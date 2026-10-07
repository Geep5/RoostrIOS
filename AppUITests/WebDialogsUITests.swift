import XCTest

/// The web app asks for names with `prompt()` ("+ New space", the "+" next to
/// Types). WKWebView drops those dialogs unless the host presents them, so on
/// iOS both taps used to do nothing.
final class WebDialogsUITests: XCTestCase {
	func testNewSpaceAndNewTypeShowNamePrompts() throws {
		let app = XCUIApplication()
		app.launchEnvironment["ROOSTR_IDENTITY"] = "memory"
		app.launchEnvironment["ROOSTR_SECRET"] = String(repeating: "7c", count: 32)
		app.launchEnvironment["ROOSTR_RELAYS"] = "ws://127.0.0.1:9"
		app.launchEnvironment["ROOSTR_DB"] = NSTemporaryDirectory() + "roostr-uitest-\(UUID().uuidString).sqlite"
		app.launch()

		let newSpace = app.webViews.buttons["＋ New space"].firstMatch
		XCTAssertTrue(newSpace.waitForExistence(timeout: 30), "the Spaces screen shows New space")
		newSpace.tap()
		let spacePrompt = app.alerts.firstMatch
		XCTAssertTrue(spacePrompt.waitForExistence(timeout: 5), "New space opens the name prompt")
		XCTAssertTrue(spacePrompt.staticTexts["Space name:"].exists)
		spacePrompt.textFields.firstMatch.typeText("Dialogs")
		spacePrompt.buttons["OK"].tap()

		let space = app.webViews.buttons.matching(NSPredicate(format: "label CONTAINS 'Dialogs'")).firstMatch
		XCTAssertTrue(space.waitForExistence(timeout: 15), "the typed name created the space")
		space.tap()
		let newType = app.webViews.buttons["New type"].firstMatch
		XCTAssertTrue(newType.waitForExistence(timeout: 15), "the space pane shows the Types + button:\n\(app.debugDescription)")
		newType.tap()
		let typePrompt = app.alerts.firstMatch
		XCTAssertTrue(typePrompt.waitForExistence(timeout: 5), "Types + opens the name prompt")
		XCTAssertTrue(typePrompt.staticTexts["Type name:"].exists)
		typePrompt.buttons["Cancel"].tap()
		XCTAssertFalse(typePrompt.exists)
	}
}
