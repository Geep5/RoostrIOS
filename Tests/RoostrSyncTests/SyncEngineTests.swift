import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// The host loop around the engine's sync session, driven through an
/// in-memory relay and store. The session is process-global, so each scenario
/// stops its engines before the next one starts.
final class SyncEngineTests: XCTestCase {
	private let key = NostrKey.generate()

	/// Polls until `probe` yields a value.
	private func eventually<T>(timeout: Duration = .seconds(5), _ probe: () async throws -> T?) async throws -> T {
		let deadline = ContinuousClock.now + timeout
		while ContinuousClock.now < deadline {
			if let value = try await probe() { return value }
			try await Task.sleep(for: .milliseconds(20))
		}
		throw XCTestError(.timeoutWhileWaiting)
	}

	/// A backend on a fresh store creates one note and pushes it to `relay`.
	private func seed(_ relay: FakeRelay) async throws -> String {
		let backend = Backend(key: key, relays: [relay], store: InMemoryChangeStore())
		await backend.start()
		let id = try await backend.createNote(name: "Hello", text: "world")
		await backend.awaitIdle()
		await backend.stop()
		return id
	}

	func testNoteRoundTripsThroughRelay() async throws {
		let relay = FakeRelay()
		let id = try await seed(relay)

		let events = relay.stored
		XCTAssertGreaterThanOrEqual(events.count, 1)
		for event in events {
			XCTAssertEqual(event.kind, 1078)
			XCTAssertEqual(event.pubkey, key.pubkey)
			XCTAssertNotNil(event.tag("h"), "personal changes carry a blinded object tag")
			XCTAssertTrue(NostrKey.verify(event))
		}

		let reader = Backend(key: key, relays: [relay], store: InMemoryChangeStore())
		await reader.start()
		await reader.awaitIdle()
		let objects = try await reader.objects()
		XCTAssertEqual(objects.map(\.id), [id])
		XCTAssertEqual(objects.first?.name, "Hello")
		XCTAssertEqual(objects.first?.typeKey, "note")
		let object = try await reader.object(id: id)
		XCTAssertEqual(object["blocks"]?.array?.first?["content"]?["text"]?["text"]?.string, "world")
		await reader.stop()
	}

	func testRejectedPublishKeepsSignedEventsAndResendsThemUnchanged() async throws {
		let relay = FakeRelay()
		relay.setAccepting(false)
		let store = InMemoryChangeStore()
		let engine = SyncEngine(key: key, relays: [relay], store: store)
		await engine.start()

		let change: JSONValue = .object([
			"objectId": .string("note-1"),
			"parentIds": .array([]),
			"timestamp": .int(1),
			"author": .string("t"),
			"ops": .array([.object(["objectCreate": .object(["typeKey": .string("note")])])]),
		])
		let bytes = try await Engine.encode(change)
		let decoded = try await Engine.decode(bytes)
		let changeId = try XCTUnwrap(decoded["id"]?.string)
		try await engine.publish(bytes: bytes, changeId: changeId, objectId: "note-1")

		let pending = try await eventually { try await store.pending(key: changeId).flatMap { $0.events == nil ? nil : $0 } }
		let signed = try XCTUnwrap(pending.events)
		XCTAssertEqual(signed.count, 1)
		XCTAssertEqual(pending.bytes, bytes)
		XCTAssertTrue(relay.stored.isEmpty, "a rejecting relay holds nothing")
		let published = try await store.isPublished(key: changeId)
		XCTAssertFalse(published)

		relay.setAccepting(true)
		await engine.awaitIdle()
		let publishedAfter = try await store.isPublished(key: changeId)
		XCTAssertTrue(publishedAfter)
		let stillPending = try await store.pending(key: changeId)
		XCTAssertNil(stillPending)
		XCTAssertEqual(relay.stored, signed, "the retry resends the persisted events byte for byte")
		await engine.stop()
	}

	/// A relay that never answers EVENT (an unreachable public relay stuck in
	/// its handshake) used to hold every change for the whole wait: with one
	/// relay accepting, a change counts as sent at once.
	func testOneSilentRelayDoesNotHoldUpPublishing() async throws {
		let good = FakeRelay()
		let silent = SilentPublishRelay()
		let store = InMemoryChangeStore()
		let engine = SyncEngine(key: key, relays: [silent, good], store: store)
		await engine.start()

		let change: JSONValue = .object([
			"objectId": .string("note-1"),
			"parentIds": .array([]),
			"timestamp": .int(1),
			"author": .string("t"),
			"ops": .array([.object(["objectCreate": .object(["typeKey": .string("note")])])]),
		])
		let bytes = try await Engine.encode(change)
		let decoded = try await Engine.decode(bytes)
		let changeId = try XCTUnwrap(decoded["id"]?.string)
		let started = ContinuousClock.now
		try await engine.publish(bytes: bytes, changeId: changeId, objectId: "note-1")
		_ = try await eventually { try await store.isPublished(key: changeId) ? true : nil }
		XCTAssertLessThan(ContinuousClock.now - started, .seconds(3), "the accepting relay's OK is enough; the silent one is not awaited")
		XCTAssertEqual(good.stored.count, 1)
		await engine.stop()
	}

	func testRestartOnBootstrappedStoreSubscribesFromCursor() async throws {
		let relay = FakeRelay()
		_ = try await seed(relay)

		let store = InMemoryChangeStore()
		let first = SyncEngine(key: key, relays: [relay], store: store)
		await first.start()
		await first.awaitIdle()
		await first.stop()
		let bootstrapped = try await store.bootstrapped()
		XCTAssertTrue(bootstrapped, "a complete walk bootstraps the store")
		let cursor = try await store.cursor()
		XCTAssertEqual(cursor, relay.stored.last?.created_at)

		let fetchedBefore = relay.fetchedIds.count
		let second = SyncEngine(key: key, relays: [relay], store: store)
		await second.start()
		await second.awaitIdle()
		// The live REQ also carries the gift-wrap filter; the personal one names our key.
		let live = try XCTUnwrap(relay.subscribeFilters.last { $0.authors != nil })
		XCTAssertEqual(live.since, cursor + 1)
		XCTAssertEqual(live.authors, [key.pubkey])
		XCTAssertEqual(live.kinds, [1078, 1079], "live carries changes and checkpoints")
		let reconciled = try XCTUnwrap(relay.reconcileFilters.last { $0.authors != nil && $0.kinds == [1078] })
		XCTAssertNil(reconciled.since, "a restart reconciles the whole stream, not from the cursor")
		XCTAssertEqual(relay.fetchedIds.count, fetchedBefore, "everything is held: the restart fetches nothing")
		XCTAssertFalse(relay.queryFilters.contains { $0.limit != nil }, "no paged walk")
		await second.stop()
	}

	/// The phone holds the vault's history; a laptop change lands a second later
	/// while the phone's link is half-open and its own new note fails to publish.
	private struct HalfOpenScenario {
		let link: StallingRelay
		let store: InMemoryChangeStore
		let phone: Backend
		let laptopId: String
		/// Newest history event the phone imported, and the oldest laptop event it missed.
		let historyNewest: Int64
		let laptopOldest: Int64
		let statuses: StatusLog
	}

	private func halfOpenScenario() async throws -> HalfOpenScenario {
		let history = FakeRelay()
		_ = try await seed(history)
		// Strictly newer than the phone's cursor (created_at has 1 s resolution).
		try await Task.sleep(for: .milliseconds(1_100))
		let laptop = FakeRelay()
		let laptopId = try await seed(laptop)

		let relay = FakeRelay()
		for event in history.stored { try await relay.publish(event, timeout: .seconds(1)) }
		let link = StallingRelay(relay)
		let store = InMemoryChangeStore()
		let phone = Backend(key: key, relays: [link], store: store)
		await phone.start()
		await phone.awaitIdle()
		let statuses = StatusLog(await phone.statusUpdates())

		link.stall()
		_ = try await phone.createNote(name: "From phone", text: "sent while half-open")
		// The first attempt fails on the dead link and backs the item off (4 s).
		_ = try await eventually { try await store.pendingPublishes().first { $0.events != nil } }
		for event in laptop.stored { try await relay.publish(event, timeout: .seconds(1)) }
		try await Task.sleep(for: .milliseconds(100))
		let early = try await phone.objects().contains { $0.id == laptopId }
		XCTAssertFalse(early, "a half-open link delivers nothing")
		return HalfOpenScenario(link: link, store: store, phone: phone, laptopId: laptopId, historyNewest: history.stored.map(\.created_at).max()!, laptopOldest: laptop.stored.map(\.created_at).min()!, statuses: statuses)
	}

	/// Caught up from the cursor, own pending changes flushed well inside their backoff, indicator back to live.
	private func assertRecovered(_ s: HalfOpenScenario, within: Duration) async throws {
		_ = try await eventually(timeout: within) {
			let caughtUp = try await s.phone.objects().contains { $0.id == s.laptopId }
			let flushed = try await s.store.pendingPublishes().isEmpty
			return caughtUp && flushed ? true : nil
		}
		let live = try XCTUnwrap(s.link.relay.subscribeFilters.last { $0.authors != nil })
		let since = try XCTUnwrap(live.since)
		XCTAssertTrue(since > s.historyNewest && since <= s.laptopOldest, "the new subscription resumes from the cursor: since \(since), history \(s.historyNewest), laptop \(s.laptopOldest)")
		_ = try await eventually { s.statuses.last?.phase == .live ? true : nil }
		let seen = s.statuses.all
		let reconnecting = try XCTUnwrap(seen.firstIndex { $0.phase == .backfill && $0.detail?.hasPrefix("Reconnecting…") == true }, "\(seen)")
		XCTAssertTrue(seen[reconnecting...].contains { $0.phase == .live }, "the indicator returns to live: \(seen)")
	}

	func testResumeReconnectsHalfOpenLinkAtOnce() async throws {
		let s = try await halfOpenScenario()
		await s.phone.resume()
		// Inside the 4 s publish backoff and without the 2 s reconnect backoff.
		try await assertRecovered(s, within: .seconds(1.5))
		await s.phone.stop()
	}

	func testDroppedSocketReconnectsAndFlushesWithoutResume() async throws {
		let s = try await halfOpenScenario()
		// What the relay's keepalive does to a socket whose pong never comes.
		await s.link.disconnect()
		try await assertRecovered(s, within: .seconds(3.5))
		await s.phone.stop()
	}

	/// Events a cursor-based resubscribe can never deliver: created_at at or
	/// before the phone's cursor (a device that was offline publishing late, a
	/// skewed clock, the same second). Only a reconciliation finds them.
	func testResumeReconcilesEventsAtOrBeforeCursor() async throws {
		let laptop = FakeRelay()
		let laptopId = try await seed(laptop)
		try await Task.sleep(for: .milliseconds(1_100))
		let relay = FakeRelay()
		_ = try await seed(relay)

		// A restart on the bootstrapped store subscribes live from the cursor.
		let store = InMemoryChangeStore()
		let earlier = Backend(key: key, relays: [relay], store: store)
		await earlier.start()
		await earlier.awaitIdle()
		await earlier.stop()
		let phone = Backend(key: key, relays: [relay], store: store)
		await phone.start()
		await phone.awaitIdle()
		let commits = CommitLog(await phone.commitUpdates())
		let statuses = StatusLog(await phone.statusUpdates())
		let cursor = try XCTUnwrap(relay.stored.map(\.created_at).max())
		XCTAssertTrue(laptop.stored.allSatisfy { $0.created_at < cursor })

		// The offline laptop comes back: the relay accepts its older events.
		for event in laptop.stored { try await relay.publish(event, timeout: .seconds(1)) }
		try await Task.sleep(for: .milliseconds(200))
		let early = try await phone.objects().contains { $0.id == laptopId }
		XCTAssertFalse(early, "the live subscription starts after the cursor")

		await phone.resume()
		let caughtUp = try await phone.objects().contains { $0.id == laptopId }
		XCTAssertTrue(caughtUp, "resume reconciles and imports what the cursor skipped")
		_ = try await eventually { commits.ids.contains(laptopId) ? true : nil }
		XCTAssertEqual(statuses.last?.phase, .live)
		let seen = statuses.all
		let catching = try XCTUnwrap(seen.firstIndex { $0.phase == .backfill && $0.detail == "Catching up…" }, "\(seen)")
		XCTAssertTrue(seen[catching...].contains { $0.phase == .live }, "\(seen)")
		await phone.stop()
	}

	/// Two relays; the laptop reaches only the first, whose socket went
	/// half-open. Its event is lost to the live link, then a newer one on the
	/// second relay moves the cursor past it, so resubscribing from the cursor skips it.
	private struct SilentDeathScenario {
		let link: StallingRelay
		let phone: Backend
		let lostId: String
	}

	/// Seeds run first: each one's engine retires the session of any engine started before it.
	private func silentDeathScenario() async throws -> SilentDeathScenario {
		let history = FakeRelay()
		_ = try await seed(history)
		try await Task.sleep(for: .milliseconds(1_100))
		let lost = FakeRelay()
		let lostId = try await seed(lost)
		try await Task.sleep(for: .milliseconds(1_100))
		let newer = FakeRelay()
		let newerId = try await seed(newer)
		XCTAssertTrue(newer.stored.map(\.created_at).min()! > lost.stored.map(\.created_at).max()!)

		let first = FakeRelay(url: URL(string: "ws://first.relay")!)
		let second = FakeRelay(url: URL(string: "ws://second.relay")!)
		for event in history.stored {
			try await first.publish(event, timeout: .seconds(1))
			try await second.publish(event, timeout: .seconds(1))
		}
		let link = StallingRelay(first)
		let phone = Backend(key: key, relays: [link, second], store: InMemoryChangeStore())
		await phone.start()
		await phone.awaitIdle()

		link.stall()
		for event in lost.stored { try await first.publish(event, timeout: .seconds(1)) }
		for event in newer.stored { try await second.publish(event, timeout: .seconds(1)) }
		_ = try await eventually { try await phone.objects().contains { $0.id == newerId } ? true : nil }
		let early = try await phone.objects().contains { $0.id == lostId }
		XCTAssertFalse(early, "the half-open link delivered nothing")
		return SilentDeathScenario(link: link, phone: phone, lostId: lostId)
	}

	func testResumeRecoversEventsLostToHalfOpenSocket() async throws {
		let s = try await silentDeathScenario()
		await s.phone.resume()
		let caughtUp = try await s.phone.objects().contains { $0.id == s.lostId }
		XCTAssertTrue(caughtUp, "resume reconciles the stalled relay")
		await s.phone.stop()
	}

	func testDroppedSocketReconnectReconciles() async throws {
		let s = try await silentDeathScenario()
		// The keepalive finally fails the half-open socket; the live loop redials on its own.
		await s.link.disconnect()
		_ = try await eventually(timeout: .seconds(5)) { try await s.phone.objects().contains { $0.id == s.lostId } ? true : nil }
		await s.phone.stop()
	}
}

/// Every status a stream yields, readable from the test.
private final class StatusLog: @unchecked Sendable {
	private let lock = NSLock()
	private var seen: [SyncStatus] = []
	private var task: Task<Void, Never>?

	init(_ stream: AsyncStream<SyncStatus>) {
		task = Task { [weak self] in
			for await status in stream { self?.lock.withLock { self?.seen.append(status) } }
		}
	}

	deinit { task?.cancel() }

	var all: [SyncStatus] { lock.withLock { seen } }
	var last: SyncStatus? { lock.withLock { seen.last } }
}

/// Every object id a commit stream yields, readable from the test.
private final class CommitLog: @unchecked Sendable {
	private let lock = NSLock()
	private var seen: Set<String> = []
	private var task: Task<Void, Never>?

	init(_ stream: AsyncStream<[String]>) {
		task = Task { [weak self] in
			for await ids in stream { self?.lock.withLock { self?.seen.formUnion(ids) } }
		}
	}

	deinit { task?.cancel() }

	var ids: Set<String> { lock.withLock { seen } }
}

/// Answers reads like an empty relay but never answers a publish.
private final class SilentPublishRelay: RelayClient, @unchecked Sendable {
	let url = URL(string: "ws://silent.relay")!
	func query(_ filters: [NostrFilter], timeout: Duration) async throws -> [NostrEvent] { [] }
	func subscribe(_ filters: [NostrFilter]) -> AsyncThrowingStream<NostrEvent, Error> { AsyncThrowingStream { _ in } }
	func publish(_ event: NostrEvent, timeout: Duration) async throws { try await Task.sleep(for: .seconds(3600)) }
	func reconcile(_ filter: NostrFilter, local: NegentropyStorage, timeout: Duration) async throws -> [String] { throw RelayError.unsupported("test relay") }
	func disconnect() async {}
}
