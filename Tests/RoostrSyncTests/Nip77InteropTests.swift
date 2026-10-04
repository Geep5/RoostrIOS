import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// NIP-77 against a local RoostrRelay (never a deployed one). Skipped unless
/// pointed at one:
///   ROOSTR_NIP77_SEEDED=<seeded.json> — a relay seeded by the relay repo's
///     NIP-77 seed script; reads `relay`, `pubkey`, `spaceTag` from the file.
///   ROOSTR_NIP77_RELAY=ws://127.0.0.1:<port> — a relay with open writes (or
///     no allowlist) the engine may publish fresh notes to.
final class Nip77InteropTests: XCTestCase {
	private static let timeout = Duration.seconds(15)

	private struct Seeded: Decodable {
		struct Item: Decodable {
			let id: String
			let created_at: Int64
		}

		let relay: String
		let pubkey: String
		let spaceTag: String
		/// Live (non-deleted) events per stream filter.
		let streams: [String: [Item]]
	}

	/// Each sync stream filter: an empty set needs the whole live stream, a
	/// full set needs nothing, a partial set needs exactly the gap.
	func testSeededRelayReconcilesEveryStreamFilter() async throws {
		guard let path = ProcessInfo.processInfo.environment["ROOSTR_NIP77_SEEDED"] else { throw XCTSkip("ROOSTR_NIP77_SEEDED not set") }
		let seeded = try JSONDecoder().decode(Seeded.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
		let relay = WebSocketRelay(url: URL(string: seeded.relay)!)
		let streams: [(String, NostrFilter)] = [
			("self1079", NostrFilter(authors: [seeded.pubkey], kinds: [Engine.checkpointKind])),
			("self1078", NostrFilter(authors: [seeded.pubkey], kinds: [Engine.changeKind])),
			("space1079", NostrFilter(kinds: [Engine.checkpointKind, Engine.deletionKind], tagged: ["h": [seeded.spaceTag]])),
			("space1078", NostrFilter(kinds: [Engine.changeKind], tagged: ["h": [seeded.spaceTag]])),
		]
		for (name, filter) in streams {
			let stored = try XCTUnwrap(seeded.streams[name], name)
			XCTAssertFalse(stored.isEmpty, name)
			let all = Set(stored.map(\.id))
			let fresh = try await relay.reconcile(filter, local: NegentropyStorage([]), timeout: Self.timeout)
			XCTAssertEqual(fresh.count, all.count, "each id once: \(name)")
			XCTAssertEqual(Set(fresh), all, "an empty set needs everything: \(name)")
			let full = try await relay.reconcile(filter, local: NegentropyStorage(stored.map { ($0.created_at, $0.id) }), timeout: Self.timeout)
			XCTAssertEqual(full, [], "a full set needs nothing: \(name)")
			let kept = stored.enumerated().filter { $0.offset % 5 != 0 }.map(\.element)
			let partial = try await relay.reconcile(filter, local: NegentropyStorage(kept.map { ($0.created_at, $0.id) }), timeout: Self.timeout)
			XCTAssertEqual(Set(partial), all.subtracting(kept.map(\.id)), "a partial set needs the gap: \(name)")
			// Fetching the need by id, as the engine does, returns every one of them.
			let missing = Array(all.subtracting(kept.map(\.id)).prefix(100))
			let fetched = try await relay.query([NostrFilter(ids: missing)], timeout: Self.timeout)
			XCTAssertEqual(Set(fetched.map(\.id)), Set(missing), "need ids are fetchable: \(name)")
		}
	}

	/// A fresh device reconciles to bootstrapped by fetching every event of
	/// ours once; a second run on the same store fetches nothing.
	func testFreshStoreReconcilesToBootstrappedThenFetchesNothing() async throws {
		guard let raw = ProcessInfo.processInfo.environment["ROOSTR_NIP77_RELAY"], let url = URL(string: raw) else { throw XCTSkip("ROOSTR_NIP77_RELAY not set") }
		let notes = Int(ProcessInfo.processInfo.environment["ROOSTR_NIP77_NOTES"] ?? "") ?? 150
		let key = NostrKey.generate()

		let author = Backend(key: key, relays: [WebSocketRelay(url: url)], store: InMemoryChangeStore())
		await author.start()
		for i in 0..<notes { _ = try await author.createNote(name: "interop \(i)", text: "body \(i)") }
		await author.awaitIdle()
		await author.stop()
		let published = try await Self.everything(NostrFilter(authors: [key.pubkey]), at: url)
		XCTAssertGreaterThanOrEqual(published.count, notes)

		let store = try SQLiteChangeStore.inMemory()
		let first = CountingRelay(WebSocketRelay(url: url))
		let engine = SyncEngine(key: key, relays: [first], store: store)
		await engine.start()
		await engine.awaitIdle()
		await engine.stop()
		var bootstrapped = try await store.bootstrapped()
		XCTAssertTrue(bootstrapped, "a complete reconciliation bootstraps")
		XCTAssertEqual(Set(first.fetchedIds), Set(published.map(\.id)))
		XCTAssertEqual(first.fetchedIds.count, published.count, "each event fetched once")
		XCTAssertEqual(first.pagedQueries, 0, "reconciled, never paged")
		XCTAssertGreaterThan(first.reconciles, 0)
		let objects = try await store.objectIds()
		XCTAssertEqual(objects.count, notes)

		let second = CountingRelay(WebSocketRelay(url: url))
		let again = SyncEngine(key: key, relays: [second], store: store)
		await again.start()
		await again.awaitIdle()
		await again.stop()
		bootstrapped = try await store.bootstrapped()
		XCTAssertTrue(bootstrapped)
		XCTAssertEqual(second.fetchedIds, [], "everything is held: nothing to fetch")
		XCTAssertEqual(second.pagedQueries, 0)
		XCTAssertGreaterThan(second.reconciles, 0)
		print("nip77 interop: \(published.count) events; first run fetched \(first.fetchedIds.count) in \(first.idQueries) batches, second run \(second.fetchedIds.count)")
	}

	/// Every stored match, paged newest first past the relay's per-REQ cap.
	private static func everything(_ filter: NostrFilter, at url: URL) async throws -> [NostrEvent] {
		let relay = WebSocketRelay(url: url)
		var byId: [String: NostrEvent] = [:]
		var until: Int64?
		while true {
			var page = filter
			page.until = until
			let events = try await relay.query([page], timeout: timeout)
			let before = byId.count
			for event in events { byId[event.id] = event }
			guard byId.count > before, let oldest = events.map(\.created_at).min() else { return Array(byId.values) }
			until = oldest
		}
	}
}

/// Counts what the engine asks a relay for.
private final class CountingRelay: RelayClient, @unchecked Sendable {
	private let relay: RelayClient
	private let lock = NSLock()
	private var ids: [String] = []
	private var idRequests = 0
	private var paged = 0
	private var reconciled = 0

	init(_ relay: RelayClient) { self.relay = relay }

	var url: URL { relay.url }
	var fetchedIds: [String] { lock.withLock { ids } }
	var idQueries: Int { lock.withLock { idRequests } }
	var pagedQueries: Int { lock.withLock { paged } }
	var reconciles: Int { lock.withLock { reconciled } }

	func query(_ filters: [NostrFilter], timeout: Duration) async throws -> [NostrEvent] {
		lock.withLock {
			let requested = filters.flatMap { $0.ids ?? [] }
			if !requested.isEmpty { idRequests += 1 }
			ids += requested
			if filters.contains(where: { $0.limit != nil }) { paged += 1 }
		}
		return try await relay.query(filters, timeout: timeout)
	}

	func subscribe(_ filters: [NostrFilter]) -> AsyncThrowingStream<NostrEvent, Error> { relay.subscribe(filters) }
	func publish(_ event: NostrEvent, timeout: Duration) async throws { try await relay.publish(event, timeout: timeout) }

	func reconcile(_ filter: NostrFilter, local: NegentropyStorage, timeout: Duration) async throws -> [String] {
		lock.withLock { reconciled += 1 }
		return try await relay.reconcile(filter, local: local, timeout: timeout)
	}

	func disconnect() async { await relay.disconnect() }
}
