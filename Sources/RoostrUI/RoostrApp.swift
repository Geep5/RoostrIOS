import SwiftUI

/// The app scene shared by the iOS bundle (App/) and the macOS runner (RoostrMac).
/// The model is a plain stored property (not `@State`) so the iOS entry can
/// forward to `body` from its own `App` without a second state container.
public struct RoostrApp: App {
	private let model = AppModel.standard()

	public init() {}

	public var body: some Scene {
		WindowGroup {
			RoostrRootView().environment(model)
		}
	}
}
