import Foundation
import GlonCore
@testable import RoostrSync

/// In-memory NIP-01 relay: stores accepted events, answers queries newest
/// first, fans published events out to matching live subscriptions. NIP-77
/// runs the reference-exact `Negentropy` server side over the stored matches.
final class FakeRelay: RelayClient, @unchecked Sendable {
	struct Rejecting: Error {}

	let url: URL
	private let lock = NSLock()
	private var events: [String: NostrEvent] = [:]
	private var subscriptions: [UUID: (filters: [NostrFilter], continuation: AsyncThrowingStream<NostrEvent, Error>.Continuation)] = [:]
	private var accepting = true
	private var queried: [NostrFilter] = []
	private var subscribed: [NostrFilter] = []
	private var reconciled: [NostrFilter] = []
	private var negentropyFailure: Error?
	private var withheld: Set<String> = []

	init(url: URL = URL(string: "ws://fake.relay")!) {
		self.url = url
	}

	/// Every accepted event, oldest first.
	var stored: [NostrEvent] {
		lock.withLock { events.values.sorted { $0.created_at != $1.created_at ? $0.created_at < $1.created_at : $0.id < $1.id } }
	}

	var queryFilters: [NostrFilter] { lock.withLock { queried } }
	var subscribeFilters: [NostrFilter] { lock.withLock { subscribed } }
	var reconcileFilters: [NostrFilter] { lock.withLock { reconciled } }
	/// Ids requested by `REQ {ids}` so far.
	var fetchedIds: [String] { lock.withLock { queried.flatMap { $0.ids ?? [] } } }

	/// Every reconcile throws `failure` (e.g. `RelayError.negentropy` for NEG-ERR); nil restores NIP-77.
	func failNegentropy(_ failure: Error?) {
		lock.withLock { negentropyFailure = failure }
	}

	/// Queries leave these ids out though reconciliation still reports them.
	func withhold(_ ids: Set<String>) {
		lock.withLock { withheld = ids }
	}

	func setAccepting(_ accepting: Bool) {
		lock.withLock { self.accepting = accepting }
	}

	func query(_ filters: [NostrFilter], timeout: Duration) async throws -> [NostrEvent] {
		lock.withLock {
			queried.append(contentsOf: filters)
			var matched = events.values.filter { event in !withheld.contains(event.id) && filters.contains { Self.matches($0, event) } }
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

	func reconcile(_ filter: NostrFilter, local: NegentropyStorage, timeout: Duration) async throws -> [String] {
		let (failure, matched) = lock.withLock {
			reconciled.append(filter)
			return (negentropyFailure, events.values.filter { Self.matches(filter, $0) })
		}
		if let failure { throw failure }
		var server = try Negentropy(storage: NegentropyStorage(matched.map { ($0.created_at, $0.id) }))
		var client = try Negentropy(storage: local, frameSizeLimit: 250_000)
		var need: [String] = []
		var message = try client.initiate()
		while true {
			guard let reply = try server.reconcile(message).output else { throw RelayError.negentropy("no answer") }
			let step = try client.reconcile(reply)
			need += step.needIds
			guard let next = step.output else { return need }
			message = next
		}
	}

	/// Every live subscription fails as a dropped socket would; stored events stay.
	func disconnect() async {
		let dropped = lock.withLock {
			defer { subscriptions.removeAll() }
			return subscriptions.values.map(\.continuation)
		}
		for continuation in dropped { continuation.finish(throwing: URLError(.networkConnectionLost)) }
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

/// A link to `relay` that can go half-open, like a socket that outlived an app
/// suspension: while stalled, live subscriptions stay open but receive nothing
/// (events published meanwhile are lost to them) and queries and publishes
/// time out. `disconnect()` fails the open subscriptions; later calls dial a
/// working link again. Unlike `FakeRelay`, a subscription first replays the
/// stored matches, oldest first, as a relay answers a REQ before EOSE.
final class StallingRelay: RelayClient, @unchecked Sendable {
	let relay: FakeRelay
	var url: URL { relay.url }
	private let lock = NSLock()
	private var stalled = false
	private var lives: [UUID: AsyncThrowingStream<NostrEvent, Error>.Continuation] = [:]

	init(_ relay: FakeRelay) {
		self.relay = relay
	}

	func stall() {
		lock.withLock { stalled = true }
	}

	private var isStalled: Bool { lock.withLock { stalled } }

	func query(_ filters: [NostrFilter], timeout: Duration) async throws -> [NostrEvent] {
		if isStalled { throw RelayError.timeout }
		return try await relay.query(filters, timeout: timeout)
	}

	func reconcile(_ filter: NostrFilter, local: NegentropyStorage, timeout: Duration) async throws -> [String] {
		if isStalled { throw RelayError.timeout }
		return try await relay.reconcile(filter, local: local, timeout: timeout)
	}

	func subscribe(_ filters: [NostrFilter]) -> AsyncThrowingStream<NostrEvent, Error> {
		let id = UUID()
		let (stream, continuation) = AsyncThrowingStream<NostrEvent, Error>.makeStream()
		let upstream = relay.subscribe(filters)
		let forward = Task { [weak self, relay] in
			do {
				if self?.isStalled == false {
					for event in try await relay.query(filters, timeout: .seconds(1)).reversed() { continuation.yield(event) }
				}
				for try await event in upstream where self?.isStalled == false { continuation.yield(event) }
			} catch {
				continuation.finish(throwing: error)
			}
		}
		lock.withLock { lives[id] = continuation }
		continuation.onTermination = { [weak self] _ in
			forward.cancel()
			guard let self else { return }
			self.lock.withLock { _ = self.lives.removeValue(forKey: id) }
		}
		return stream
	}

	func publish(_ event: NostrEvent, timeout: Duration) async throws {
		if isStalled { throw RelayError.timeout }
		try await relay.publish(event, timeout: timeout)
	}

	func disconnect() async {
		let dropped = lock.withLock {
			stalled = false
			defer { lives.removeAll() }
			return Array(lives.values)
		}
		for continuation in dropped { continuation.finish(throwing: URLError(.networkConnectionLost)) }
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
	private var held: [String: HeldEvent] = [:]

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
	func forgetCheckpointFloors() async throws {}

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

	func recordHeld(_ events: [HeldEvent]) async throws {
		for event in events where held[event.id] == nil { held[event.id] = event }
	}

	func heldEvents(matching filter: NostrFilter) async throws -> [HeldEvent] {
		held.values.filter { event in
			if let kinds = filter.kinds, !kinds.contains(event.kind) { return false }
			if let authors = filter.authors, !authors.contains(event.author) { return false }
			if let tags = filter.tagged["h"], !tags.contains(event.hTag ?? "") { return false }
			if let since = filter.since, event.createdAt < since { return false }
			if let until = filter.until, event.createdAt > until { return false }
			return true
		}
	}

	var heldCount: Int { held.count }
}
