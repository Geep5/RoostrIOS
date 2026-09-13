import SwiftUI

/// Identity gate: no key → `IdentityView`; key → the web editor.
public struct RoostrRootView: View {
	@Environment(AppModel.self) private var model

	public init() {}

	public var body: some View {
		Group {
			if !model.loaded {
				ProgressView("Loading identity…")
			} else if model.key == nil {
				IdentityView()
			} else {
				WebEditorView()
			}
		}
		.frame(minWidth: 360, minHeight: 420)
		.task { await model.start() }
	}
}
