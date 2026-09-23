import Foundation
import GlonCore
@testable import RoostrSync

/// In-memory NIP-01 relay: stores accepted events, answers queries newest
/// first, fans published events out to matching live subscriptions.
final class FakeRelay: RelayClient, @unchecked Sendable {
	struct Rejecting: Error {}

	let url: URL
	private let lock = NSLock()
	private var events: [String: NostrEvent] = [:]
	private var subscriptions: [UUID: (filters: [NostrFilter], continuation: AsyncThrowingStream<NostrEvent, Error>.Continuation)] = [:]
	private var accepting = true
	private var queried: [NostrFilter] = []
	private var subscribed: [NostrFilter] = []

	init(url: URL = URL(string: "ws://fake.relay")!) {
		self.url = url
	}

	/// Every accepted event, oldest first.
	var stored: [NostrEvent] {
		lock.withLock { events.values.sorted { $0.created_at != $1.created_at ? $0.created_at < $1.created_at : $0.id < $1.id } }
	}

	var queryFilters: [NostrFilter] { lock.withLock { queried } }
	var subscribeFilters: [NostrFilter] { lock.withLock { subscribed } }

	func setAccepting(_ accepting: Bool) {
		lock.withLock { self.accepting = accepting }
	}

	func query(_ filters: [NostrFilter], timeout: Duration) async throws -> [NostrEvent] {
		lock.withLock {
			queried.append(contentsOf: filters)
			var matched = events.values.filter { event in filters.contains { Self.matches($0, event) } }
			matched.sort { $0.created_at != $1.created_at ? $0.created_at > $1.created_at : $0.id > $1.id }
			if let limit = filters.compactMap(\.limit).min(), matched.count > limit { matched.removeLast(matched.count - limit) }
			return matched
		}
	}

	func subscribe(_ filters: [NostrFilter]) -> AsyncThrowingStream<NostrEvent, Error> {
		let id = UUID()
		let (stream, continuation) = AsyncThrowingStream<NostrEvent, Error>.makeStream()
		lock.withLock {
			subscribed.append(contentsOf: filters)
			subscriptions[id] = (filters, continuation)
		}
		continuation.onTermination = { [weak self] _ in
			guard let self else { return }
			self.lock.withLock { _ = self.subscriptions.removeValue(forKey: id) }
		}
		return stream
	}

	func publish(_ event: NostrEvent, timeout: Duration) async throws {
		let listeners: [AsyncThrowingStream<NostrEvent, Error>.Continuation] = try lock.withLock {
			guard accepting else { throw Rejecting() }
			events[event.id] = event
			return subscriptions.values.filter { sub in sub.filters.contains { Self.matches($0, event) } }.map(\.continuation)
		}
		for listener in listeners { listener.yield(event) }
	}

	private static func matches(_ filter: NostrFilter, _ event: NostrEvent) -> Bool {
		if let ids = filter.ids, !ids.contains(event.id) { return false }
		if let authors = filter.authors, !authors.contains(event.pubkey) { return false }
		if let kinds = filter.kinds, !kinds.contains(event.kind) { return false }
		if let since = filter.since, event.created_at < since { return false }
		if let until = filter.until, event.created_at > until { return false }
		for (name, values) in filter.tagged {
			let present = event.tags.contains { $0.count > 1 && $0[0] == name && values.contains($0[1]) }
			if !present { return false }
		}
		return true
	}
}

/// Dictionary-backed ChangeStore with the browser store's semantics.
actor InMemoryChangeStore: ChangeStore {
	private var changes: [String: [ChangeRecord]] = [:]
	private var ids: Set<String> = []
	private var cursorValue: Int64 = 0
	private var groups: [(String, Int64)] = []
	private var bootstrappedFlag = false
	private var floor: Int64?
	private var pendings: [String: PendingPublish] = [:]
	private var published: Set<String> = []
	private var checkpoints: [String: CheckpointRecord] = [:]
	private var floors: [String: Int64] = [:]

	func addChanges(_ records: [ChangeRecord]) async throws -> Int {
		var added = 0
		for record in records where !ids.contains(record.id) {
			ids.insert(record.id)
			changes[record.objectId, default: []].append(record)
			added += 1
		}
		return added
	}

	func changesFor(objectId: String) async throws -> [ChangeRecord] { changes[objectId] ?? [] }
	func objectIds() async throws -> [String] { Array(Set(changes.keys).union(checkpoints.keys)) }

	func checkpoint(objectId: String) async throws -> CheckpointRecord? { checkpoints[objectId] }
	func putCheckpoint(_ record: CheckpointRecord) async throws -> Bool {
		if let existing = checkpoints[record.objectId], !(record.covered > existing.covered || (record.covered == existing.covered && record.hash > existing.hash)) { return false }
		checkpoints[record.objectId] = record
		return true
	}
	func checkpointFloors() async throws -> [String: Int64] { floors }
	func setCheckpointFloor(scope: String, _ floor: Int64) async throws { floors[scope] = floor }

	func cursor() async throws -> Int64 { cursorValue }
	func setCursor(_ cursor: Int64, replayGroups: [(String, Int64)]) async throws {
		cursorValue = cursor
		groups = replayGroups
	}
	func replayGroups() async throws -> [(String, Int64)] { groups }
	func bootstrapped() async throws -> Bool { bootstrappedFlag }
	func setBootstrapped() async throws { bootstrappedFlag = true }
	func bootstrapFloor() async throws -> Int64? { floor }
	func setBootstrapFloor(_ floor: Int64?) async throws { self.floor = floor }

	func pendingPublishes() async throws -> [PendingPublish] { Array(pendings.values) }
	func pending(key: String) async throws -> PendingPublish? { pendings[key] }
	func savePending(_ item: PendingPublish) async throws { pendings[item.key] = item }
	func isPublished(key: String) async throws -> Bool { published.contains(key) }
	func markPublished(key: String) async throws {
		published.insert(key)
		pendings[key] = nil
	}
}
