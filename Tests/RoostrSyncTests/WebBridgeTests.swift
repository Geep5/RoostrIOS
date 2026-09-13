import Foundation
import GlonCore
import WebKit
import XCTest
@testable import RoostrSync

/// The web view the editor runs in: the scheme handler serves the SPA
/// fallback, the platform marker is injected before any page script, and a
/// page message round-trips through the bridge to `__roostrReply`.
@MainActor
final class WebBridgeTests: XCTestCase {
	private final class Host: WebBridgeHost {
		var backend: Backend?
		var key: NostrKey? = NostrKey.generate()
		func logout(exportPending: Bool) async throws {}
		func importKey(_ secret: String) async throws {}
		func setRelays(_ relays: [String]) async throws {}
	}

	private final class Navigation: NSObject, WKNavigationDelegate {
		var finished: CheckedContinuation<Void, Never>?
		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			finished?.resume()
			finished = nil
		}
	}

	private var bundle: URL!

	override func setUpWithError() throws {
		bundle = FileManager.default.temporaryDirectory.appendingPathComponent("roostr-web-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
		let page = """
		<!doctype html><html><head><title>Roostr test shell</title></head><body>
		<script>
		document.body.textContent = "platform=" + globalThis.__ROOSTR_PLATFORM;
		window.__replies = {};
		window.__roostrReply = (id, ok, payload) => { window.__replies[id] = { ok, payload }; };
		window.webkit.messageHandlers.roostr.postMessage({ id: 1, method: "identity", args: [] });
		window.webkit.messageHandlers.roostr.postMessage({ id: 2, method: "nope", args: [] });
		</script></body></html>
		"""
		try page.write(to: bundle.appendingPathComponent("200.html"), atomically: true, encoding: .utf8)
		try "body{}".write(to: bundle.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: bundle)
	}

	private func evaluate(_ webView: WKWebView, _ script: String) async -> Any? {
		await withCheckedContinuation { continuation in
			webView.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value) }
		}
	}

	private func eventually(_ webView: WKWebView, _ script: String, timeout: Duration = .seconds(10)) async -> Any? {
		let deadline = ContinuousClock.now + timeout
		while ContinuousClock.now < deadline {
			if let value = await evaluate(webView, script), !(value is NSNull) { return value }
			try? await Task.sleep(for: .milliseconds(50))
		}
		return nil
	}

	func testSchemeHandlerResolvesFilesAndFallsBack() {
		let handler = RoostrSchemeHandler(root: bundle)
		XCTAssertEqual(handler.resolve("/style.css").lastPathComponent, "style.css")
		XCTAssertEqual(handler.resolve("/app").lastPathComponent, "200.html")
		XCTAssertEqual(handler.resolve("/app/object/abc").lastPathComponent, "200.html")
		XCTAssertEqual(handler.resolve("/").lastPathComponent, "200.html")
		XCTAssertEqual(handler.resolve("/../../etc/passwd").lastPathComponent, "200.html", "never escapes the bundle")
	}

	func testPageSeesPlatformAndBridgeRoundTrips() async throws {
		let host = Host()
		let bridge = WebBridge(host: host)
		let navigation = Navigation()
		let webView = bridge.makeWebView(bundleURL: bundle)
		webView.navigationDelegate = navigation
		XCTAssertEqual(webView.url, URL(string: "roostr://app/app"))
		await withCheckedContinuation { continuation in navigation.finished = continuation }

		let platform = await evaluate(webView, "window.__ROOSTR_PLATFORM")
		XCTAssertEqual(platform as? String, "ios")
		let title = await evaluate(webView, "document.title")
		XCTAssertEqual(title as? String, "Roostr test shell")
		let text = await evaluate(webView, "document.body.textContent")
		XCTAssertEqual(text as? String, "platform=ios")

		let identity = await eventually(webView, "window.__replies[1] || null")
		let reply = try XCTUnwrap(identity as? [String: Any])
		XCTAssertEqual(reply["ok"] as? Bool, true)
		let payload = try XCTUnwrap(reply["payload"] as? [String: Any])
		XCTAssertEqual(payload["pubkey"] as? String, host.key?.pubkey)
		let npub = try await Bech32.npub(host.key!.pubkey)
		XCTAssertEqual(payload["npub"] as? String, npub)

		let unknown = await eventually(webView, "window.__replies[2] || null")
		let failure = try XCTUnwrap(unknown as? [String: Any])
		XCTAssertEqual(failure["ok"] as? Bool, false)
		XCTAssertEqual((failure["payload"] as? [String: Any])?["message"] as? String, "unknown bridge method nope")
		bridge.detach()
	}
}
