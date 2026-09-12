import XCTest
import GlonCore
@testable import RoostrSync

final class SQLiteChangeStoreTests: XCTestCase {
	private func record(_ id: String, object: String, payload: Int64 = 0) -> ChangeRecord {
		ChangeRecord(
			id: id,
			objectId: object,
			bytes: Data([0x01, UInt8(truncatingIfNeeded: payload), 0xFF]),
			json: .object(["id": .string(id), "object_id": .string(object), "n": .int(payload), "text": .string("quote\" back\\ nl\n tab\t ünï")])
		)
	}

	func testFilterEncodesTagKeys() throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		let data = try encoder.encode(NostrFilter(kinds: [1078], tagged: ["h": ["ab"]]))
		XCTAssertEqual(String(data: data, encoding: .utf8), "{\"#h\":[\"ab\"],\"kinds\":[1078]}")
	}

	func testAddChangesDedupesByIdAndCountsNew() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let a = record("a", object: "o1", payload: 1)
		let b = record("b", object: "o1", payload: 2)
		let firstCount = try await store.addChanges([a, b])
		XCTAssertEqual(firstCount, 2)
		let secondCount = try await store.addChanges([a, b, record("c", object: "o2", payload: 3)])
		XCTAssertEqual(secondCount, 1)
		let thirdCount = try await store.addChanges([a])
		XCTAssertEqual(thirdCount, 0)
		let emptyCount = try await store.addChanges([])
		XCTAssertEqual(emptyCount, 0)
		let stored = try await store.changesFor(objectId: "o1")
		XCTAssertEqual(stored, [a, b])
	}

	func testChangesForPreservesInsertionOrderPerObject() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let o1 = ["z", "m", "a"].enumerated().map { record($0.element, object: "o1", payload: Int64($0.offset)) }
		let o2 = ["y", "b"].enumerated().map { record($0.element, object: "o2", payload: Int64($0.offset + 10)) }
		_ = try await store.addChanges([o1[0], o2[0]])
		_ = try await store.addChanges([o1[1]])
		_ = try await store.addChanges([o2[1], o1[2]])
		let first = try await store.changesFor(objectId: "o1")
		XCTAssertEqual(first.map(\.id), ["z", "m", "a"])
		let second = try await store.changesFor(objectId: "o2")
		XCTAssertEqual(second.map(\.id), ["y", "b"])
		let missing = try await store.changesFor(objectId: "missing")
		XCTAssertEqual(missing, [])
	}

	func testObjectIdsAreDistinct() async throws {
		let store = try SQLiteChangeStore.inMemory()
		_ = try await store.addChanges([record("1", object: "o2"), record("2", object: "o1"), record("3", object: "o2"), record("4", object: "o1")])
		let ids = try await store.objectIds()
		XCTAssertEqual(ids.sorted(), ["o1", "o2"])
	}

	func testCursorAndReplayGroupsRoundTripTogether() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let initialCursor = try await store.cursor()
		XCTAssertEqual(initialCursor, 0)
		let initialGroups = try await store.replayGroups()
		XCTAssertEqual(initialGroups.count, 0)

		try await store.setCursor(1_700_000_000, replayGroups: [("space/1", 42), ("space/2", 7)])
		let cursor = try await store.cursor()
		XCTAssertEqual(cursor, 1_700_000_000)
		let groups = try await store.replayGroups()
		XCTAssertEqual(groups.map(\.0), ["space/1", "space/2"])
		XCTAssertEqual(groups.map(\.1), [42, 7])

		try await store.setCursor(1_700_000_001, replayGroups: [])
		let advanced = try await store.cursor()
		XCTAssertEqual(advanced, 1_700_000_001)
		let cleared = try await store.replayGroups()
		XCTAssertEqual(cleared.count, 0)
	}

	func testBootstrapLifecycle() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let fresh = try await store.bootstrapped()
		XCTAssertFalse(fresh)
		let noFloor = try await store.bootstrapFloor()
		XCTAssertNil(noFloor)

		try await store.setBootstrapFloor(1234)
		let floor = try await store.bootstrapFloor()
		XCTAssertEqual(floor, 1234)
		try await store.setBootstrapFloor(99)
		let lowered = try await store.bootstrapFloor()
		XCTAssertEqual(lowered, 99)

		try await store.setBootstrapped()
		try await store.setBootstrapped()
		let done = try await store.bootstrapped()
		XCTAssertTrue(done)

		try await store.setBootstrapFloor(nil)
		let clearedFloor = try await store.bootstrapFloor()
		XCTAssertNil(clearedFloor)
		let stillDone = try await store.bootstrapped()
		XCTAssertTrue(stillDone)
	}

	func testPendingAndPublishedLifecycle() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let event = NostrEvent(id: "e1", pubkey: "p", created_at: 5, kind: 1078, tags: [["h", "s1"]], content: "c", sig: "s")
		let personal = PendingPublish(key: "c1", objectId: "o1", changeId: "c1", bytes: Data([9, 8, 7]))
		let shared = PendingPublish(key: "s1/3/c2", objectId: "o2", changeId: "c2", bytes: Data([1]), spaceId: "s1", keyId: 3, events: [event])

		let none = try await store.pending(key: "c1")
		XCTAssertNil(none)
		let unpublished = try await store.isPublished(key: "c1")
		XCTAssertFalse(unpublished)
		let empty = try await store.pendingPublishes()
		XCTAssertEqual(empty.count, 0)

		try await store.savePending(personal)
		try await store.savePending(shared)
		let gotPersonal = try await store.pending(key: "c1")
		XCTAssertEqual(gotPersonal, personal)
		let gotShared = try await store.pending(key: "s1/3/c2")
		XCTAssertEqual(gotShared, shared)
		let all = try await store.pendingPublishes()
		XCTAssertEqual(Set(all.map(\.key)), ["c1", "s1/3/c2"])

		var retried = personal
		retried.events = [event]
		try await store.savePending(retried)
		let overwritten = try await store.pending(key: "c1")
		XCTAssertEqual(overwritten, retried)
		let stillTwo = try await store.pendingPublishes()
		XCTAssertEqual(stillTwo.count, 2)

		try await store.markPublished(key: "c1")
		let published = try await store.isPublished(key: "c1")
		XCTAssertTrue(published)
		let removed = try await store.pending(key: "c1")
		XCTAssertNil(removed)
		let remaining = try await store.pendingPublishes()
		XCTAssertEqual(remaining.map(\.key), ["s1/3/c2"])
		let sharedPublished = try await store.isPublished(key: "s1/3/c2")
		XCTAssertFalse(sharedPublished)

		try await store.markPublished(key: "never-pending")
		let orphanPublished = try await store.isPublished(key: "never-pending")
		XCTAssertTrue(orphanPublished)
		let untouched = try await store.pendingPublishes()
		XCTAssertEqual(untouched.count, 1)
	}

	func testFileBackedStoreSurvivesReopen() async throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roostr-store-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let path = dir.appendingPathComponent("changes.sqlite").path

		let first = try SQLiteChangeStore(path: path)
		let a = record("a", object: "o1", payload: 1)
		let b = record("b", object: "o1", payload: 2)
		_ = try await first.addChanges([a, b])
		try await first.setCursor(77, replayGroups: [("g", 1)])
		try await first.setBootstrapped()
		try await first.savePending(PendingPublish(key: "b", objectId: "o1", changeId: "b", bytes: b.bytes))
		try await first.markPublished(key: "a")
		await first.close()

		let second = try SQLiteChangeStore(path: path)
		let changes = try await second.changesFor(objectId: "o1")
		XCTAssertEqual(changes, [a, b])
		let duplicate = try await second.addChanges([a])
		XCTAssertEqual(duplicate, 0)
		let cursor = try await second.cursor()
		XCTAssertEqual(cursor, 77)
		let groups = try await second.replayGroups()
		XCTAssertEqual(groups.map(\.0), ["g"])
		let bootstrapped = try await second.bootstrapped()
		XCTAssertTrue(bootstrapped)
		let pending = try await second.pendingPublishes()
		XCTAssertEqual(pending.map(\.key), ["b"])
		let published = try await second.isPublished(key: "a")
		XCTAssertTrue(published)
		await second.close()
	}

	func testClosedStoreThrowsStoreError() async throws {
		let store = try SQLiteChangeStore.inMemory()
		await store.close()
		do {
			_ = try await store.cursor()
			XCTFail("expected a throw")
		} catch let error as StoreError {
			XCTAssertEqual(error.message, "store is closed")
		}
	}
}
