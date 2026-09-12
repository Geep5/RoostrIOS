import Foundation
import XCTest
@testable import GlonCore

/// Shared-space authority fixtures shared with glonOdin/core/authority_fixtures.json,
/// the native daemon and the website: the `sync` method owns the authority gate
/// (who may create, edit, snapshot or delete inside a space) and the vanish-ledger
/// reader. Every replica must reach the same verdict for the same inputs.
final class AuthorityContractTests: XCTestCase {
	private struct Fixtures: Decodable {
		let authorize: [JSONValue]
		let vanished: [Vanished]
	}

	private struct Vanished: Decodable {
		let name: String
		let ledger: JSONValue
		let expected: [Vanish]
	}

	private struct Vanish: Decodable, Hashable {
		let objectId: String
		let at: Int64
	}

	private struct Ledger: Encodable {
		let action = "vanished"
		let ledger: JSONValue
	}

	private struct Verdict: Decodable {
		let ok: Bool
		let reason: String
	}

	private static let fixtures: Fixtures = {
		let url = Bundle.module.url(forResource: "authority_fixtures", withExtension: "json", subdirectory: "Fixtures")!
		return try! JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
	}()

	/// The fixture case minus its expectations, plus the dispatch action.
	private static func request(_ fixture: JSONValue) throws -> (name: String, payload: JSONValue) {
		guard case .object(var fields) = fixture, let name = fields["name"]?.string else { throw XCTSkip("fixture is not an object") }
		for key in ["name", "ok", "reason", "error"] { fields[key] = nil }
		fields["action"] = .string("authorize")
		return (name, .object(fields))
	}

	func testAuthorize() async throws {
		let fixtures = Self.fixtures.authorize
		XCTAssertEqual(fixtures.count, 36)
		var verdicts = 0
		for fixture in fixtures {
			let (name, payload) = try Self.request(fixture)
			if let expected = fixture["error"]?.string {
				do {
					let _: Verdict = try await GlonCore.shared.call("sync", payload)
					XCTFail("\(name): must throw")
				} catch {
					XCTAssertEqual(error as? GlonError, .engine(expected), name)
				}
				continue
			}
			let verdict: Verdict = try await GlonCore.shared.call("sync", payload)
			XCTAssertEqual(verdict.ok, fixture["ok"] == .bool(true), "\(name): ok")
			XCTAssertEqual(verdict.reason, fixture["reason"]?.string ?? "", "\(name): reason")
			verdicts += 1
		}
		print("AuthorityContractTests: \(verdicts) authorize verdicts checked")
	}

	func testAuthorizeRejectsNonObjectChange() async {
		let payload: JSONValue = .object([
			"action": .string("authorize"),
			"change": .string("not an object"),
			"provenance": .object(["spaceId": .string("s"), "keyId": .string("k"), "signer": .string(String(repeating: "ab", count: 32))]),
			"space": .object(["spaceId": .string("s"), "keyId": .string("k"), "owner": .string(String(repeating: "ab", count: 32))]),
			"trustedSpace": .null,
			"existing": .null,
		])
		do {
			let _: Verdict = try await GlonCore.shared.call("sync", payload)
			XCTFail("non-object change must be rejected")
		} catch {
			XCTAssertEqual(error as? GlonError, .engine("invalid change JSON"))
		}
	}

	func testVanished() async throws {
		let fixtures = Self.fixtures.vanished
		XCTAssertEqual(fixtures.count, 3)
		for fixture in fixtures {
			let vanished: [Vanish] = try await GlonCore.shared.call("sync", Ledger(ledger: fixture.ledger))
			XCTAssertEqual(vanished.count, fixture.expected.count, "\(fixture.name): count")
			XCTAssertEqual(Set(vanished), Set(fixture.expected), fixture.name)
		}
	}
}
