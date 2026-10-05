import Foundation
import XCTest
import GlonCore

/// The replay cache trusts `GlonCore.sourceFingerprint` to name the linked
/// engine: a framework rebuilt without bumping it would serve states an older
/// core replayed.
final class VendorFingerprintTests: XCTestCase {
	func testSourceFingerprintMatchesVendoredFramework() throws {
		let manifest = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("Vendor/glon-core.json")
		let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
		XCTAssertEqual(json?["sourceFingerprint"] as? String, GlonCore.sourceFingerprint, "update GlonCore.sourceFingerprint after rebuilding Vendor/Glon.xcframework")
	}
}
