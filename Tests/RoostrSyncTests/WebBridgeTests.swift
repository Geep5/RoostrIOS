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
		window.webkit.messageHandlers.roostr.postMessage({ id: 3, method: "signEvent", args: [{ kind: 1, created_at: 1760000000, tags: [], content: "hi" }] });
		window.webkit.messageHandlers.roostr.postMessage({ id: 4, method: "signEvent", args: [{ kind: 24242, created_at: 1760000000, tags: [["t", "upload"], ["x", "ab".repeat(32)], ["expiration", "1760000600"]], content: "Upload a.txt" }] });
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

		let refusedValue = await eventually(webView, "window.__replies[3] || null")
		let refused = try XCTUnwrap(refusedValue as? [String: Any])
		XCTAssertEqual(refused["ok"] as? Bool, false)
		XCTAssertEqual((refused["payload"] as? [String: Any])?["message"] as? String, "signEvent only signs kind 24242 (Blossom authorization), not kind 1")
		let signedValue = await eventually(webView, "window.__replies[4] || null")
		let signedReply = try XCTUnwrap(signedValue as? [String: Any])
		XCTAssertEqual(signedReply["ok"] as? Bool, true)
		let signed = try JSONDecoder().decode(NostrEvent.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(signedReply["payload"])))
		XCTAssertEqual(signed.kind, 24242)
		XCTAssertEqual(signed.pubkey, host.key?.pubkey)
		XCTAssertEqual(signed.tags, [["t", "upload"], ["x", String(repeating: "ab", count: 32)], ["expiration", "1760000600"]])
		XCTAssertTrue(NostrKey.verify(signed), "the page gets a signed event it can put in a Blossom Authorization header")
		bridge.detach()
	}

	/// The page may have the identity sign Blossom authorizations (kind
	/// 24242) and nothing else: no change, base, message or deletion.
	func testSignEventSignsOnlyBlossomAuthorization() throws {
		let key = NostrKey.generate()
		func template(kind: Int64, createdAt: JSONValue = .int(1_760_000_000)) -> JSONValue {
			.object([
				"kind": .int(kind), "created_at": createdAt, "content": .string("Upload a.txt"),
				"tags": .array([.array([.string("t"), .string("upload")]), .array([.string("x"), .string(String(repeating: "cd", count: 32))])]),
			])
		}
		let signed = try WebBridge.signEvent(template(kind: 24242), key: key)
		XCTAssertEqual(signed.kind, 24242)
		XCTAssertEqual(signed.created_at, 1_760_000_000)
		XCTAssertEqual(signed.content, "Upload a.txt")
		XCTAssertEqual(signed.pubkey, key.pubkey)
		XCTAssertTrue(NostrKey.verify(signed))
		let now = Int64(Date().timeIntervalSince1970)
		let defaulted = try WebBridge.signEvent(template(kind: 24242, createdAt: .null), key: key)
		XCTAssertLessThanOrEqual(abs(defaulted.created_at - now), 5, "created_at defaults to now")
		for kind: Int64 in [0, 1, 5, 1059, 1078, 1079, 1080, 31078, 24241, 24243] {
			XCTAssertThrowsError(try WebBridge.signEvent(template(kind: kind), key: key)) { error in
				XCTAssertEqual(error as? WebBridgeError, .refused("signEvent only signs kind 24242 (Blossom authorization), not kind \(kind)"))
			}
		}
		XCTAssertThrowsError(try WebBridge.signEvent(.object(["kind": .int(24242), "tags": .array([]), "content": .int(1)]), key: key))
	}

	/// Pull-to-refresh end to end: a page subscribed through "start" asks for
	/// "syncNow"; the resume reconciles an event the live subscription could
	/// never deliver (created_at before the cursor), its object id reaches the
	/// page as a "commit" event and "fetchObject" serves the new state.
	func testSyncNowDeliversReconciledCommitToPage() async throws {
		let key = try XCTUnwrap(Host().key)
		func seed(_ relay: FakeRelay) async throws -> String {
			let backend = Backend(key: key, relays: [relay], store: InMemoryChangeStore())
			await backend.start()
			let id = try await backend.createNote(name: "From laptop", text: "late")
			await backend.awaitIdle()
			await backend.stop()
			return id
		}
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
		let backend = Backend(key: key, relays: [relay], store: store)
		await backend.start()
		await backend.awaitIdle()

		let page = """
		<!doctype html><html><head><title>Roostr refresh shell</title></head><body>
		<script>
		window.__replies = {};
		window.__commits = [];
		window.__roostrReply = (id, ok, payload) => { window.__replies[id] = { ok, payload }; };
		window.__roostrEvent = (name, payload) => { if (name === "commit") window.__commits.push(...payload); };
		window.__call = (id, method, args) => window.webkit.messageHandlers.roostr.postMessage({ id, method, args });
		window.__call(1, "start", []);
		</script></body></html>
		"""
		try page.write(to: bundle.appendingPathComponent("200.html"), atomically: true, encoding: .utf8)
		let host = Host()
		host.key = key
		host.backend = backend
		let bridge = WebBridge(host: host)
		let navigation = Navigation()
		let webView = bridge.makeWebView(bundleURL: bundle)
		webView.navigationDelegate = navigation
		await withCheckedContinuation { continuation in navigation.finished = continuation }
		let startReply = await eventually(webView, "window.__replies[1] || null")
		let started = try XCTUnwrap(startReply as? [String: Any])
		XCTAssertEqual(started["ok"] as? Bool, true)
		// "start" reconnects behind the reload; let that pass finish first.
		await backend.resume()

		// The offline laptop comes back: the relay accepts its older events, no live delivery.
		for event in laptop.stored { try await relay.publish(event, timeout: .seconds(1)) }
		try await Task.sleep(for: .milliseconds(200))
		let early = await evaluate(webView, "window.__commits.includes(\(String(reflecting: laptopId)))")
		XCTAssertEqual(early as? Bool, false)

		_ = await evaluate(webView, "window.__call(2, \"syncNow\", []); null")
		let syncReply = await eventually(webView, "window.__replies[2] || null")
		let synced = try XCTUnwrap(syncReply as? [String: Any])
		XCTAssertEqual(synced["ok"] as? Bool, true)
		XCTAssertEqual((synced["payload"] as? [String: Any])?["phase"] as? String, "live")
		let committed = await eventually(webView, "window.__commits.includes(\(String(reflecting: laptopId))) || null")
		XCTAssertEqual(committed as? Bool, true, "the reconciled object's commit reaches the page")

		_ = await evaluate(webView, "window.__call(3, \"fetchObject\", [\(String(reflecting: laptopId))]); null")
		let fetchReply = await eventually(webView, "window.__replies[3] || null")
		let fetched = try XCTUnwrap(fetchReply as? [String: Any])
		XCTAssertEqual(fetched["ok"] as? Bool, true)
		let object = try XCTUnwrap(fetched["payload"] as? [String: Any])
		XCTAssertEqual(object["id"] as? String, laptopId)
		bridge.detach()
		await backend.stop()
	}
}
