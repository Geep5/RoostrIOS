import SwiftUI

/// Identity gate: no key → `IdentityView`; key → the web editor. Returning
/// from the background reconnects sync: a suspended app's sockets can be dead
/// without knowing it.
public struct RoostrRootView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.scenePhase) private var scenePhase
	@State private var backgrounded = false

	public init() {}

	public var body: some View {
		Group {
			if !model.loaded {
				ProgressView("Loading identity…")
			} else if model.key == nil {
				IdentityView()
			} else {
				WebEditorView()
					.overlay(alignment: .bottom) {
						if model.showRemindersDebug {
							Text(model.remindersDebug)
								.font(.caption2.monospaced())
								.padding(4)
								.background(.thinMaterial)
								.accessibilityIdentifier("reminders-debug")
						}
					}
			}
		}
		.frame(minWidth: 360, minHeight: 420)
		.task { await model.start() }
		.onChange(of: scenePhase) { _, phase in
			switch phase {
			case .background:
				backgrounded = true
			case .active where backgrounded:
				backgrounded = false
				Task { await model.resume() }
			default:
				break
			}
		}
	}
}
