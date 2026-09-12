import Foundation
import XCTest
import GlonCore
@testable import RoostrSync

/// End-to-end through real sockets: Backend → engine → WebSocketRelay →
/// RoostrRelay → a second Backend with an empty store. Skips when no relay
/// listens on ROOSTR_TEST_RELAY (default ws://127.0.0.1:7799).
final class LiveSyncTests: XCTestCase {
	private static let relayURL = URL(string: ProcessInfo.processInfo.environment["ROOSTR_TEST_RELAY"] ?? "ws://127.0.0.1:7799")!

	override func setUp() async throws {
		let probe = WebSocketRelay(url: Self.relayURL)
		do {
			_ = try await probe.query([NostrFilter(kinds: [1], limit: 1)], timeout: .seconds(2))
		} catch {
			throw XCTSkip("relay unreachable at \(Self.relayURL): \(error)")
		}
	}

	func testNoteRoundTripsBetweenTwoHosts() async throws {
		// A fixed key so the same vault can be inspected from the website engine.
		let secretHex = ProcessInfo.processInfo.environment["ROOSTR_TEST_SECRET"] ?? String(repeating: "5a", count: 32)
		let key = try NostrKey(secret: Hex.decode(secretHex)!)
		let name = "From the Swift host \(Int(Date().timeIntervalSince1970))"

		let writer = Backend(key: key, relays: [WebSocketRelay(url: Self.relayURL)], store: try SQLiteChangeStore.inMemory())
		await writer.start()
		let id = try await writer.createNote(name: name, text: "hello from swift")
		await writer.awaitIdle()
		await writer.stop()

		let reader = Backend(key: key, relays: [WebSocketRelay(url: Self.relayURL)], store: try SQLiteChangeStore.inMemory())
		await reader.start()
		await reader.awaitIdle()
		let objects = try await reader.objects()
		XCTAssertTrue(objects.contains { $0.id == id && $0.name == name }, "reader sees \(objects.map(\.name))")
		let object = try await reader.object(id: id)
		let texts = object["blocks"]?.array?.compactMap { $0["content"]?["text"]?["text"]?.string } ?? []
		XCTAssertEqual(texts, ["hello from swift"])
		await reader.stop()
		print("LIVE_SYNC_OBJECT \(id) \(name)")
	}
}
