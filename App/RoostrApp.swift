import SwiftUI
import RoostrUI

/// iOS bundle entry (XcodeGen target `Roostr`); the scene lives in RoostrUI.
@main
struct RoostrIOSApp: App {
	private let app = RoostrApp()

	var body: some Scene { app.body }
}
