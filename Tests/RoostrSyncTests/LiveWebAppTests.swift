import Foundation
import WebKit
import XCTest
@testable import RoostrSync

/// The real thing on macOS: the website's built `/app` bundle in a WKWebView,
/// the `ios` backend proxying over the bridge to a live `Backend`, a note
/// published through the engine and read back by the Svelte UI. Skips
/// without the bundle (`Scripts/build-web.sh`) or the local relay.
@MainActor
final class LiveWebAppTests: XCTestCase {
	private final class Host: WebBridgeHost {
		var backend: Backend?
		var key: NostrKey?
		func logout(exportPending: Bool) async throws {}
		func importKey(_ secret: String) async throws {}
		func setRelays(_ relays: [String]) async throws {}
	}

	private static let relayURL = URL(string: ProcessInfo.processInfo.environment["ROOSTR_TEST_RELAY"] ?? "ws://127.0.0.1:7799")!
	private static let bundle = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Web", isDirectory: true)

	override func setUp() async throws {
		guard FileManager.default.fileExists(atPath: Self.bundle.appendingPathComponent("200.html").path) else { throw XCTSkip("no web bundle at \(Self.bundle.path)") }
		do {
			_ = try await WebSocketRelay(url: Self.relayURL).query([NostrFilter(kinds: [1], limit: 1)], timeout: .seconds(2))
		} catch {
			throw XCTSkip("relay unreachable: \(error)")
		}
	}

	private func bodyText(_ webView: WKWebView) async -> String {
		await withCheckedContinuation { continuation in
			webView.evaluateJavaScript("document.body.innerText") { value, _ in continuation.resume(returning: value as? String ?? "") }
		}
	}

	func testSvelteAppRendersNotePublishedThroughTheEngine() async throws {
		let key = NostrKey.generate()
		let host = Host()
		host.key = key
		let backend = Backend(key: key, relays: [WebSocketRelay(url: Self.relayURL)], store: try SQLiteChangeStore.inMemory(), keyring: InMemorySpaceKeyring())
		host.backend = backend
		await backend.start()
		let bridge = WebBridge(host: host)
		let webView = bridge.makeWebView(bundleURL: Self.bundle)
		webView.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)

		// The web app creates its default space on first boot; a note scoped to
		// that space is what its list shows. Create one through the engine once
		// the space exists, then expect the page to pick it up via the commit event.
		var spaceId = ""
		let spaceDeadline = ContinuousClock.now + .seconds(20)
		while spaceId.isEmpty, ContinuousClock.now < spaceDeadline {
			spaceId = (try? await backend.channels().first?["id"]?.string ?? "") ?? ""
			if spaceId.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
		}
		XCTAssertFalse(spaceId.isEmpty, "web app created its first space over the bridge")
		let name = "Bridge note \(Int(Date().timeIntervalSince1970))"
		let created = try await backend.mutate(action: "create", params: .object([
			"name": .string(name), "type_key": .string("note"),
			"fields": .object(["channel": .object(["stringValue": .string(spaceId)])]),
		]))
		XCTAssertNotNil(created["id"]?.string)
		await backend.awaitIdle()
		let deadline = ContinuousClock.now + .seconds(30)
		var text = ""
		while ContinuousClock.now < deadline {
			text = await bodyText(webView)
			if text.contains(name) { break }
			try await Task.sleep(for: .milliseconds(200))
		}
		XCTAssertTrue(text.contains(name), "page text after load:\n\(text.prefix(600))")
		print("LIVE_WEB_APP rendered=\(text.contains(name)) chars=\(text.count)")
		bridge.detach()
		await backend.stop()
	}
}
