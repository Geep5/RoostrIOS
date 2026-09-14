import XCTest

/// Runs the real app on a simulator against a vault holding one recurring
/// object: the permission alert is accepted on first need, one reminder is
/// pending for that object, and tapping a delivered notification opens it.
final class RemindersUITests: XCTestCase {
	func testRecurringObjectSchedulesAReminderAndTapOpensIt() throws {
		let env = ProcessInfo.processInfo.environment
		let objectId = try XCTUnwrap(env["ROOSTR_UITEST_OBJECT"], "set ROOSTR_UITEST_OBJECT")
		let app = XCUIApplication()
		app.launchEnvironment["ROOSTR_IDENTITY"] = "memory"
		app.launchEnvironment["ROOSTR_SECRET"] = try XCTUnwrap(env["ROOSTR_UITEST_SECRET"], "set ROOSTR_UITEST_SECRET")
		app.launchEnvironment["ROOSTR_RELAYS"] = env["ROOSTR_UITEST_RELAY"] ?? "ws://127.0.0.1:7799"
		app.launchEnvironment["ROOSTR_DB"] = NSTemporaryDirectory() + "roostr-uitest-\(UUID().uuidString).sqlite"
		app.launchEnvironment["ROOSTR_DEBUG_REMINDERS"] = "1"

		let monitor = addUIInterruptionMonitor(withDescription: "notifications") { alert in
			guard alert.buttons["Allow"].exists else { return false }
			alert.buttons["Allow"].tap()
			return true
		}
		defer { removeUIInterruptionMonitor(monitor) }
		app.launch()

		let label = app.staticTexts["reminders-debug"]
		let scheduled = NSPredicate(format: "label BEGINSWITH 'pending=1'")
		let deadline = Date().addingTimeInterval(90)
		while Date() < deadline, !scheduled.evaluate(with: label) {
			app.swipeUp() // any interaction lets the interruption monitor dismiss the alert
			_ = label.waitForExistence(timeout: 2)
		}
		XCTAssertTrue(scheduled.evaluate(with: label), "expected one pending reminder, saw: \(label.exists ? label.label : "<no label>")")
		XCTAssertTrue(label.label.contains(objectId), "reminder is for the seeded object")

		// A delivered notification (sent by the driver via `simctl push` when
		// ROOSTR_UITEST_PUSHED is set) is tapped and the editor opens the object.
		guard env["ROOSTR_UITEST_PUSHED"] == "1" else { return }
		let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
		let banner = springboard.otherElements["Notification"].firstMatch
		XCTAssertTrue(banner.waitForExistence(timeout: 90), "a notification banner arrived")
		banner.tap()
		let opened = app.webViews.staticTexts["Water the plants"].firstMatch
		XCTAssertTrue(opened.waitForExistence(timeout: 15), "the object page opened from the notification")
	}
}
