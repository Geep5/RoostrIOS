import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// History sync by NIP-77 through `FakeRelay`'s negentropy server: exactly the
/// missing ids are fetched, completion waits for every one of them, and a
/// relay that refuses reconciliation is paged as before. The session is
/// process-global, so each scenario stops its engines before the next starts.
final class NegentropySyncTests: XCTestCase {
	private let key = NostrKey.generate()

	/// Another device on a fresh store publishes `notes` notes to `relay`.
	private func seed(_ relay: FakeRelay, notes: Int) async throws {
		let backend = Backend(key: key, relays: [relay], store: InMemoryChangeStore())
		await backend.start()
		for i in 0..<notes { _ = try await backend.createNote(name: "note \(i)", text: "text \(i)") }
		await backend.awaitIdle()
		await backend.stop()
	}

	/// Starts an engine on `store`, lets it settle, stops it; returns the ids it fetched by id.
	private func sync(_ relay: FakeRelay, _ store: ChangeStore, statuses: StatusTrail? = nil) async -> [String] {
		let before = relay.fetchedIds.count
		let engine = SyncEngine(key: key, relays: [relay], store: store)
		if let statuses { statuses.follow(await engine.statusUpdates()) }
		await engine.start()
		await engine.awaitIdle()
		await engine.stop()
		return Array(relay.fetchedIds[before...])
	}

	private func heldIds(_ store: ChangeStore) async throws -> Set<String> {
		Set(try await store.heldEvents(matching: NostrFilter(authors: [key.pubkey])).map(\.id))
	}

	func testFreshStoreFetchesExactlyWhatItLacksThenNothing() async throws {
		let relay = FakeRelay()
		try await seed(relay, notes: 3)
		let store = try SQLiteChangeStore.inMemory()

		let first = await sync(relay, store)
		let all = Set(relay.stored.map(\.id))
		XCTAssertEqual(first.count, all.count, "each missing event is fetched once")
		XCTAssertEqual(Set(first), all)
		XCTAssertFalse(relay.queryFilters.contains { $0.limit != nil }, "reconciled, never paged")
		let bootstrapped = try await store.bootstrapped()
		XCTAssertTrue(bootstrapped)
		let objects = try await store.objectIds()
		XCTAssertEqual(objects.count, 3)
		let held = try await heldIds(store)
		XCTAssertEqual(held, all, "every imported event is held")

		try await seed(relay, notes: 1)
		let added = Set(relay.stored.map(\.id)).subtracting(all)
		XCTAssertFalse(added.isEmpty)
		let second = await sync(relay, store)
		XCTAssertEqual(Set(second), added, "a later run fetches only the new events")
		XCTAssertEqual(second.count, added.count)
		let third = await sync(relay, store)
		XCTAssertEqual(third, [], "nothing left to fetch")
	}

	func testHistoryIsIncompleteUntilEveryNeededIdImports() async throws {
		let relay = FakeRelay()
		try await seed(relay, notes: 2)
		let missing = try XCTUnwrap(relay.stored.first?.id)
		relay.withhold([missing])
		let store = InMemoryChangeStore()
		let statuses = StatusTrail()

		let first = await sync(relay, store, statuses: statuses)
		XCTAssertTrue(first.contains(missing), "the withheld id was requested")
		var bootstrapped = try await store.bootstrapped()
		XCTAssertFalse(bootstrapped, "an id the relay did not return keeps history incomplete")
		let failure = statuses.all.compactMap(\.detail).last { $0.hasPrefix("history incomplete, retrying") }
		XCTAssertNotNil(failure, "\(statuses.all)")
		XCTAssertTrue(failure?.contains("1 reconciled events not returned") == true, failure ?? "")
		var held = try await heldIds(store)
		XCTAssertEqual(held, Set(relay.stored.map(\.id)).subtracting([missing]))

		relay.withhold([])
		let second = await sync(relay, store)
		XCTAssertEqual(second, [missing], "the next run fetches exactly the id still missing")
		bootstrapped = try await store.bootstrapped()
		XCTAssertTrue(bootstrapped)
		held = try await heldIds(store)
		XCTAssertEqual(held, Set(relay.stored.map(\.id)))
	}

	func testNegErrFallsBackToThePagedWalk() async throws {
		let relay = FakeRelay()
		try await seed(relay, notes: 2)
		relay.failNegentropy(RelayError.negentropy("blocked: too many records"))
		let store = InMemoryChangeStore()

		let fetched = await sync(relay, store)
		XCTAssertEqual(fetched, [], "nothing is fetched by id without a reconciliation")
		XCTAssertTrue(relay.queryFilters.contains { $0.limit != nil && $0.kinds == [Engine.changeKind] && $0.authors == [key.pubkey] }, "the change stream is paged instead")
		let bootstrapped = try await store.bootstrapped()
		XCTAssertTrue(bootstrapped, "a complete paged walk still bootstraps")
		let objects = try await store.objectIds()
		XCTAssertEqual(objects.count, 2)
		let held = try await heldIds(store)
		XCTAssertEqual(held, Set(relay.stored.map(\.id)), "walked events are held too")

		relay.failNegentropy(nil)
		let after = await sync(relay, store)
		XCTAssertEqual(after, [], "once the relay reconciles again, nothing is missing")
	}

	func testPublishedEventsAreHeld() async throws {
		let relay = FakeRelay()
		let store = InMemoryChangeStore()
		let backend = Backend(key: key, relays: [relay], store: store)
		await backend.start()
		_ = try await backend.createNote(name: "mine", text: "local")
		await backend.awaitIdle()
		await backend.stop()
		let held = try await heldIds(store)
		XCTAssertEqual(held, Set(relay.stored.map(\.id)), "own publishes never come back as needed")
		let fetched = await sync(relay, store)
		XCTAssertEqual(fetched, [])
	}
}

/// Every status a stream yields, readable from the test.
private final class StatusTrail: @unchecked Sendable {
	private let lock = NSLock()
	private var seen: [SyncStatus] = []
	private var task: Task<Void, Never>?

	func follow(_ stream: AsyncStream<SyncStatus>) {
		task = Task { [weak self] in
			for await status in stream { self?.lock.withLock { self?.seen.append(status) } }
		}
	}

	deinit { task?.cancel() }

	var all: [SyncStatus] { lock.withLock { seen } }
}
