import Foundation
import XCTest
@testable import GlonCore

/// Receive-side sync session shared with glonOdin/core/sync_session_test.odin
/// and the website: chunk-group reassembly, the cursor high-water mark, replay
/// obligations and replay-fault detection live in the engine's `sync` method.
/// Every event is produced by the engine's own seal, so the test exercises the
/// exact tags and ciphertext a Roostr writer emits; only the signature is
/// missing, which hosts verify before ingest.
final class SyncSessionTests: XCTestCase {
	private static let pk = String(repeating: "ab", count: 32)
	private static let secret = String(repeating: "01", count: 32)
	private static let conversationKey = String(repeating: "02", count: 32)
	private static let spaceKey = String(repeating: "03", count: 32)
	private static let writer = String(repeating: "ef", count: 32)
	private static let groupTTLMs: Int64 = 300_000

	private let core = GlonCore.shared

	private func sync(_ action: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
		var payload = fields
		payload["action"] = .string(action)
		return try await core.call("sync", JSONValue.object(payload))
	}

	private func openSession() async throws {
		_ = try await sync("session", [
			"pk": .string(Self.pk),
			"conversationKey": .string(Self.conversationKey),
			"cursor": .int(10),
			"spaces": .array([.object(["spaceId": .string("space-1"), "keyHex": .string(Self.spaceKey), "keyId": .int(1)])]),
		])
	}

	private func close() async throws {
		let closed: Bool = try await core.call("sync", JSONValue.object(["action": .string("close")]))
		XCTAssertTrue(closed)
	}

	/// A wire change with a valid content address, carrying `size` bytes of text; base64.
	private func wireChange(_ objectId: String, size: Int) async throws -> String {
		var ops: [JSONValue] = [.object(["objectCreate": .object(["typeKey": .string("page")])])]
		if size > 0 {
			let value: JSONValue = .object(["stringValue": .string(String(repeating: "x", count: size))])
			ops.append(.object(["fieldSet": .object(["key": .string("body"), "value": value])]))
		}
		let change: JSONValue = .object([
			"objectId": .string(objectId),
			"parentIds": .array([]),
			"timestamp": .int(1),
			"author": .string("t"),
			"ops": .array(ops),
		])
		return try await core.call("codec", JSONValue.object(["action": .string("encode"), "change": change]))
	}

	/// Personal or shared seal of `change`; returns the parts as kind-1078 events.
	private func sealEvents(_ change: String, objectId: String, shared: Bool, pubkey: String, createdAt: Int64) async throws -> [JSONValue] {
		var payload: [String: JSONValue] = ["action": .string("seal"), "change": .string(change), "objectId": .string(objectId)]
		if shared {
			payload["conversationKey"] = .string(Self.spaceKey)
			payload["space"] = .object(["keyHex": .string(Self.spaceKey), "spaceId": .string("space-1")])
		} else {
			payload["conversationKey"] = .string(Self.conversationKey)
			payload["secret"] = .string(Self.secret)
		}
		let sealed: JSONValue = try await core.call("wire", JSONValue.object(payload))
		return try XCTUnwrap(sealed["parts"]?.array, "seal returns parts").map { part in
			.object([
				"pubkey": .string(pubkey),
				"created_at": .int(createdAt),
				"kind": .int(1078),
				"tags": part["tags"] ?? .null,
				"content": part["content"] ?? .null,
			])
		}
	}

	private func ingest(_ event: JSONValue, now: Int64) async throws -> JSONValue {
		try await sync("ingest", ["event": event, "nowMs": .int(now)])
	}

	/// Value of the event's `c` tag at `index` (gid is 1).
	private func chunkTag(_ event: JSONValue, _ index: Int) -> String? {
		event["tags"]?.array?.first { $0.array?.first == .string("c") }?.array?[index].string
	}

	private func withField(_ event: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
		guard case .object(var fields) = event else { return event }
		fields[key] = value
		return .object(fields)
	}

	/// The session is process-global (the ABI is single-flight), so its scenarios
	/// run sequentially inside one test rather than on XCTest's threads.
	func testSyncSessionContract() async throws {
		try await singlePartAndPubkeyRule()
		try await reassemblesOutOfOrderChunks()
		try await faultsOnConflictAndExpiry()
		try await restoresReplayGroupsAndRejectsWithoutSession()
	}

	private func singlePartAndPubkeyRule() async throws {
		try await openSession()
		let change = try await wireChange("note-1", size: 0)
		let events = try await sealEvents(change, objectId: "note-1", shared: false, pubkey: Self.pk, createdAt: 100)
		XCTAssertEqual(events.count, 1)

		var r = try await ingest(events[0], now: 1_000)
		XCTAssertEqual(r["cursor"]?.int, 100, "cursor advances to the event")
		let item = try XCTUnwrap(r["item"], "single part yields an item")
		XCTAssertEqual(item["change"]?["objectId"]?.string, "note-1")
		XCTAssertNil(item["chunkKey"], "no chunk key for a whole change")
		XCTAssertNil(item["provenance"], "personal items carry no provenance")

		// Same ciphertext under someone else's pubkey is not ours.
		let forged = try await sealEvents(change, objectId: "note-1", shared: false, pubkey: String(repeating: "cd", count: 32), createdAt: 200)
		r = try await ingest(forged[0], now: 1_000)
		XCTAssertNil(r["item"], "personal ciphertext must be authored by our key")
		XCTAssertEqual(r["cursor"]?.int, 100, "a dropped event does not move the cursor")

		// Wrong kind is ignored outright.
		r = try await ingest(withField(events[0], "kind", .int(1)), now: 1_000)
		XCTAssertNil(r["item"])
		try await close()
	}

	private func reassemblesOutOfOrderChunks() async throws {
		try await openSession()
		let change = try await wireChange("big-1", size: 70_000)
		let events = try await sealEvents(change, objectId: "big-1", shared: true, pubkey: Self.writer, createdAt: 300)
		XCTAssertEqual(events.count, 3, "expected 3 parts")

		var r = try await ingest(events[2], now: 1_000)
		XCTAssertNil(r["item"], "first part alone is not a change")
		XCTAssertEqual(r["replayGroups"]?.array?.count, 1, "an open group is a replay obligation")

		r = try await ingest(events[0], now: 1_001)
		XCTAssertNil(r["item"])
		// Re-delivery of a part already held is idempotent.
		r = try await ingest(events[0], now: 1_002)
		XCTAssertNil(r["item"])
		var state = try await sync("state")
		XCTAssertEqual(state["groups"]?.int, 1)

		r = try await ingest(events[1], now: 1_003)
		let item = try XCTUnwrap(r["item"], "last part completes the change")
		XCTAssertEqual(item["change"]?["objectId"]?.string, "big-1")
		let gid = try XCTUnwrap(chunkTag(events[1], 1), "chunk parts carry a c tag")
		let chunkKey = try XCTUnwrap(item["chunkKey"]?.string)
		XCTAssertEqual(chunkKey, "[\"\(Self.writer)\",\"space-1\",1,\"\(gid)\"]")
		XCTAssertEqual(item["provenance"], .object(["spaceId": .string("space-1"), "keyId": .int(1), "signer": .string(Self.writer)]))
		state = try await sync("state")
		XCTAssertEqual(state["groups"]?.int, 0, "completed group is released")
		XCTAssertEqual(state["replayFloor"]?.int, 300, "obligation stays until the import settles")

		// A repeat of the group while it is importing is ignored; settling retires it.
		r = try await ingest(events[1], now: 1_004)
		XCTAssertNil(r["item"], "importing group is not reassembled twice")
		r = try await sync("settle", ["chunkKey": .string(chunkKey), "imported": .bool(true)])
		XCTAssertEqual(r["replayGroups"], .array([]), "settled import clears the replay group")
		r = try await ingest(events[0], now: 1_005)
		XCTAssertNil(r["item"], "imported group parts are ignored afterwards")
		try await close()
	}

	private func faultsOnConflictAndExpiry() async throws {
		try await openSession()
		let a = try await sealEvents(try await wireChange("big-a", size: 70_000), objectId: "big-a", shared: true, pubkey: Self.writer, createdAt: 400)
		let b = try await sealEvents(try await wireChange("big-b", size: 70_000), objectId: "big-b", shared: true, pubkey: Self.writer, createdAt: 500)

		// Conflicting content for a held index tears the group down and faults at its start.
		_ = try await ingest(a[0], now: 1_000)
		// Reuse a's chunk tag (same gid/index) but b's ciphertext.
		let conflict = withField(a[0], "content", try XCTUnwrap(b[0]["content"]))
		var r = try await ingest(conflict, now: 1_001)
		XCTAssertEqual(r["faultAt"]?.int, 400, "conflicting part faults at the group's earliest event")
		let state = try await sync("state")
		XCTAssertEqual(state["groups"]?.int, 0)

		// Expiry: a stale group faults when the next chunk arrives after its TTL.
		_ = try await ingest(a[1], now: 2_000)
		r = try await ingest(b[1], now: 2_000 + Self.groupTTLMs)
		XCTAssertEqual(r["faultAt"]?.int, 400, "expired group faults at its earliest event")
		try await close()
	}

	private func restoresReplayGroupsAndRejectsWithoutSession() async throws {
		do {
			_ = try await sync("state")
			XCTFail("state without a session must throw")
		} catch {
			XCTAssertEqual(error as? GlonError, .engine("no sync session"))
		}

		let state = try await sync("session", [
			"pk": .string(Self.pk),
			"conversationKey": .string(Self.conversationKey),
			"cursor": .int(7),
			"replayGroups": .array([.array([.string("[\"x\",\"\",0,\"0000000000000000\"]"), .int(42)])]),
		])
		XCTAssertEqual(state["replayFloor"]?.int, 42, "persisted replay groups restore the floor")
		XCTAssertEqual(state["cursor"]?.int, 7)
		try await close()
	}
}

private extension JSONValue {
	var int: Int64? {
		if case .int(let value) = self { return value }
		return nil
	}

	var array: [JSONValue]? {
		if case .array(let value) = self { return value }
		return nil
	}
}
