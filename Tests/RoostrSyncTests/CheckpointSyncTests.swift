import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// Checkpoint sync on the native host (docs/checkpoint-sync.md): the store
/// keeps one checkpoint per object under the supersede rule, a cold start
/// imports kind-1079 payloads and walks kind-1078 only from the publisher's
/// manifest floor, and replay seeds from the checkpoint. The phone never
/// builds checkpoints, so a publisher's payload is hand-assembled here from
/// the wire layout in core/proto.odin, as the browser test does.
final class CheckpointSyncTests: XCTestCase {
	private let key = NostrKey.generate()

	// ── Fixture: a checkpoint protobuf ──

	private static func varint(_ n: Int) -> [UInt8] {
		var out: [UInt8] = []
		var n = n
		while n >= 0x80 { out.append(UInt8(n & 0x7f) | 0x80); n >>= 7 }
		out.append(UInt8(n))
		return out
	}
	private static func field(_ no: Int, _ bytes: [UInt8]) -> [UInt8] {
		varint((no << 3) | 2) + varint(bytes.count) + bytes
	}
	/// Checkpoint: 1 objectId, 2 headIds, 3 coveredIds, 4 Snapshot, 5 createdAt;
	/// Snapshot: 1 id, 2 typeKey, 3 {1 key, 2 Value}, 7 createdAt, 8 updatedAt; Value.stringValue = 1.
	static func checkpointBytes(objectId: String, typeKey: String, fields: [(String, String)], heads: [String], covered: [String], createdAt: Int) -> Data {
		let utf8 = { (s: String) in Array(s.utf8) }
		var snapshot = field(1, utf8(objectId)) + field(2, utf8(typeKey))
		for (k, v) in fields { snapshot += field(3, field(1, utf8(k)) + field(2, field(1, utf8(v)))) }
		snapshot += varint((7 << 3) | 0) + varint(100) + varint((8 << 3) | 0) + varint(100)
		var out = field(1, utf8(objectId))
		for id in heads { out += field(2, [UInt8](Hex.decode(id)!)) }
		for id in covered { out += field(3, [UInt8](Hex.decode(id)!)) }
		out += field(4, snapshot) + varint((5 << 3) | 0) + varint(createdAt)
		return Data(out)
	}

	private func change(_ objectId: String, ops: [JSONValue], parents: [String] = []) async throws -> (json: JSONValue, bytes: Data, id: String) {
		let bytes = try await Engine.encode(.object([
			"objectId": .string(objectId), "parentIds": .array(parents.map(JSONValue.string)),
			"timestamp": .int(100), "author": .string(key.pubkey), "ops": .array(ops),
		]))
		let json = try await Engine.decode(bytes)
		return (json, bytes, try XCTUnwrap(json["id"]?.string))
	}
	private func setName(_ value: String) -> JSONValue {
		.object(["fieldSet": .object(["key": .string("name"), "value": .object(["stringValue": .string(value)])])])
	}

	private func conversationKey() async throws -> String {
		try await Engine.conversationKey(sharedX: try key.sharedX(with: key.pubkey))
	}
	private func sealed(kind: Int, _ plaintext: String, createdAt: Int64, tags: [[String]] = []) async throws -> NostrEvent {
		try key.sign(kind: kind, createdAt: createdAt, tags: tags, content: try await Engine.encrypt(plaintext, conversationKey: try await conversationKey()))
	}

	// ── Store ──

	func testStoreKeepsWiderThenHigherHashAndListsCheckpointOnlyObjects() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let narrow = CheckpointRecord(objectId: "doc", bytes: Data([1]), hash: "aa", heads: ["h1"], covered: 1)
		let wide = CheckpointRecord(objectId: "doc", bytes: Data([2]), hash: "00", heads: ["h2"], covered: 2)
		let rival = CheckpointRecord(objectId: "doc", bytes: Data([3]), hash: "ff", heads: ["h2"], covered: 2)
		var stored = try await store.putCheckpoint(narrow)
		XCTAssertTrue(stored)
		stored = try await store.putCheckpoint(wide)
		XCTAssertTrue(stored, "more covered wins regardless of hash")
		stored = try await store.putCheckpoint(narrow)
		XCTAssertFalse(stored, "a narrower checkpoint never replaces a wider one")
		stored = try await store.putCheckpoint(rival)
		XCTAssertTrue(stored, "same width: the larger hash wins on every replica")
		let held = try await store.checkpoint(objectId: "doc")
		XCTAssertEqual(held, rival)
		_ = try await store.addChanges([ChangeRecord(id: "c1", objectId: "other", bytes: Data(), json: .object([:]))])
		let ids = try await store.objectIds()
		XCTAssertEqual(ids.sorted(), ["doc", "other"], "an object held only as a checkpoint is queryable")
		try await store.setCheckpointFloor(scope: "", 500)
		try await store.setCheckpointFloor(scope: "tag", 700)
		let floors = try await store.checkpointFloors()
		XCTAssertEqual(floors, ["": 500, "tag": 700])
	}

	// ── Replay ──

	func testCheckpointStandsInForCoveredHistory() async throws {
		let create = try await change("doc", ops: [.object(["objectCreate": .object(["typeKey": .string("note")])]), setName("v1")])
		let edit = try await change("doc", ops: [setName("v2")], parents: [create.id])
		let full = try await Engine.replay([create.json, edit.json])
		let c1 = Self.checkpointBytes(objectId: "doc", typeKey: "note", fields: [("name", "v1")], heads: [create.id], covered: [create.id], createdAt: 1)
		let c2 = Self.checkpointBytes(objectId: "doc", typeKey: "note", fields: [("name", "v2")], heads: [edit.id], covered: [create.id, edit.id], createdAt: 2)
		let fromWide = try await Engine.replay([], checkpoint: c2)
		XCTAssertEqual(fromWide?["fields"], full?["fields"])
		let fromNarrow = try await Engine.replay([edit.json], checkpoint: c1)
		XCTAssertEqual(fromNarrow?["fields"], full?["fields"])
		let heads = try await Engine.heads([], checkpoint: c2)
		XCTAssertEqual(heads, [edit.id], "checkpoint heads nothing built on are the object's heads")
	}

	// ── Cold start ──

	func testColdStartImportsCheckpointAndWalksChangesFromManifestFloor() async throws {
		let relay = FakeRelay()
		let create = try await change("doc", ops: [.object(["objectCreate": .object(["typeKey": .string("note")])]), setName("v1")])
		let edit = try await change("doc", ops: [setName("v2")], parents: [create.id])
		// The publisher: the covered change is OLD (before the floor) and the
		// tail is NEW; the checkpoint folds the old one in.
		let c1 = Self.checkpointBytes(objectId: "doc", typeKey: "note", fields: [("name", "v1")], heads: [create.id], covered: [create.id], createdAt: 1)
		let oldChange = try await sealed(kind: Engine.changeKind, create.bytes.base64EncodedString(), createdAt: 100, tags: [["h", try await Engine.blind(secretHex: key.secretHex, id: "doc")]])
		let checkpoint = try await sealed(kind: Engine.checkpointKind, c1.base64EncodedString(), createdAt: 150, tags: [["h", try await Engine.blind(secretHex: key.secretHex, id: "doc")]])
		let manifest = try await sealed(kind: Engine.manifestKind, #"{"cursor":150,"objects":1}"#, createdAt: 160, tags: [["d", Engine.manifestTag]])
		let newChange = try await sealed(kind: Engine.changeKind, edit.bytes.base64EncodedString(), createdAt: 200, tags: [["h", try await Engine.blind(secretHex: key.secretHex, id: "doc")]])
		for event in [oldChange, checkpoint, manifest, newChange] { try await relay.publish(event, timeout: .seconds(1)) }

		let store = try SQLiteChangeStore.inMemory()
		let backend = Backend(key: key, relays: [relay], store: store)
		await backend.start()
		await backend.awaitIdle()

		let held = try await store.checkpoint(objectId: "doc")
		XCTAssertEqual(held?.covered, 1)
		XCTAssertEqual(held?.heads, [create.id])
		let changes = try await store.changesFor(objectId: "doc")
		XCTAssertEqual(changes.map(\.id), [edit.id], "only the tail past the floor is stored; the covered change is not")
		let walk = relay.queryFilters.filter { $0.kinds == [Engine.changeKind] && $0.authors != nil }
		XCTAssertTrue(walk.allSatisfy { $0.since == 150 }, "kind-1078 is walked from the manifest cursor, not genesis: \(walk.map(\.since))")
		XCTAssertTrue(relay.queryFilters.contains { $0.kinds == [Engine.checkpointKind] && ($0.since ?? 0) <= 1 }, "kind-1079 is walked unbounded")
		let live = try XCTUnwrap(relay.subscribeFilters.first { $0.authors != nil })
		XCTAssertEqual(live.kinds, [Engine.changeKind, Engine.checkpointKind])
		XCTAssertGreaterThanOrEqual(live.since ?? 0, 150, "live never reaches below a publisher's floor")

		let object = try await backend.object(id: "doc")
		XCTAssertEqual(object["fields"]?["name"]?["stringValue"]?.string, "v2", "state = checkpoint + tail")
		let floors = try await store.checkpointFloors()
		XCTAssertEqual(floors[""], 150)
		await backend.stop()
	}

	func testLiveCheckpointSeedsReplayAndRekeysTheMemo() async throws {
		let relay = FakeRelay()
		let create = try await change("doc", ops: [.object(["objectCreate": .object(["typeKey": .string("note")])]), setName("v1")])
		let edit = try await change("doc", ops: [setName("v2")], parents: [create.id])
		let tag = try await Engine.blind(secretHex: key.secretHex, id: "doc")
		for (c, at) in [(create, Int64(100)), (edit, Int64(200))] {
			try await relay.publish(try await sealed(kind: Engine.changeKind, c.bytes.base64EncodedString(), createdAt: at, tags: [["h", tag]]), timeout: .seconds(1))
		}
		let store = try SQLiteChangeStore.inMemory()
		let backend = Backend(key: key, relays: [relay], store: store)
		await backend.start()
		await backend.awaitIdle()
		var object = try await backend.object(id: "doc")
		// A checkpoint arriving live whose covered ids form a prefix of the held
		// history is a replay shortcut: its snapshot seeds the state and the
		// covered changes are skipped (core checkpoint_for_replay). The memo
		// must re-key on the hash so the replay actually re-runs rather than
		// trusting an unchanged change count.
		let c2 = Self.checkpointBytes(objectId: "doc", typeKey: "note", fields: [("name", "from-checkpoint")], heads: [edit.id], covered: [create.id, edit.id], createdAt: 2)
		try await relay.publish(try await sealed(kind: Engine.checkpointKind, c2.base64EncodedString(), createdAt: 300, tags: [["h", tag]]), timeout: .seconds(1))
		let deadline = ContinuousClock.now + .seconds(5)
		var held: CheckpointRecord?
		while held == nil, ContinuousClock.now < deadline {
			held = try await store.checkpoint(objectId: "doc")
			if held == nil { try await Task.sleep(for: .milliseconds(20)) }
		}
		await backend.awaitIdle()
		XCTAssertEqual(held?.covered, 2)
		object = try await backend.object(id: "doc")
		XCTAssertEqual(object["fields"]?["name"]?["stringValue"]?.string, "from-checkpoint", "the checkpoint snapshot seeds the state")
		let memo = await backend.cachedSignature(id: "doc")
		XCTAssertEqual(memo, "2:\(held!.hash)", "the memo is keyed on the checkpoint hash, not only the change count")
		await backend.stop()
	}
}
