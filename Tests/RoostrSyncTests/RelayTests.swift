import Foundation
import XCTest
@testable import RoostrSync

/// Runs against the local RoostrRelay (`ws://127.0.0.1:7799`, open writes).
/// Skipped when nothing listens there.
final class RelayTests: XCTestCase {
	private static let url = URL(string: "ws://127.0.0.1:7799")!
	private static let timeout = Duration.seconds(5)

	private var relay: WebSocketRelay!
	private var key: NostrKey!

	override func setUp() async throws {
		relay = WebSocketRelay(url: Self.url)
		key = NostrKey.generate()
		let probe = try key.sign(kind: 1, createdAt: now(), tags: [], content: "probe")
		do { try await relay.publish(probe, timeout: Self.timeout) } catch let error as RelayError {
			throw error
		} catch {
			throw XCTSkip("relay unreachable at \(Self.url): \(error)")
		}
	}

	private func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

	private func publish(_ content: String, createdAt: Int64? = nil) async throws -> NostrEvent {
		let event = try key.sign(kind: 1, createdAt: createdAt ?? now(), tags: [], content: content)
		try await relay.publish(event, timeout: Self.timeout)
		return event
	}

	func testPublishThenQuery() async throws {
		let event = try await publish("hello ✓ \"quotes\" \\ \n\t")
		let found = try await relay.query([NostrFilter(authors: [key.pubkey], kinds: [1])], timeout: Self.timeout)
		XCTAssertTrue(found.contains(event))
		XCTAssertTrue(found.allSatisfy(NostrKey.verify))
	}

	func testQueryLimitReturnsExactlyOne() async throws {
		let first = try await publish("first", createdAt: now() - 10)
		// Strictly newer than the reachability probe, so no same-second tie-break decides the order.
		let second = try await publish("second", createdAt: now() + 2)
		let found = try await relay.query([NostrFilter(authors: [key.pubkey], kinds: [1], limit: 1)], timeout: Self.timeout)
		XCTAssertEqual(found.count, 1)
		XCTAssertEqual(found.first, second, "newest first")
		XCTAssertNotEqual(found.first, first)
	}

	func testQueryByIdAndUnknownIdIsEmpty() async throws {
		let event = try await publish("by id")
		let byId = try await relay.query([NostrFilter(ids: [event.id])], timeout: Self.timeout)
		XCTAssertEqual(byId, [event])
		let unknown = try await relay.query([NostrFilter(ids: [String(repeating: "0", count: 64)])], timeout: Self.timeout)
		XCTAssertEqual(unknown, [])
	}

	func testSubscribeReceivesLaterEvents() async throws {
		let stream = relay.subscribe([NostrFilter(authors: [key.pubkey], kinds: [1], since: now() - 1)])
		let received = Task { () -> NostrEvent? in
			for try await event in stream where event.content == "live" { return event }
			return nil
		}
		try await Task.sleep(for: .milliseconds(200))
		let live = try await publish("live")
		let got = try await withThrowingTaskGroup(of: NostrEvent?.self) { group in
			group.addTask { try await received.value }
			group.addTask { try await Task.sleep(for: Self.timeout); received.cancel(); return nil }
			let first = try await group.next()!
			group.cancelAll()
			return first
		}
		XCTAssertEqual(got, live)
	}

	func testPublishRejectsBadSignature() async throws {
		var event = try key.sign(kind: 1, createdAt: now(), tags: [], content: "forged")
		event.sig = String(repeating: "0", count: 128)
		do {
			try await relay.publish(event, timeout: Self.timeout)
			XCTFail("relay accepted an unsigned event")
		} catch RelayError.rejected {
		}
	}

	func testUnreachableRelayThrowsTransportError() async throws {
		let dead = WebSocketRelay(url: URL(string: "ws://127.0.0.1:1")!)
		for _ in 0..<2 {
			do {
				_ = try await dead.query([NostrFilter(kinds: [1], limit: 1)], timeout: Self.timeout)
				XCTFail("expected connection failure")
			} catch is RelayError {
				XCTFail("expected a transport error, not a relay answer")
			} catch {
			}
		}
	}

	func testSubscriptionFailsOnDisconnectAndNextCallRedials() async throws {
		let stream = relay.subscribe([NostrFilter(authors: [key.pubkey], kinds: [1])])
		let outcome = Task { () -> Bool in
			do {
				for try await _ in stream {}
				return false
			} catch {
				return true
			}
		}
		try await Task.sleep(for: .milliseconds(200))
		await relay.disconnect()
		let failed = await outcome.value
		XCTAssertTrue(failed, "live stream must finish with the transport error")
		// Same instance keeps working: a fresh dial on the next call.
		let event = try await publish("after failure")
		let found = try await relay.query([NostrFilter(ids: [event.id])], timeout: Self.timeout)
		XCTAssertEqual(found, [event])
	}
}
