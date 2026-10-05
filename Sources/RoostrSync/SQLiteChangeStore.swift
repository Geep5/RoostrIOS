import Foundation
import GlonCore
import SQLite3

/// SQLite failure surfaced with the library's own message.
public struct StoreError: Error, CustomStringConvertible, Sendable {
	public let code: Int32
	public let message: String

	public init(code: Int32, message: String) {
		self.code = code; self.message = message
	}

	public var description: String { "sqlite(\(code)): \(message)" }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// `ChangeStore` over the system SQLite. Three tables mirror the browser's
/// IndexedDB stores: `changes` (wire bytes + decoded JSON, in insertion order),
/// `checkpoints` (one per object) and `meta` (string key/value); `held` lists
/// the relay events this device holds, for NIP-77; `replay_cache` memoizes
/// replayed states (`ReplayCacheStore`). Statements are prepared once and reused.
public actor SQLiteChangeStore: ChangeStore {
	private var db: OpaquePointer?
	private var statements: [String: OpaquePointer] = [:]
	private let encoder = JSONEncoder()
	private let decoder = JSONDecoder()

	public init(path: String) throws {
		var handle: OpaquePointer?
		let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
		let rc = sqlite3_open_v2(path, &handle, flags, nil)
		guard rc == SQLITE_OK, let opened = handle else {
			let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
			sqlite3_close(handle)
			throw StoreError(code: rc, message: message)
		}
		do {
			try Self.exec(opened, "PRAGMA journal_mode=WAL")
			try Self.exec(opened, "PRAGMA foreign_keys=OFF")
			try Self.exec(opened, """
				CREATE TABLE IF NOT EXISTS changes (
					id TEXT PRIMARY KEY,
					object_id TEXT NOT NULL,
					seq INTEGER NOT NULL,
					bytes BLOB NOT NULL,
					json TEXT NOT NULL
				)
				""")
			try Self.exec(opened, "CREATE INDEX IF NOT EXISTS changes_object_id ON changes(object_id, seq)")
			try Self.exec(opened, "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
			try Self.exec(opened, """
				CREATE TABLE IF NOT EXISTS checkpoints (
					object_id TEXT PRIMARY KEY,
					bytes BLOB NOT NULL,
					hash TEXT NOT NULL,
					heads TEXT NOT NULL,
					covered INTEGER NOT NULL
				)
				""")
			try Self.exec(opened, """
				CREATE TABLE IF NOT EXISTS held (
					id TEXT PRIMARY KEY,
					created_at INTEGER NOT NULL,
					kind INTEGER NOT NULL,
					author TEXT NOT NULL,
					h TEXT
				)
				""")
			try Self.exec(opened, "CREATE INDEX IF NOT EXISTS held_author ON held(author, kind)")
			try Self.exec(opened, "CREATE INDEX IF NOT EXISTS held_h ON held(h, kind)")
			try Self.exec(opened, """
				CREATE TABLE IF NOT EXISTS replay_cache (
					object_id TEXT PRIMARY KEY,
					engine_version TEXT NOT NULL,
					change_count INTEGER NOT NULL,
					change_digest TEXT NOT NULL,
					checkpoint_hash TEXT NOT NULL,
					state BLOB NOT NULL
				)
				""")
		} catch {
			sqlite3_close(opened)
			throw error
		}
		db = opened
	}

	public static func inMemory() throws -> SQLiteChangeStore {
		try SQLiteChangeStore(path: ":memory:")
	}

	/// Finalizes statements and closes the connection; every later call throws.
	public func close() {
		for statement in statements.values { sqlite3_finalize(statement) }
		statements.removeAll()
		if let db { sqlite3_close(db) }
		db = nil
	}

	deinit {
		for statement in statements.values { sqlite3_finalize(statement) }
		if let db { sqlite3_close(db) }
	}

	// MARK: changes

	public func addChanges(_ records: [ChangeRecord]) async throws -> Int {
		if records.isEmpty { return 0 }
		return try transaction {
			let insert = try statement("INSERT OR IGNORE INTO changes (id, object_id, seq, bytes, json) VALUES (?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM changes), ?, ?)")
			var inserted = 0
			for record in records {
				try reset(insert)
				let json = try encoder.encode(record.json)
				try bind(insert, 1, record.id)
				try bind(insert, 2, record.objectId)
				try bind(insert, 3, record.bytes)
				try bind(insert, 4, String(decoding: json, as: UTF8.self))
				try stepDone(insert)
				inserted += Int(sqlite3_changes(try handle()))
			}
			return inserted
		}
	}

	public func changesFor(objectId: String) async throws -> [ChangeRecord] {
		let select = try statement("SELECT id, bytes, json FROM changes WHERE object_id = ? ORDER BY seq")
		try reset(select)
		try bind(select, 1, objectId)
		var records: [ChangeRecord] = []
		while try stepRow(select) {
			let id = columnText(select, 0)
			let bytes = columnBlob(select, 1)
			let json = try decoder.decode(JSONValue.self, from: Data(columnText(select, 2).utf8))
			records.append(ChangeRecord(id: id, objectId: objectId, bytes: bytes, json: json))
		}
		sqlite3_reset(select)
		return records
	}

	public func objectIds() async throws -> [String] {
		let select = try statement("""
			SELECT object_id FROM (
				SELECT object_id, MIN(seq) AS first FROM changes GROUP BY object_id
				UNION SELECT object_id, NULL FROM checkpoints WHERE object_id NOT IN (SELECT object_id FROM changes)
			) ORDER BY first IS NULL, first
			""")
		try reset(select)
		var ids: [String] = []
		while try stepRow(select) { ids.append(columnText(select, 0)) }
		sqlite3_reset(select)
		return ids
	}

	// MARK: checkpoints

	public func checkpoint(objectId: String) async throws -> CheckpointRecord? {
		let select = try statement("SELECT bytes, hash, heads, covered FROM checkpoints WHERE object_id = ?")
		try reset(select)
		try bind(select, 1, objectId)
		defer { sqlite3_reset(select) }
		guard try stepRow(select) else { return nil }
		let heads = try decoder.decode([String].self, from: Data(columnText(select, 2).utf8))
		return CheckpointRecord(objectId: objectId, bytes: columnBlob(select, 0), hash: columnText(select, 1), heads: heads, covered: Int(sqlite3_column_int64(select, 3)))
	}

	public func putCheckpoint(_ record: CheckpointRecord) async throws -> Bool {
		try transaction {
			if let existing = try checkpointMeta(record.objectId),
			   !(record.covered > existing.covered || (record.covered == existing.covered && record.hash > existing.hash)) {
				return false
			}
			let upsert = try statement("INSERT OR REPLACE INTO checkpoints (object_id, bytes, hash, heads, covered) VALUES (?, ?, ?, ?, ?)")
			try reset(upsert)
			try bind(upsert, 1, record.objectId)
			try bind(upsert, 2, record.bytes)
			try bind(upsert, 3, record.hash)
			try bind(upsert, 4, String(decoding: try encoder.encode(record.heads), as: UTF8.self))
			guard sqlite3_bind_int64(upsert, 5, Int64(record.covered)) == SQLITE_OK else { throw error(SQLITE_ERROR) }
			try stepDone(upsert)
			return true
		}
	}

	private func checkpointMeta(_ objectId: String) throws -> (covered: Int, hash: String)? {
		let select = try statement("SELECT covered, hash FROM checkpoints WHERE object_id = ?")
		try reset(select)
		try bind(select, 1, objectId)
		defer { sqlite3_reset(select) }
		guard try stepRow(select) else { return nil }
		return (Int(sqlite3_column_int64(select, 0)), columnText(select, 1))
	}

	public func forgetCheckpointFloors() async throws {
		guard let raw = try meta("checkpoint-floors") else { return }
		let floors = (try? decoder.decode([String: Int64].self, from: Data(raw.utf8))) ?? [:]
		try transaction {
			try deleteMeta("checkpoint-floors")
			if floors.values.contains(where: { $0 > 0 }) { try deleteMeta("bootstrapped") }
		}
	}

	// MARK: meta

	public func cursor() async throws -> Int64 {
		try meta("cursor").flatMap(Int64.init) ?? 0
	}

	public func setCursor(_ cursor: Int64, replayGroups: [(String, Int64)]) async throws {
		let groups = try encoder.encode(JSONValue.array(replayGroups.map { .array([.string($0.0), .int($0.1)]) }))
		try transaction {
			try setMeta("cursor", String(cursor))
			try setMeta("replay-groups", String(decoding: groups, as: UTF8.self))
		}
	}

	public func replayGroups() async throws -> [(String, Int64)] {
		guard let raw = try meta("replay-groups") else { return [] }
		guard case .array(let pairs) = try decoder.decode(JSONValue.self, from: Data(raw.utf8)) else {
			throw StoreError(code: SQLITE_CORRUPT, message: "replay-groups is not an array")
		}
		return try pairs.map { pair in
			guard case .array(let parts) = pair, parts.count == 2, case .string(let key) = parts[0] else {
				throw StoreError(code: SQLITE_CORRUPT, message: "replay-groups entry is not [key, at]")
			}
			switch parts[1] {
			case .int(let at): return (key, at)
			case .double(let at): return (key, Int64(at))
			default: throw StoreError(code: SQLITE_CORRUPT, message: "replay-groups entry has non-numeric at")
			}
		}
	}

	public func bootstrapped() async throws -> Bool {
		try meta("bootstrapped") == "1"
	}

	public func setBootstrapped() async throws {
		try setMeta("bootstrapped", "1")
	}

	public func bootstrapFloor() async throws -> Int64? {
		try meta("bootstrap-floor").flatMap(Int64.init)
	}

	public func setBootstrapFloor(_ floor: Int64?) async throws {
		if let floor { try setMeta("bootstrap-floor", String(floor)) } else { try deleteMeta("bootstrap-floor") }
	}

	// MARK: publication

	public func pendingPublishes() async throws -> [PendingPublish] {
		let select = try statement("SELECT value FROM meta WHERE key LIKE 'pending:%' ORDER BY rowid")
		try reset(select)
		var items: [PendingPublish] = []
		while try stepRow(select) {
			items.append(try decoder.decode(PendingPublish.self, from: Data(columnText(select, 0).utf8)))
		}
		sqlite3_reset(select)
		return items
	}

	public func pending(key: String) async throws -> PendingPublish? {
		guard let raw = try meta("pending:" + key) else { return nil }
		return try decoder.decode(PendingPublish.self, from: Data(raw.utf8))
	}

	public func savePending(_ item: PendingPublish) async throws {
		let json = try encoder.encode(item)
		try setMeta("pending:" + item.key, String(decoding: json, as: UTF8.self))
	}

	public func isPublished(key: String) async throws -> Bool {
		try meta("published:" + key) != nil
	}

	public func markPublished(key: String) async throws {
		try transaction {
			try setMeta("published:" + key, "1")
			try deleteMeta("pending:" + key)
		}
	}

	// MARK: held relay events

	public func recordHeld(_ events: [HeldEvent]) async throws {
		if events.isEmpty { return }
		try transaction {
			let insert = try statement("INSERT OR IGNORE INTO held (id, created_at, kind, author, h) VALUES (?, ?, ?, ?, ?)")
			for event in events {
				try reset(insert)
				try bind(insert, 1, event.id)
				try bind(insert, 2, event.createdAt)
				try bind(insert, 3, Int64(event.kind))
				try bind(insert, 4, event.author)
				if let hTag = event.hTag { try bind(insert, 5, hTag) }
				try stepDone(insert)
			}
		}
	}

	public func heldEvents(matching filter: NostrFilter) async throws -> [HeldEvent] {
		enum Argument { case text(String), integer(Int64) }
		var clauses: [String] = []
		var arguments: [Argument] = []
		func list(_ column: String, _ values: [Argument]) {
			clauses.append("\(column) IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
			arguments += values
		}
		if let kinds = filter.kinds { list("kind", kinds.map { .integer(Int64($0)) }) }
		if let authors = filter.authors { list("author", authors.map(Argument.text)) }
		if let tags = filter.tagged["h"] { list("h", tags.map(Argument.text)) }
		if let since = filter.since { clauses.append("created_at >= ?"); arguments.append(.integer(since)) }
		if let until = filter.until { clauses.append("created_at <= ?"); arguments.append(.integer(until)) }
		let select = try statement("SELECT id, created_at, kind, author, h FROM held" + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")))
		try reset(select)
		for (index, argument) in arguments.enumerated() {
			switch argument {
			case .text(let text): try bind(select, Int32(index + 1), text)
			case .integer(let value): try bind(select, Int32(index + 1), value)
			}
		}
		var events: [HeldEvent] = []
		while try stepRow(select) {
			let h = sqlite3_column_type(select, 4) == SQLITE_NULL ? nil : columnText(select, 4)
			events.append(HeldEvent(id: columnText(select, 0), createdAt: sqlite3_column_int64(select, 1), kind: Int(sqlite3_column_int64(select, 2)), author: columnText(select, 3), hTag: h))
		}
		sqlite3_reset(select)
		return events
	}

	// MARK: replay cache

	public func replayInputs() async throws -> [String: ReplayInput] {
		var inputs: [String: ReplayInput] = [:]
		let checkpoints = try statement("SELECT object_id, hash FROM checkpoints")
		try reset(checkpoints)
		var hashes: [String: String] = [:]
		while try stepRow(checkpoints) { hashes[columnText(checkpoints, 0)] = columnText(checkpoints, 1) }
		sqlite3_reset(checkpoints)
		// The (object_id, seq) index yields each object's ids contiguously, in replay order.
		let select = try statement("SELECT object_id, id FROM changes INDEXED BY changes_object_id ORDER BY object_id, seq")
		try reset(select)
		var current: String?
		var ids: [String] = []
		func flush() {
			guard let current else { return }
			inputs[current] = ReplayInput(changeIds: ids, checkpointHash: hashes[current] ?? "")
		}
		while try stepRow(select) {
			let objectId = columnText(select, 0)
			if objectId != current {
				flush()
				current = objectId
				ids.removeAll(keepingCapacity: true)
			}
			ids.append(columnText(select, 1))
		}
		flush()
		sqlite3_reset(select)
		for (objectId, hash) in hashes where inputs[objectId] == nil {
			inputs[objectId] = ReplayInput(changeIds: [], checkpointHash: hash)
		}
		return inputs
	}

	public func cachedReplays(objectIds: [String], engineVersion: String) async throws -> [String: CachedReplay] {
		let select = try statement("SELECT change_count, change_digest, checkpoint_hash, state FROM replay_cache WHERE object_id = ? AND engine_version = ?")
		var rows: [String: CachedReplay] = [:]
		for objectId in objectIds {
			try reset(select)
			try bind(select, 1, objectId)
			try bind(select, 2, engineVersion)
			if try stepRow(select) {
				let input = ReplayInput(changeCount: Int(sqlite3_column_int64(select, 0)), changeDigest: columnText(select, 1), checkpointHash: columnText(select, 2))
				rows[objectId] = CachedReplay(objectId: objectId, input: input, state: columnBlob(select, 3))
			}
		}
		sqlite3_reset(select)
		return rows
	}

	public func putCachedReplays(_ rows: [CachedReplay], engineVersion: String) async throws {
		if rows.isEmpty { return }
		try transaction {
			let upsert = try statement("INSERT OR REPLACE INTO replay_cache (object_id, engine_version, change_count, change_digest, checkpoint_hash, state) VALUES (?, ?, ?, ?, ?, ?)")
			for row in rows {
				try reset(upsert)
				try bind(upsert, 1, row.objectId)
				try bind(upsert, 2, engineVersion)
				try bind(upsert, 3, Int64(row.input.changeCount))
				try bind(upsert, 4, row.input.changeDigest)
				try bind(upsert, 5, row.input.checkpointHash)
				try bind(upsert, 6, row.state)
				try stepDone(upsert)
			}
		}
	}

	public func clearCachedReplays() async throws {
		try Self.exec(try handle(), "DELETE FROM replay_cache")
	}

	// MARK: meta primitives

	/// Host meta row (`MetaStore`): relay lists, wraps seen, join requests.
	public func meta(_ key: String) throws -> String? {
		let select = try statement("SELECT value FROM meta WHERE key = ?")
		try reset(select)
		try bind(select, 1, key)
		defer { sqlite3_reset(select) }
		return try stepRow(select) ? columnText(select, 0) : nil
	}

	/// Upserts the row; nil deletes it.
	public func setMeta(_ key: String, _ value: String?) throws {
		guard let value else { try deleteMeta(key); return }
		let upsert = try statement("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
		try reset(upsert)
		try bind(upsert, 1, key)
		try bind(upsert, 2, value)
		try stepDone(upsert)
	}

	private func deleteMeta(_ key: String) throws {
		let delete = try statement("DELETE FROM meta WHERE key = ?")
		try reset(delete)
		try bind(delete, 1, key)
		try stepDone(delete)
	}

	// MARK: sqlite plumbing

	private func handle() throws -> OpaquePointer {
		guard let db else { throw StoreError(code: SQLITE_MISUSE, message: "store is closed") }
		return db
	}

	private func error(_ rc: Int32) -> StoreError {
		StoreError(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "store is closed")
	}

	private static func exec(_ db: OpaquePointer, _ sql: String) throws {
		var message: UnsafeMutablePointer<CChar>?
		let rc = sqlite3_exec(db, sql, nil, nil, &message)
		guard rc == SQLITE_OK else {
			let text = message.map { String(cString: $0) } ?? "sqlite error \(rc)"
			sqlite3_free(message)
			throw StoreError(code: rc, message: text)
		}
	}

	private func transaction<T>(_ body: () throws -> T) throws -> T {
		let db = try handle()
		try Self.exec(db, "BEGIN IMMEDIATE")
		do {
			let result = try body()
			try Self.exec(db, "COMMIT")
			return result
		} catch {
			sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
			throw error
		}
	}

	private func statement(_ sql: String) throws -> OpaquePointer {
		if let cached = statements[sql] { return cached }
		var prepared: OpaquePointer?
		let rc = sqlite3_prepare_v2(try handle(), sql, -1, &prepared, nil)
		guard rc == SQLITE_OK, let prepared else { throw error(rc) }
		statements[sql] = prepared
		return prepared
	}

	private func reset(_ statement: OpaquePointer) throws {
		sqlite3_reset(statement)
		let rc = sqlite3_clear_bindings(statement)
		guard rc == SQLITE_OK else { throw error(rc) }
	}

	private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) throws {
		let rc = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
		guard rc == SQLITE_OK else { throw error(rc) }
	}

	private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) throws {
		let rc = sqlite3_bind_int64(statement, index, value)
		guard rc == SQLITE_OK else { throw error(rc) }
	}

	private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Data) throws {
		let rc = value.withUnsafeBytes { buffer -> Int32 in
			if buffer.isEmpty { return sqlite3_bind_zeroblob(statement, index, 0) }
			return sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
		}
		guard rc == SQLITE_OK else { throw error(rc) }
	}

	private func stepDone(_ statement: OpaquePointer) throws {
		let rc = sqlite3_step(statement)
		guard rc == SQLITE_DONE else { throw error(rc) }
	}

	private func stepRow(_ statement: OpaquePointer) throws -> Bool {
		switch sqlite3_step(statement) {
		case SQLITE_ROW: return true
		case SQLITE_DONE: return false
		case let rc: throw error(rc)
		}
	}

	private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
		sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
	}

	private func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data {
		let count = Int(sqlite3_column_bytes(statement, index))
		guard count > 0, let base = sqlite3_column_blob(statement, index) else { return Data() }
		return Data(bytes: base, count: count)
	}
}

extension SQLiteChangeStore: MetaStore, ReplayCacheStore {}
