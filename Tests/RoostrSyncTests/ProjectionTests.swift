import CryptoKit
import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// The website-shaped projections over the replica (`backend.ts`):
/// summaries, relation defs, incremental query and the sync digest.
final class ProjectionTests: XCTestCase {
	private func backend() -> Backend {
		Backend(key: NostrKey.generate(), relays: [FakeRelay()], store: InMemoryChangeStore(), keyring: InMemorySpaceKeyring())
	}

	func testConcurrentMailboxDeliveryAndClaimAreIdempotent() async throws {
		let backend = backend()
		await backend.start()
		defer { Task { await backend.stop() } }
		let source = try await backend.createNote(name: "Sender", text: "")
		let target = try await backend.createNote(name: "Receiver", text: "")
		let message: JSONValue = .object([
			"id": .string("concurrent-message"), "exchangeId": .string("concurrent-exchange"),
			"sender": .object(["objectId": .string(source), "agentId": .string("")]),
			"recipients": .array([.object(["objectId": .string(target), "agentId": .string("")])]),
			"text": .string("Record this once"), "replyTo": .string(""), "sentAt": .int(100),
			"title": .string("Concurrent delivery"), "requestReply": .bool(false),
			"historical": .bool(false), "operation": .string(""), "author": .string(""),
		])
		_ = try await backend.mutate(action: "message_send", params: .object([
			"object_id": .string(source), "message": message,
		]))
		try await withThrowingTaskGroup(of: Void.self) { group in
			for _ in 0..<8 {
				group.addTask {
					_ = try await backend.mutate(action: "message_deliver", params: .object([
						"sender_object_id": .string(source), "message_id": .string("concurrent-message"),
						"recipient_object_id": .string(target),
					]))
				}
			}
			try await group.waitForAll()
		}
		let receiver = try await backend.object(id: target)
		XCTAssertEqual(receiver["mailbox"]?.array?.map { $0["message"]?["text"]?.string }, ["Record this once"])
		let claims = try await withThrowingTaskGroup(of: Bool.self, returning: Int.self) { group in
			for index in 0..<12 {
				group.addTask {
					let result = try await backend.mutate(action: "message_processing", params: .object([
						"object_id": .string(target), "message_id": .string("concurrent-message"),
						"status": .string("processing"), "owner": .string("worker-\(index)"),
					]))
					return result["claimed"]?.bool == true
				}
			}
			var claimed = 0
			for try await value in group { if value { claimed += 1 } }
			return claimed
		}
		XCTAssertEqual(claims, 1, "Only one worker may execute a delivered message")
	}

	func testSummariesCarryWebsiteFields() async throws {
		let backend = backend()
		await backend.start()
		defer { Task { await backend.stop() } }
		let noteId = try await backend.createNote(name: "Hello", text: "world")
		let task = try await backend.mutate(action: "create", params: .object([
			"name": .string("Ship it"),
			"type_key": .string("task"),
			"fields": .object(["done": .object(["boolValue": .bool(true)]), "iconEmoji": .object(["stringValue": .string("🚀")])]),
		]))
		let taskId = try XCTUnwrap(task["id"]?.string)

		let rows = try await backend.summaries()
		let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"]!.string!, $0) })
		XCTAssertEqual(Set(byId.keys), [noteId, taskId])

		let note = try XCTUnwrap(byId[noteId])
		XCTAssertEqual(note["typeKey"]?.string, "note")
		XCTAssertEqual(note["name"]?.string, "Hello")
		XCTAssertEqual(note["channelId"]?.string, "", "no channel in the vault: unassigned")
		XCTAssertEqual(note["icon"]?.string, "")
		XCTAssertEqual(note["done"]?.bool, false)
		XCTAssertNotNil(note["updatedAt"]?.int)

		let done = try XCTUnwrap(byId[taskId])
		XCTAssertEqual(done["typeKey"]?.string, "task")
		XCTAssertEqual(done["done"]?.bool, true)
		XCTAssertEqual(done["icon"]?.string, "🚀")
	}

	func testHiddenTypesAndDeletedObjectsLeaveTheList() async throws {
		let backend = backend()
		await backend.start()
		defer { Task { await backend.stop() } }
		let noteId = try await backend.createNote(name: "Gone", text: "")
		_ = try await backend.mutate(action: "delete", params: .object(["object_id": .string(noteId)]))
		_ = try await backend.mutate(action: "create", params: .object(["name": .string("Def"), "type_key": .string("relation")]))
		let rows = try await backend.summaries()
		XCTAssertEqual(rows, [])
	}

	func testRelationsComeFromSeededSpaceDefaults() async throws {
		let backend = backend()
		await backend.start()
		defer { Task { await backend.stop() } }
		let fresh = try await backend.relations()
		XCTAssertEqual(fresh, [], "a fresh vault holds no relation objects")

		let space = try await backend.mutate(action: "channel_create", params: .object(["name": .string("Personal")]))
		let spaceId = try XCTUnwrap(space["id"]?.string)
		let defs = try await backend.relations()
		let byKey = Dictionary(uniqueKeysWithValues: defs.map { ($0["key"]!.string!, $0) })
		let name = try XCTUnwrap(byKey["name"], "bundled defs seed with the space")
		XCTAssertEqual(name["format"]?.string, "shorttext")
		XCTAssertEqual(name["name"]?.string, "Name")
		XCTAssertEqual(name["space"]?.string, spaceId)
		XCTAssertEqual(name["hidden"]?.bool, false)
		XCTAssertEqual(name["readOnly"]?.bool, false)
		XCTAssertEqual(name["maxCount"]?.int, 0)
		XCTAssertEqual(name["objectTypes"]?.array, [])
		XCTAssertEqual(name["options"]?.array, [])
		XCTAssertNil(name["objectSource"], "absent, not empty: the UI treats undefined as unrestricted")
		XCTAssertEqual(byKey["iconEmoji"]?["hidden"]?.bool, true)
		XCTAssertTrue(defs.allSatisfy { !($0["key"]?.string ?? "").isEmpty })
	}

	func testQueryIsIncrementalAcrossCalls() async throws {
		let backend = backend()
		await backend.start()
		defer { Task { await backend.stop() } }
		let noteId = try await backend.createNote(name: "Queried", text: "body")
		let body: JSONValue = .object(["filters": .array([]), "sorts": .array([])])

		let first = try await backend.query(body: body)
		XCTAssertEqual(first["total"]?.int, 1)
		let record = try XCTUnwrap(first["records"]?.array?.first)
		XCTAssertEqual(record["id"]?.string, noteId)
		XCTAssertEqual(record["name"]?.string, "Queried")

		// Nothing changed: the cache path sends no upserts and the engine answers from its snapshot.
		let again = try await backend.query(body: body)
		XCTAssertEqual(again["total"]?.int, 1)
		XCTAssertEqual(again["records"]?.array?.first?["id"]?.string, noteId)

		// A change count growth is an upsert; a new object too.
		let second = try await backend.createNote(name: "Second", text: "")
		_ = try await backend.mutate(action: "set_field", params: .object([
			"object_id": .string(noteId), "key": .string("name"), "value": .object(["stringValue": .string("Renamed")]),
		]))
		let grown = try await backend.query(body: body)
		XCTAssertEqual(grown["total"]?.int, 2)
		let names = Dictionary(uniqueKeysWithValues: (grown["records"]?.array ?? []).map { ($0["id"]!.string!, $0["name"]?.string ?? "") })
		XCTAssertEqual(names, [noteId: "Renamed", second: "Second"])

		// Deleting removes the object from the engine's snapshot via `removed`.
		_ = try await backend.mutate(action: "delete", params: .object(["object_id": .string(second)]))
		let shrunk = try await backend.query(body: body)
		XCTAssertEqual(shrunk["total"]?.int, 1)
	}

	func testSyncDigestCountsObjectsAndChanges() async throws {
		let backend = backend()
		await backend.start()
		defer { Task { await backend.stop() } }
		let empty = try await backend.syncDigest()
		XCTAssertEqual(empty["objects"]?.int, 0)
		XCTAssertEqual(empty["changes"]?.int, 0)
		XCTAssertEqual(empty["digest"]?.string, Hex.encode(Data(SHA256.hash(data: Data()))), "sha256 of the empty text")

		let noteId = try await backend.createNote(name: "Digest", text: "x")
		let digest = try await backend.syncDigest()
		XCTAssertEqual(digest["objects"]?.int, 1)
		XCTAssertEqual(digest["changes"]?.int, 2, "create + block_add")
		let store = await backend.store
		let ids = try await store.changesFor(objectId: noteId).map(\.id).sorted()
		let expected = Hex.encode(Data(SHA256.hash(data: Data("\(noteId):\(ids.joined(separator: ","))\n".utf8))))
		XCTAssertEqual(digest["digest"]?.string, expected)
	}

	func testLogoutRefusesWhilePublishesArePending() async throws {
		let relay = FakeRelay()
		relay.setAccepting(false)
		let store = InMemoryChangeStore()
		let backend = Backend(key: NostrKey.generate(), relays: [relay], store: store, keyring: InMemorySpaceKeyring())
		await backend.start()
		_ = try await backend.createNote(name: "Stuck", text: "")
		// The outbox keeps retrying a rejecting relay, so wait for the durable records rather than idleness.
		let deadline = ContinuousClock.now + .seconds(5)
		while try await store.pendingPublishes().count < 2, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		do {
			try await backend.logout(exportTo: nil)
			XCTFail("unpublished changes must block the logout")
		} catch let error as LogoutError {
			XCTAssertEqual(error, .unpublishedChanges(2))
		}

		let export = FileManager.default.temporaryDirectory.appendingPathComponent("roostr-pending-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: export) }
		try await backend.logout(exportTo: export)
		let exported = try JSONDecoder().decode([PendingPublish].self, from: Data(contentsOf: export))
		XCTAssertEqual(exported.count, 2)
	}
}
