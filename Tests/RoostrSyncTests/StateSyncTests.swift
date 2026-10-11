import Foundation
import GlonCore
import SQLite3
import XCTest
@testable import RoostrSync

/// State sync on the phone (docs/state-sync.md): bases first, live deltas by
/// the base they name, deterministic rebase of orphans, and the pre-base walk
/// unchanged while no relay holds a base. The phone never compacts: the
/// computer's part (`compact_plan`, `seal_base`) is played here by the core.
final class StateSyncTests: XCTestCase {
	private let key = NostrKey.generate()

	/// Polls until `probe` yields a value.
	private func eventually<T>(timeout: Duration = .seconds(10), _ probe: () async throws -> T?) async throws -> T {
		let deadline = ContinuousClock.now + timeout
		while ContinuousClock.now < deadline {
			if let value = try await probe() { return value }
			try await Task.sleep(for: .milliseconds(20))
		}
		throw XCTestError(.timeoutWhileWaiting)
	}

	// ── Fixtures: changes, deltas and bases as the computers publish them ──

	private static let createNote = JSONValue.object(["objectCreate": .object(["typeKey": .string("note")])])
	private static func setField(_ key: String, _ value: String) -> JSONValue {
		.object(["fieldSet": .object(["key": .string(key), "value": .object(["stringValue": .string(value)])])])
	}

	private func change(_ objectId: String, _ ops: [JSONValue], parents: [String] = [], timestamp: Int64, base: String? = nil) async throws -> ChangeRecord {
		let bytes = try await Engine.encode(.object([
			"objectId": .string(objectId), "parentIds": .array(parents.map(JSONValue.string)),
			"timestamp": .int(timestamp), "author": .string(key.pubkey), "ops": .array(ops),
		]))
		let json = try await Engine.decode(bytes)
		return ChangeRecord(id: try XCTUnwrap(json["id"]?.string), objectId: objectId, bytes: bytes, json: json, b: base)
	}

	private func conversationKey() async throws -> String {
		try await Engine.conversationKey(sharedX: try key.sharedX(with: key.pubkey))
	}

	private static func tags(_ value: JSONValue?) -> [[String]] {
		(value?.array ?? []).map { ($0.array ?? []).compactMap(\.string) }
	}

	/// A kind-1078 delta sealed by the core (`wire seal`, with `["b", base]` when the change names one).
	private func publishDelta(_ c: ChangeRecord, to relays: [FakeRelay], createdAt: Int64) async throws -> [NostrEvent] {
		var payload: [String: JSONValue] = [
			"action": .string("seal"), "change": .string(c.bytes.base64EncodedString()),
			"conversationKey": .string(try await conversationKey()), "secret": .string(key.secretHex), "objectId": .string(c.objectId),
		]
		if let b = c.b { payload["base"] = .string(b) }
		let sealed: JSONValue = try await GlonCore.shared.call("wire", JSONValue.object(payload))
		let events = try (sealed["parts"]?.array ?? []).map { part in
			try key.sign(kind: Engine.changeKind, createdAt: createdAt, tags: Self.tags(part["tags"]), content: try XCTUnwrap(part["content"]?.string))
		}
		for relay in relays { for event in events { try await relay.publish(event, timeout: .seconds(1)) } }
		return events
	}

	/// The serving computer's compaction: `changes` folded into a new base on top of `bases`.
	private func compact(_ bases: [BaseRecord], _ changes: [ChangeRecord], atMs nowMs: Int64) async throws -> BaseRecord {
		var payload = ObjectHoldings(bases: bases, changes: changes, checkpoint: nil).payload
		payload["nowMs"] = .int(nowMs)
		payload["force"] = .bool(true)
		let plan: JSONValue = try await Engine.sync("compact_plan", payload)
		XCTAssertEqual(plan["compact"]?.bool, true)
		let bytes = try XCTUnwrap(plan["base"]?.string.flatMap { Data(base64Encoded: $0) })
		return BaseRecord(objectId: changes[0].objectId, hash: try XCTUnwrap(plan["hash"]?.string), epoch: try XCTUnwrap(plan["epoch"]?.int), createdAt: nowMs, bytes: bytes)
	}

	/// `seal_base`, signed: the 1080 parts first, then the addressable 31078.
	private func publishBase(_ base: BaseRecord, to relays: [FakeRelay], createdAt: Int64) async throws -> [NostrEvent] {
		let sealed: JSONValue = try await Engine.sync("seal_base", [
			"base": .string(base.bytes.base64EncodedString()), "conversationKey": .string(try await conversationKey()), "secret": .string(key.secretHex),
		])
		XCTAssertEqual(sealed["hash"]?.string, base.hash)
		let events = try ((sealed["parts"]?.array ?? []) + [try XCTUnwrap(sealed["event"])]).map { part in
			try key.sign(kind: Int(try XCTUnwrap(part["kind"]?.int)), createdAt: createdAt, tags: Self.tags(part["tags"]), content: try XCTUnwrap(part["content"]?.string))
		}
		for relay in relays { for event in events { try await relay.publish(event, timeout: .seconds(1)) } }
		return events
	}

	/// A migrated vault: three pre-migration changes from long ago, an epoch-1
	/// base folding them (big enough to split into 1080 parts) and one live
	/// delta on it.
	private struct Migrated {
		let relay: FakeRelay
		let history: [ChangeRecord]
		let preMigration: [NostrEvent]
		let base: BaseRecord
		let live: ChangeRecord
		let liveEvents: [NostrEvent]
	}

	private func migratedVault() async throws -> Migrated {
		let relay = FakeRelay()
		let now = Int64(Date().timeIntervalSince1970)
		let create = try await change("doc", [Self.createNote, Self.setField("name", "v1")], timestamp: 1)
		let rename = try await change("doc", [Self.setField("name", "v2")], parents: [create.id], timestamp: 2)
		let notes = try await change("doc", [Self.setField("notes", String(repeating: "state sync ", count: 6_000))], parents: [rename.id], timestamp: 3)
		var preMigration: [NostrEvent] = []
		for (index, c) in [create, rename, notes].enumerated() {
			preMigration += try await publishDelta(c, to: [relay], createdAt: 1_000_000 + Int64(index))
		}
		let base = try await compact([], [create, rename, notes], atMs: now * 1000)
		XCTAssertEqual(base.epoch, 1)
		let baseEvents = try await publishBase(base, to: [relay], createdAt: now)
		XCTAssertGreaterThan(baseEvents.count, 1, "a 66k-char field splits the base into kind-1080 parts")
		let live = try await change("doc", [Self.setField("name", "v3")], parents: [notes.id], timestamp: 4, base: base.hash)
		let liveEvents = try await publishDelta(live, to: [relay], createdAt: now + 1)
		return Migrated(relay: relay, history: [create, rename, notes, live], preMigration: preMigration, base: base, live: live, liveEvents: liveEvents)
	}

	// ── Sync ──

	func testBasesFirstBootstrapReachesTheFullHistoryState() async throws {
		let vault = try await migratedVault()
		let store = try SQLiteChangeStore.inMemory()
		let backend = Backend(key: key, relays: [vault.relay], store: store)
		await backend.start()
		await backend.awaitIdle()

		let object = try await backend.object(id: "doc")
		let replayed = try await Engine.replay(vault.history.map(\.json))
		let full = unpackCoreValueMaps(try XCTUnwrap(replayed))
		XCTAssertEqual(object["fields"], full["fields"], "base + live delta = the state of the whole history")
		XCTAssertEqual(object["typeKey"], full["typeKey"])
		XCTAssertEqual(object["fields"]?["name"]?["stringValue"]?.string, "v3")
		let cachedBases = await backend.cachedBaseHashes(id: "doc")
		XCTAssertEqual(cachedBases, vault.base.hash, "the replay memo is keyed on the base")

		let first = try XCTUnwrap(vault.relay.reconcileFilters.first)
		XCTAssertEqual(first.kinds, [Engine.baseKind], "bases are reconciled first")
		XCTAssertEqual(first.authors, [key.pubkey])
		XCTAssertTrue(vault.relay.queryFilters.contains { $0.kinds == [Engine.basePartKind] && $0.tagged["c"] != nil }, "split base parts are fetched by #c")
		XCTAssertTrue(vault.relay.reconcileFilters.contains { $0.kinds == [Engine.changeKind] && $0.tagged["b"] == [vault.base.hash] }, "live deltas by #b")
		let unbounded = vault.relay.reconcileFilters.filter { $0.kinds == [Engine.changeKind] && $0.tagged.isEmpty && $0.since == nil }
		XCTAssertEqual(unbounded, [], "once bases exist, kind-1078 history is never reconciled from event zero")
		let fetched = Set(vault.relay.fetchedIds)
		XCTAssertTrue(vault.liveEvents.allSatisfy { fetched.contains($0.id) })
		XCTAssertFalse(vault.preMigration.contains { fetched.contains($0.id) }, "history the base folded, older than its bound, is never fetched")
		let held = try await store.bases(objectId: "doc")
		XCTAssertEqual(held.map(\.hash), [vault.base.hash])
		let changes = try await store.changesFor(objectId: "doc")
		XCTAssertEqual(changes.map(\.id), [vault.live.id])
		XCTAssertEqual(changes.first?.b, vault.base.hash, "the delta's b tag is stored with it")
		let bootstrapped = try await store.bootstrapped()
		XCTAssertTrue(bootstrapped)
		await backend.stop()
	}

	func testLocalDeltaCarriesItsBase() async throws {
		let vault = try await migratedVault()
		let store = try SQLiteChangeStore.inMemory()
		let backend = Backend(key: key, relays: [vault.relay], store: store)
		await backend.start()
		await backend.awaitIdle()
		let before = Set(vault.relay.stored.map(\.id))

		_ = try await backend.mutate(action: "block_add", params: .object([
			"object_id": .string("doc"),
			"block": .object(["content": .object(["text": .object(["text": .string("on the base")])])]),
			"target_id": .string(""),
			"position": .int(0),
		]))
		let mine = try await eventually { () -> ChangeRecord? in
			try await store.changesFor(objectId: "doc").first { $0.id != vault.live.id }
		}
		XCTAssertEqual(mine.b, vault.base.hash)
		XCTAssertEqual(mine.json["parentIds"]?.array?.compactMap(\.string), [vault.live.id], "written on the base's live head")
		let published = try await eventually {
			vault.relay.stored.first { !before.contains($0.id) && $0.kind == Engine.changeKind && $0.tag("h") == vault.liveEvents[0].tag("h") }
		}
		XCTAssertEqual(published.tag("b"), vault.base.hash, "the delta goes out with [\"b\", base]")
		let object = try await backend.object(id: "doc")
		XCTAssertEqual(object["fields"]?["name"]?["stringValue"]?.string, "v3")
		await backend.stop()
	}

	/// A base B2 compacted without seeing delta x (written on B1): x is an
	/// orphan. Every device holding the same events rebases it to the same
	/// change, written on B2, and publishes it with B2's b tag.
	func testOrphanRebasesToTheSameIdOnEveryDevice() async throws {
		let relays = [FakeRelay(), FakeRelay(url: URL(string: "ws://other.relay")!)]
		let now = Int64(Date().timeIntervalSince1970)
		let create = try await change("doc", [Self.createNote, Self.setField("name", "v1")], timestamp: 1)
		let rename = try await change("doc", [Self.setField("name", "v2")], parents: [create.id], timestamp: 2)
		for (index, c) in [create, rename].enumerated() { _ = try await publishDelta(c, to: relays, createdAt: 1_000_000 + Int64(index)) }
		let b1 = try await compact([], [create, rename], atMs: (now - 100) * 1000)
		_ = try await publishBase(b1, to: relays, createdAt: now - 100)
		let folded = try await change("doc", [Self.setField("y", "folded")], parents: [rename.id], timestamp: 3, base: b1.hash)
		let orphan = try await change("doc", [Self.setField("x", "orphan")], parents: [rename.id], timestamp: 4, base: b1.hash)
		_ = try await publishDelta(folded, to: relays, createdAt: now - 50)
		_ = try await publishDelta(orphan, to: relays, createdAt: now - 40)
		let b2 = try await compact([b1], [create, rename, folded], atMs: now * 1000)
		XCTAssertEqual(b2.epoch, 2)
		_ = try await publishBase(b2, to: relays, createdAt: now)

		let expected = try await Engine.rebase(ObjectHoldings(bases: [b1, b2], changes: [create, rename, folded, orphan], checkpoint: nil))
		XCTAssertEqual(expected.base, b2.hash)
		let rebasedId = try XCTUnwrap(expected.changes.first?.id)
		XCTAssertEqual(expected.changes.map(\.orphan), [orphan.id])

		for relay in relays {
			let seeded = Set(relay.stored.map(\.id))
			let store = try SQLiteChangeStore.inMemory()
			let backend = Backend(key: key, relays: [relay], store: store)
			await backend.start()
			await backend.awaitIdle()
			let rebased = try await eventually { () -> ChangeRecord? in
				try await store.changesFor(objectId: "doc").first { $0.b == b2.hash }
			}
			XCTAssertEqual(rebased.id, rebasedId, "\(relay.url): deterministic rebase")
			XCTAssertEqual(rebased.json["parentIds"]?.array?.compactMap(\.string), [folded.id], "written on B2's heads")
			let marked = try await store.changesFor(objectId: "doc").first { $0.id == orphan.id }
			XCTAssertEqual(marked?.rebased, true, "the orphan is never replayed or rebased again")
			let published = try await eventually { relay.stored.first { !seeded.contains($0.id) && $0.kind == Engine.changeKind && $0.tag("b") == b2.hash } }
			XCTAssertEqual(published.pubkey, key.pubkey)
			_ = try await eventually { () -> Bool? in
				let object = try await backend.object(id: "doc")
				return object["fields"]?["x"]?["stringValue"]?.string == "orphan" ? true : nil
			}
			let object = try await backend.object(id: "doc")
			XCTAssertEqual(object["fields"]?["y"]?["stringValue"]?.string, "folded")
			XCTAssertEqual(object["fields"]?["name"]?["stringValue"]?.string, "v2")
			await backend.stop()
		}
	}

	func testWithNoBasesTheHistoryWalkIsUnchanged() async throws {
		let relay = FakeRelay()
		let create = try await change("doc", [Self.createNote, Self.setField("name", "v1")], timestamp: 1)
		let rename = try await change("doc", [Self.setField("name", "v2")], parents: [create.id], timestamp: 2)
		var events: [NostrEvent] = []
		for (index, c) in [create, rename].enumerated() { events += try await publishDelta(c, to: [relay], createdAt: 1_000_000 + Int64(index)) }
		let store = try SQLiteChangeStore.inMemory()
		let backend = Backend(key: key, relays: [relay], store: store)
		await backend.start()
		await backend.awaitIdle()

		let object = try await backend.object(id: "doc")
		XCTAssertEqual(object["fields"]?["name"]?["stringValue"]?.string, "v2")
		XCTAssertTrue(relay.reconcileFilters.contains { $0.kinds == [Engine.baseKind] && $0.authors == [key.pubkey] }, "bases are still looked for first")
		XCTAssertTrue(relay.reconcileFilters.contains { $0.kinds == [Engine.changeKind] && $0.authors == [key.pubkey] && $0.since == nil && $0.tagged.isEmpty }, "the whole kind-1078 history, as before")
		XCTAssertTrue(relay.reconcileFilters.contains { $0.kinds == [Engine.checkpointKind] && $0.since == nil }, "legacy checkpoints keep importing")
		XCTAssertFalse(relay.reconcileFilters.contains { $0.tagged["b"] != nil }, "no base: no #b pass")
		let fetched = Set(relay.fetchedIds)
		XCTAssertTrue(events.allSatisfy { fetched.contains($0.id) }, "pre-migration history syncs as it always did")
		let changes = try await store.changesFor(objectId: "doc")
		XCTAssertEqual(changes.map(\.id), [create.id, rename.id])
		XCTAssertTrue(changes.allSatisfy { $0.b == nil })
		let bootstrapped = try await store.bootstrapped()
		XCTAssertTrue(bootstrapped)

		// A change made with no base goes out exactly as before: no b tag.
		let before = Set(relay.stored.map(\.id))
		_ = try await backend.mutate(action: "block_add", params: .object([
			"object_id": .string("doc"), "block": .object(["content": .object(["text": .object(["text": .string("pre-base")])])]),
			"target_id": .string(""), "position": .int(0),
		]))
		let published = try await eventually { relay.stored.first { !before.contains($0.id) && $0.kind == Engine.changeKind && $0.tag("h") == events[0].tag("h") } }
		XCTAssertNil(published.tag("b"))
		await backend.stop()
	}

	// ── Store ──

	/// A database an older build wrote (no `b`/`rebased`/`base_hashes`
	/// columns, no `bases` table) opens with every row intact and gains them.
	func testStoreMigratesAnOlderSchemaKeepingItsRows() async throws {
		let path = FileManager.default.temporaryDirectory.appendingPathComponent("roostr-migrate-\(UUID().uuidString).sqlite").path
		defer { try? FileManager.default.removeItem(atPath: path) }
		var db: OpaquePointer?
		XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
		for sql in [
			"CREATE TABLE changes (id TEXT PRIMARY KEY, object_id TEXT NOT NULL, seq INTEGER NOT NULL, bytes BLOB NOT NULL, json TEXT NOT NULL)",
			"CREATE INDEX changes_object_id ON changes(object_id, seq)",
			"CREATE TABLE held (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, kind INTEGER NOT NULL, author TEXT NOT NULL, h TEXT)",
			"CREATE TABLE replay_cache (object_id TEXT PRIMARY KEY, engine_version TEXT NOT NULL, change_count INTEGER NOT NULL, change_digest TEXT NOT NULL, checkpoint_hash TEXT NOT NULL, state BLOB NOT NULL)",
			"INSERT INTO changes VALUES ('c1', 'o1', 1, x'01', '{\"id\":\"c1\"}')",
			"INSERT INTO changes VALUES ('c2', 'o2', 2, x'02', '{\"id\":\"c2\"}')",
			"INSERT INTO held VALUES ('e1', 100, 1078, 'pk', 'tag')",
			"INSERT INTO replay_cache VALUES ('o1', 'v', 1, 'digest', '', x'7b7d')",
		] {
			XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
		}
		sqlite3_close(db)

		var store: SQLiteChangeStore? = try SQLiteChangeStore(path: path)
		var changes = try await store!.changesFor(objectId: "o1")
		XCTAssertEqual(changes, [ChangeRecord(id: "c1", objectId: "o1", bytes: Data([1]), json: .object(["id": .string("c1")]))])
		let held = try await store!.heldEvents(matching: NostrFilter(kinds: [1078]))
		XCTAssertEqual(held, [HeldEvent(id: "e1", createdAt: 100, kind: 1078, author: "pk", hTag: "tag")])
		let cached = try await store!.cachedReplays(objectIds: ["o1"], engineVersion: "v")
		XCTAssertEqual(cached["o1"]?.input, ReplayInput(changeCount: 1, changeDigest: "digest", checkpointHash: ""))

		_ = try await store!.addChanges([ChangeRecord(id: "c3", objectId: "o1", bytes: Data([3]), json: .object([:]), b: "bb")])
		try await store!.markRebased(["c1"])
		try await store!.recordHeld([HeldEvent(id: "e2", createdAt: 200, kind: 1078, author: "pk", hTag: "tag", bTag: "bb")])
		var stored = try await store!.putBase(BaseRecord(objectId: "o1", hash: "h1", epoch: 1, createdAt: 5_000, bytes: Data([9])))
		XCTAssertTrue(stored)
		stored = try await store!.putBase(BaseRecord(objectId: "o1", hash: "h1", epoch: 1, createdAt: 5_000, bytes: Data([9])))
		XCTAssertFalse(stored, "a base is held once")
		stored = try await store!.putBase(BaseRecord(objectId: "o1", hash: "h2", epoch: 2, createdAt: 4_000, bytes: Data([8])))
		XCTAssertTrue(stored)
		store = nil

		// Reopening is a no-op migration; every row is still there.
		let reopened = try SQLiteChangeStore(path: path)
		changes = try await reopened.changesFor(objectId: "o1")
		XCTAssertEqual(changes.map(\.id), ["c1", "c3"])
		XCTAssertEqual(changes.map(\.rebased), [true, false])
		XCTAssertEqual(changes.map(\.b), [nil, "bb"])
		let byBase = try await reopened.heldEvents(matching: NostrFilter(kinds: [1078], tagged: ["b": ["bb"]]))
		XCTAssertEqual(byBase.map(\.id), ["e2"])
		let current = try await reopened.currentBaseHashes()
		XCTAssertEqual(current, ["h2"], "the highest epoch is current whatever its created_at")
		let newest = try await reopened.newestBaseCreatedAt()
		XCTAssertEqual(newest, 5_000)
		let withoutBase = try await reopened.objectsWithoutBase()
		XCTAssertEqual(withoutBase, ["o2"])
		let inputs = try await reopened.replayInputs()
		XCTAssertEqual(inputs["o1"], ReplayInput(changeIds: ["c3"], checkpointHash: "", baseHashes: ["h2", "h1"]), "a rebased orphan never replays; the bases key the memo")
		let ids = try await reopened.objectIds()
		XCTAssertEqual(Set(ids), ["o1", "o2"])
	}

	func testStoreKeepsABoundedBaseChain() async throws {
		let store = try SQLiteChangeStore.inMemory()
		for epoch in Int64(1)...12 {
			_ = try await store.putBase(BaseRecord(objectId: "o", hash: String(format: "h%02lld", epoch), epoch: epoch, createdAt: epoch, bytes: Data()))
		}
		let held = try await store.bases(objectId: "o")
		XCTAssertEqual(held.map(\.epoch), Array(Int64(13 - baseChainKept)...12))
	}
}
