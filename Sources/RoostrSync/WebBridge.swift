import Foundation
import GlonCore
import WebKit

// The website's `/app` SPA runs in a WKWebView and talks to this process over
// one message handler; its `ios` backend is a thin proxy of the same contract
// the browser backend exposes. The web layer keeps zero data: key, store,
// relays and engine stay in Swift.
//
//   JS → Swift   window.webkit.messageHandlers.roostr.postMessage({id, method, args})
//   Swift → JS   window.__roostrReply(id, ok, payload)   payload = result, or {message} when !ok
//                window.__roostrEvent("status" | "commit", payload)

/// The relay list the website keeps in `localStorage["roostr-relays"]`. It
/// lives outside the replica on purpose: the backend is built from it and
/// logout destroys the database but keeps the user's relay choice.
public enum RelaySettings {
	private static let key = "roostr-relays"

	/// `ROOSTR_RELAYS=wss://a,wss://b` overrides the built-in default for the developer runner.
	public static var defaults: [String] {
		let env = ProcessInfo.processInfo.environment["ROOSTR_RELAYS"] ?? "wss://roostr-relay.fly.dev"
		return env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
	}

	/// Never-configured devices get the default; a stored list, even empty, is the user's choice.
	public static func load() -> [String] {
		UserDefaults.standard.stringArray(forKey: key) ?? defaults
	}

	public static func save(_ relays: [String]) {
		UserDefaults.standard.set(relays, forKey: key)
	}
}

/// What the bridge needs from whoever owns the identity and the backend's
/// lifecycle (the app model): the web layer never starts or stops sync itself.
@MainActor
public protocol WebBridgeHost: AnyObject {
	var backend: Backend? { get }
	var key: NostrKey? { get }
	/// Stops sync, forgets the key and destroys the replica. Throws while unpublished changes remain unless `exportPending`.
	func logout(exportPending: Bool) async throws
	/// Logs the current identity out, then opens the vault under `secret` (`nsec1…` or 64 hex chars).
	func importKey(_ secret: String) async throws
	/// Persists the list and restarts sync against it.
	func setRelays(_ relays: [String]) async throws
}

public enum WebBridgeError: Error, CustomStringConvertible, Equatable {
	case notStarted
	case unknownMethod(String)
	case badArgument(String)

	public var description: String {
		switch self {
		case .notStarted: return "no key"
		case .unknownMethod(let name): return "unknown bridge method \(name)"
		case .badArgument(let detail): return "bad bridge argument: \(detail)"
		}
	}
}

/// Website `SyncStatus` (`backend.ts`).
private struct BridgeStatus: Encodable {
	let phase: String
	let imported: Int
	let pending: Int
	let detail: String?
	let bootstrapped: Bool

	init(_ status: SyncStatus, bootstrapped: Bool) {
		phase = status.phase.rawValue
		imported = status.imported
		pending = status.pending
		detail = status.detail
		self.bootstrapped = bootstrapped
	}
}

private struct Request: Decodable {
	let id: Int
	let method: String
	let args: [JSONValue]?
}

private struct Failure: Encodable {
	let message: String
}

private struct AnyEncodable: Encodable {
	let value: any Encodable

	func encode(to encoder: Encoder) throws {
		try value.encode(to: encoder)
	}
}

@MainActor
public final class WebBridge: NSObject, WKScriptMessageHandler {
	public static let scheme = "roostr"
	public static let handlerName = "roostr"
	public static let startURL = URL(string: "roostr://app/app")!
	/// Selects the website's `ios` backend; explicit, like `VITE_ROOSTR_BACKEND`.
	public static let platformScript = "window.__ROOSTR_PLATFORM = \"ios\";"

	private let host: WebBridgeHost
	private weak var webView: WKWebView?
	private var listeners: [Task<Void, Never>] = []
	private let encoder = JSONEncoder()
	private let decoder = JSONDecoder()

	public init(host: WebBridgeHost) {
		self.host = host
	}

	/// A web view serving `bundleURL` (the website's static build) under
	/// `roostr://app/`, with the platform marker injected at document start
	/// and this bridge as the `roostr` message handler. Loads `startURL`.
	public func makeWebView(bundleURL: URL) -> WKWebView {
		let configuration = WKWebViewConfiguration()
		configuration.setURLSchemeHandler(RoostrSchemeHandler(root: bundleURL), forURLScheme: Self.scheme)
		let content = configuration.userContentController
		content.addUserScript(WKUserScript(source: Self.platformScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
		content.add(self, name: Self.handlerName)
		let webView = WKWebView(frame: .zero, configuration: configuration)
		#if DEBUG
		webView.isInspectable = true
		#endif
		self.webView = webView
		webView.load(URLRequest(url: Self.startURL))
		return webView
	}

	/// Drops the event forwarders; call when the web view goes away.
	public func detach() {
		unsubscribe()
		webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
		webView = nil
	}

	// MARK: WKScriptMessageHandler

	public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
		let body = message.body
		Task {
			guard JSONSerialization.isValidJSONObject(body),
			      let data = try? JSONSerialization.data(withJSONObject: body),
			      let request = try? decoder.decode(Request.self, from: data)
			else { return }
			do {
				let payload = try await dispatch(request.method, request.args ?? [])
				reply(request.id, ok: true, payload)
			} catch {
				reply(request.id, ok: false, Failure(message: "\(error)"))
			}
		}
	}

	// MARK: Dispatch

	private func backend() throws -> Backend {
		guard let backend = host.backend else { throw WebBridgeError.notStarted }
		return backend
	}

	private func key() throws -> NostrKey {
		guard let key = host.key else { throw WebBridgeError.notStarted }
		return key
	}

	private func dispatch(_ method: String, _ args: [JSONValue]) async throws -> any Encodable {
		switch method {
		case "start":
			let backend = try backend()
			subscribe(backend)
			return await status(backend)
		case "stop":
			unsubscribe()
			return JSONValue.null
		case "status":
			return await status(try backend())
		case "logout":
			try await host.logout(exportPending: args.first?.bool ?? false)
			return JSONValue.null
		case "relays":
			return RelaySettings.load()
		case "setRelays":
			try await host.setRelays(try strings(args, 0, "setRelays list"))
			// The vault reopened under a new backend; keep the page's event feed alive.
			if !listeners.isEmpty, let backend = host.backend { subscribe(backend) }
			return JSONValue.null
		case "fetchObject":
			return try await backend().object(id: try string(args, 0, "fetchObject id"))
		case "fetchObjects":
			return try await backend().summaries()
		case "fetchChannels":
			return try await backend().channels()
		case "fetchRelations":
			return try await backend().relations()
		case "fetchQuery":
			return try await backend().query(body: try object(args, 0, "fetchQuery body"))
		case "mutate":
			let action = try string(args, 0, "mutate action")
			let params = args.count > 1 ? args[1] : .object([:])
			guard case .object(var result) = try await backend().mutate(action: action, params: params) else { return JSONValue.object(["ok": .bool(true)]) }
			result["ok"] = .bool(true)
			return JSONValue.object(result)
		case "syncDigest":
			return try await backend().syncDigest()
		case "identity":
			let key = try key()
			return ["pubkey": key.pubkey, "npub": try await Bech32.npub(key.pubkey)]
		case "exportKey":
			let key = try key()
			return ["nsec": try await Bech32.nsec(key), "hex": key.secretHex]
		case "importKey":
			try await host.importKey(try string(args, 0, "importKey secret"))
			return JSONValue.null
		case "joinRequests":
			return try await backend().joinRequests()
		case "clearJoinRequest":
			try await backend().clearJoinRequest(key: try string(args, 0, "clearJoinRequest key"))
			return JSONValue.null
		case "sendJoinRequest":
			let link = try object(args, 0, "sendJoinRequest link")
			guard let space = link["space"]?.string, let owner = link["owner"]?.string else { throw WebBridgeError.badArgument("sendJoinRequest link needs space and owner") }
			let relays = link["relays"]?.array?.compactMap(\.string) ?? []
			try await backend().sendJoinRequest(space: space, owner: owner, relays: relays)
			return JSONValue.null
		case "importSpaceInvite":
			let invite = try object(args, 0, "importSpaceInvite invite")
			guard let space = invite["space"]?.string, let owner = invite["owner"]?.string, let key = invite["key"]?.string, let keyId = invite["keyId"]?.int else {
				throw WebBridgeError.badArgument("importSpaceInvite needs space, owner, key, keyId")
			}
			return try await backend().importSpaceInvite(space: space, owner: owner, key: key, keyId: keyId)
		default:
			throw WebBridgeError.unknownMethod(method)
		}
	}

	private func string(_ args: [JSONValue], _ index: Int, _ what: String) throws -> String {
		guard index < args.count, let value = args[index].string else { throw WebBridgeError.badArgument("\(what) must be a string") }
		return value
	}

	private func strings(_ args: [JSONValue], _ index: Int, _ what: String) throws -> [String] {
		guard index < args.count, let items = args[index].array else { throw WebBridgeError.badArgument("\(what) must be an array") }
		return try items.map { item in
			guard let value = item.string else { throw WebBridgeError.badArgument("\(what) must contain strings") }
			return value
		}
	}

	private func object(_ args: [JSONValue], _ index: Int, _ what: String) throws -> JSONValue {
		guard index < args.count, case .object = args[index] else { throw WebBridgeError.badArgument("\(what) must be an object") }
		return args[index]
	}

	// MARK: Status / events

	private func status(_ backend: Backend) async -> BridgeStatus {
		var current = SyncStatus(phase: .idle)
		// The stream yields the engine's last status on subscription.
		for await status in await backend.statusUpdates() {
			current = status
			break
		}
		return BridgeStatus(current, bootstrapped: await backend.bootstrapped())
	}

	private func subscribe(_ backend: Backend) {
		unsubscribe()
		listeners = [
			Task { [weak self] in
				for await status in await backend.statusUpdates() {
					let bootstrapped = await backend.bootstrapped()
					self?.event("status", BridgeStatus(status, bootstrapped: bootstrapped))
				}
			},
			Task { [weak self] in
				for await ids in await backend.commitUpdates() {
					self?.event("commit", ids)
				}
			},
		]
	}

	private func unsubscribe() {
		for task in listeners { task.cancel() }
		listeners = []
	}

	private func reply(_ id: Int, ok: Bool, _ payload: any Encodable) {
		guard let json = literal(payload) else { return }
		webView?.evaluateJavaScript("window.__roostrReply(\(id), \(ok), \(json));") { _, _ in }
	}

	private func event(_ name: String, _ payload: any Encodable) {
		guard let json = literal(payload) else { return }
		webView?.evaluateJavaScript("window.__roostrEvent(\"\(name)\", \(json));") { _, _ in }
	}

	/// JSON text is a JavaScript expression once the two line terminators
	/// JSON allows unescaped inside strings are escaped.
	private func literal(_ payload: any Encodable) -> String? {
		guard let data = try? encoder.encode(AnyEncodable(value: payload)) else { return nil }
		return String(decoding: data, as: UTF8.self)
			.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
			.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
	}
}

/// Serves the website's static build from a directory: `roostr://app/<path>`
/// → `<root>/<path>`; a missing file or a directory serves `200.html`, the
/// SPA fallback (`/app` is client-rendered).
public final class RoostrSchemeHandler: NSObject, WKURLSchemeHandler {
	private static let mimeTypes: [String: String] = [
		"html": "text/html", "js": "text/javascript", "css": "text/css", "wasm": "application/wasm",
		"json": "application/json", "png": "image/png", "webp": "image/webp", "svg": "image/svg+xml",
		"txt": "text/plain", "woff2": "font/woff2", "ico": "image/x-icon",
	]
	private let root: URL

	public init(root: URL) {
		self.root = root.standardizedFileURL
	}

	public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
		guard let url = task.request.url else { return }
		let file = resolve(url.path)
		do {
			let data = try Data(contentsOf: file)
			let mime = Self.mimeTypes[file.pathExtension.lowercased()] ?? "application/octet-stream"
			let headers = ["Content-Type": mime, "Content-Length": String(data.count), "Cache-Control": "no-store"]
			guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
			task.didReceive(response)
			task.didReceive(data)
			task.didFinish()
		} catch {
			task.didFailWithError(error)
		}
	}

	public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

	/// The file for a request path, or the SPA fallback. Paths never escape the root.
	func resolve(_ path: String) -> URL {
		let fallback = root.appendingPathComponent("200.html")
		let relative = path.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." }.joined(separator: "/")
		if relative.isEmpty { return fallback }
		let candidate = root.appendingPathComponent(relative).standardizedFileURL
		var directory: ObjCBool = false
		guard candidate.path.hasPrefix(root.path), FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory), !directory.boolValue else {
			return fallback
		}
		return candidate
	}
}
