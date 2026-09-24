import Foundation
import XCTest
@testable import GlonCore

/// Per-object serving fixtures shared with glonOdin/core/serving_fixtures.json:
/// which machine does an object's agent work, and why. The phone never serves
/// anything, but it renders the answer, so it must reach the same one.
final class ServingContractTests: XCTestCase {
	private struct Fixtures: Decodable {
		let resolve: [JSONValue]
	}

	private struct Serving: Decodable, Equatable {
		let machineId: String
		let reason: String
		let requires: [String]
		let candidates: [String]
	}

	private static func strings(_ value: JSONValue?) -> [String] {
		guard case .array(let items)? = value else { return [] }
		return items.compactMap(\.string)
	}

	private static let fixtures: Fixtures = {
		let url = Bundle.module.url(forResource: "serving_fixtures", withExtension: "json", subdirectory: "Fixtures")!
		return try! JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
	}()

	func testResolve() async throws {
		let fixtures = Self.fixtures.resolve
		XCTAssertEqual(fixtures.count, 18)
		for fixture in fixtures {
			guard case .object(var fields) = fixture, let name = fields["name"]?.string else { continue }
			let expected = fields["expected"]
			let expectedError = fields["error"]?.string
			for key in ["name", "expected", "error"] { fields[key] = nil }
			fields["action"] = .string("resolve")
			if let expectedError {
				do {
					let _: Serving = try await GlonCore.shared.call("serving", JSONValue.object(fields))
					XCTFail("\(name): must throw")
				} catch {
					XCTAssertEqual(error as? GlonError, .engine(expectedError), name)
				}
				continue
			}
			let serving: Serving = try await GlonCore.shared.call("serving", JSONValue.object(fields))
			XCTAssertEqual(serving.machineId, expected?["machineId"]?.string, name)
			XCTAssertEqual(serving.reason, expected?["reason"]?.string, name)
			XCTAssertEqual(serving.requires, Self.strings(expected?["requires"]), name)
			XCTAssertEqual(serving.candidates, Self.strings(expected?["candidates"]), name)
		}
	}
}
