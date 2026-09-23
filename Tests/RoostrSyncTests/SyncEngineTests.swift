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

		let second = SyncEngine(key: key, relays: [relay], store: store)
		await second.start()
		await second.awaitIdle()
		// The live REQ also carries the gift-wrap filter; the personal one names our key.
		let live = try XCTUnwrap(relay.subscribeFilters.last { $0.authors != nil })
		XCTAssertEqual(live.since, cursor + 1)
		XCTAssertEqual(live.authors, [key.pubkey])
		XCTAssertEqual(live.kinds, [1078, 1079], "live carries changes and checkpoints")
		let walk = try XCTUnwrap(relay.queryFilters.last { $0.authors != nil && $0.kinds == [1078] })
		XCTAssertEqual(walk.since, cursor + 1)
		await second.stop()
	}
}
