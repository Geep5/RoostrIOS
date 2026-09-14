import RoostrSync
import SwiftUI
import WebKit

/// The editor: the website's `/app` SPA in a `WKWebView`, bridged to this
/// process's `Backend`. Shown once an identity exists; the web layer holds
/// no data of its own.
public struct WebEditorView: View {
	@Environment(AppModel.self) private var model

	public init() {}

	public var body: some View {
		WebViewRepresentable(model: model)
	}

	/// A pending route (notification tap) is handed to the bridge once and cleared.
	static func consumeRoute(_ model: AppModel, _ bridge: WebBridge) {
		guard let route = model.pendingRoute else { return }
		bridge.navigate(to: route)
		Task { @MainActor in model.pendingRoute = nil }
	}

	/// Where the website's build lives: `ROOSTR_WEB` for the runner, the app
	/// bundle's `Web` folder reference, or `App/Web` next to this package when
	/// running from source (`swift run roostr-mac`).
	static func bundleURL() -> URL {
		if let path = ProcessInfo.processInfo.environment["ROOSTR_WEB"] { return URL(fileURLWithPath: path, isDirectory: true) }
		if let bundled = Bundle.main.url(forResource: "Web", withExtension: nil) { return bundled }
		return URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("App/Web", isDirectory: true)
	}
}

#if canImport(UIKit)
private struct WebViewRepresentable: UIViewRepresentable {
	let model: AppModel

	func makeCoordinator() -> WebBridge { WebBridge(host: model) }

	func makeUIView(context: Context) -> WKWebView {
		context.coordinator.makeWebView(bundleURL: WebEditorView.bundleURL())
	}

	func updateUIView(_ webView: WKWebView, context: Context) {
		WebEditorView.consumeRoute(model, context.coordinator)
	}

	static func dismantleUIView(_ webView: WKWebView, coordinator: WebBridge) {
		coordinator.detach()
	}
}
#else
private struct WebViewRepresentable: NSViewRepresentable {
	let model: AppModel

	func makeCoordinator() -> WebBridge { WebBridge(host: model) }

	func makeNSView(context: Context) -> WKWebView {
		context.coordinator.makeWebView(bundleURL: WebEditorView.bundleURL())
	}

	func updateNSView(_ webView: WKWebView, context: Context) {
		WebEditorView.consumeRoute(model, context.coordinator)
	}

	static func dismantleNSView(_ webView: WKWebView, coordinator: WebBridge) {
		coordinator.detach()
	}
}
#endif
