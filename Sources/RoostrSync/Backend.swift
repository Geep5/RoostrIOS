import CryptoKit
import Foundation
import GlonCore

// The replica backend the UI consumes: ties store + replay + sync + the
// engine's mutation planner together. All state lives on-device; relays are
// the only network.

public enum BackendError: Error, Equatable {
	case unknownObject(String)
	case malformedPlan(String)
}

/// The synced vanish ledger object; the engine reads its entries.
private let vanishLogId = "__vanished__"

public actor Backend {
	private struct Cached {
		let changeCount: Int
		let state: JSONValue
	}

	private let key: NostrKey
	private let store: ChangeStore
	private let engine: SyncEngine
	/// Key-derived author id, parity with the Odin server (keys.ts authorIdFor).
	public let author: String

	private var states: [String: Cached] = [:]
	/// Object ids the synced ledger says are gone; rebuilt when it commits.
	private var vanished: Set<String> = []
	private var dirty: Set<String> = []
	private var allDirty = true
	private var forwardTask: Task<Void, Never>?
	private var commitSinks: [UUID: AsyncStream<[String]>.Continuation] = [:]

	public init(key: NostrKey, relays: [RelayClient], store: ChangeStore) {
		self.key = key
		self.store = store
		self.engine = SyncEngine(key: key, relays: relays, store: store)
		self.author = Self.authorId(secretHex: key.secretHex)
	}

	/// sha256 of the UTF-8 bytes of the 64-char secret hex STRING, first 16 hex chars.
	static func authorId(secretHex: String) -> String {
		String(Hex.encode(Data(SHA256.hash(data: Data(secretHex.utf8)))).prefix(16))
	}

	// ── Lifecycle ──

	public func start() async {
		allDirty = true
		forwardTask?.cancel()
		let commits = await engine.commitUpdates()
		forwardTask = Task {
			for await ids in commits {
				self.imported(ids)
			}
		}
		await engine.start()
	}

	public func stop() async {
		forwardTask?.cancel()
		forwardTask = nil
		await engine.stop()
		for sink in commitSinks.values { sink.finish() }
		commitSinks.removeAll()
	}

	public func awaitIdle() async {
		await engine.awaitIdle()
	}

	public func statusUpdates() async -> AsyncStream<SyncStatus> {
		await engine.statusUpdates()
	}

	/// Object ids whose state changed, from relay imports and local mutations alike.
	public func commitUpdates() -> AsyncStream<[String]> {
		let id = UUID()
		let (stream, continuation) = AsyncStream<[String]>.makeStream()
		commitSinks[id] = continuation
		continuation.onTermination = { _ in Task { await self.dropCommitSink(id) } }
		return stream
	}

	private func dropCommitSink(_ id: UUID) { commitSinks[id] = nil }

	private func imported(_ ids: [String]) {
		for id in ids { dirty.insert(id) }
		notify(ids)
	}

	private func notify(_ ids: [String]) {
		for sink in commitSinks.values { sink.yield(ids) }
	}

	// ── Replayed state ──

	/// Recomputes dirty object states; an object whose change count did not grow keeps its cached replay.
	private func ensure() async throws {
		var rebuilt = false
		let ids: [String]
		if allDirty {
			allDirty = false
			rebuilt = true
			ids = try await store.objectIds()
			dirty.removeAll()
		} else {
			ids = Array(dirty)
			dirty.removeAll()
		}
		for id in ids {
			let changes = try await store.changesFor(objectId: id)
			if changes.isEmpty { states[id] = nil; continue }
			if let hit = states[id], hit.changeCount == changes.count { continue }
			do {
				if let state = try await Engine.replay(changes.map(\.json)) {
					states[id] = Cached(changeCount: changes.count, state: state)
				}
			} catch {
				// One malformed legacy object must never brick the vault.
				continue
			}
		}
		try await enforceVanished(rebuilt: rebuilt, touched: ids)
	}

	/// The ledger wins over whatever replayed: a relay copy of a vanished object
	/// can arrive ahead of, or without, the delete change that tombstones it.
	private func enforceVanished(rebuilt: Bool, touched: [String]) async throws {
		let ledgerChanged = touched.contains(vanishLogId)
		if rebuilt || ledgerChanged {
			let entries = try await Engine.vanished(ledger: states[vanishLogId]?.state)
			vanished = Set(entries.map(\.objectId))
		}
		if vanished.isEmpty { return }
		if rebuilt || ledgerChanged {
			for id in vanished { states[id] = nil }
		} else {
			for id in touched where vanished.contains(id) { states[id] = nil }
		}
	}

	/// Non-deleted objects, newest first; the vanish ledger and vanished ids are excluded.
	public func objects() async throws -> [ObjectSummary] {
		try await ensure()
		var out: [ObjectSummary] = []
		out.reserveCapacity(states.count)
		for (id, cached) in states {
			let state = cached.state
			if id == vanishLogId || vanished.contains(id) { continue }
			let typeKey = state["typeKey"]?.string ?? ""
			let deleted = state["deleted"]?.bool ?? false
			if deleted || typeKey == "vanish_log" { continue }
			out.append(ObjectSummary(
				id: id,
				typeKey: typeKey,
				name: state["fields"]?["name"]?["stringValue"]?.string ?? "",
				updatedAt: state["updatedAt"]?.int ?? 0,
				deleted: deleted
			))
		}
		out.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
		return out
	}

	/// Replayed ObjectJSON with plain maps.
	public func object(id: String) async throws -> JSONValue {
		try await ensure()
		guard let cached = states[id] else { throw BackendError.unknownObject(id) }
		return unpackCoreValueMaps(cached.state)
	}

	// ── Mutations ──

	/// Runs the engine's mutation planner over the current state and commits
	/// every planned change (encode → store → publish). Returns the plan's result.
	public func mutate(action: String, params: JSONValue) async throws -> JSONValue {
		try await ensure()
		let plan = try await Engine.mutation(
			action: action,
			params: params,
			objects: states.values.map { packCoreValueMaps($0.state) },
			timestamp: Int64(Date().timeIntervalSince1970 * 1000),
			author: author,
			idSeed: UUID().uuidString.lowercased(),
			keyId: 0
		)
		for change in plan.changes { try await commit(change) }
		// Browsers enforce the synced ledger locally; native hosts additionally purge files.
		for change in plan.vanishChanges { try await commit(change) }
		return unpackCoreValueMaps(plan.result)
	}

	/// Creates a note and its first text block; returns the object id.
	public func createNote(name: String, text: String) async throws -> String {
		let created = try await mutate(action: "create", params: .object(["name": .string(name)]))
		guard let id = created["id"]?.string else { throw BackendError.malformedPlan("create returned no id") }
		_ = try await mutate(action: "block_add", params: .object([
			"object_id": .string(id),
			"block": .object(["content": .object(["text": .object(["text": .string(text)])])]),
			"target_id": .string(""),
			"position": .int(0),
		]))
		return id
	}

	/// Encodes, addresses, durably persists and publishes one planned change.
	private func commit(_ planned: JSONValue) async throws {
		guard var fields = planned.object, let objectId = fields["objectId"]?.string else { throw BackendError.malformedPlan("change without objectId") }
		let history = try await store.changesFor(objectId: objectId)
		fields["parentIds"] = .array(try await Engine.heads(history.map(\.json)).map(JSONValue.string))
		let bytes = try await Engine.encode(.object(fields))
		// Round-trip through decode so the stored JSON matches relay-imported changes byte for byte.
		let decoded = try await Engine.decode(bytes)
		guard let id = decoded["id"]?.string else { throw BackendError.malformedPlan("encoded change without id") }
		_ = try await store.addChanges([ChangeRecord(id: id, objectId: objectId, bytes: bytes, json: decoded)])
		dirty.insert(objectId)
		try await engine.publish(bytes: bytes, changeId: id, objectId: objectId)
		notify([objectId])
	}
}
