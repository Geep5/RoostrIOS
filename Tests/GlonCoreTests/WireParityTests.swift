import Foundation
import XCTest
@testable import GlonCore

/// Relay wire fixtures shared with glonOdin/core/wire_test.odin and the
/// website: NIP-44 v2, blinded tags, chunked sealing, opening and raw
/// content-address verification must match the TS reference byte for byte
/// through this bridge. Hosts keep only secp256k1 ECDH and event signing.
final class WireParityTests: XCTestCase {
	private struct Fixtures: Decodable {
		let blind: [Blind]
		let conversationKeys: [ConversationKey]
		let seal: [Seal]
		let open: [Open]
		let verify: [Verify]
	}

	private struct Blind: Decodable {
		let name: String
		let id: String
		let secret: String?
		let keyHex: String?
		let expected: String
	}

	private struct ConversationKey: Decodable {
		let sharedX: String
		let expected: String
	}

	private struct Seal: Decodable {
		let name: String
		let change: String
		let conversationKey: String
		let objectId: String
		let nonce: String?
		let secret: String?
		let space: Space?
		let expected: JSONValue
	}

	private struct Space: Codable {
		let keyHex: String
		let spaceId: String
	}

	private struct Open: Decodable {
		let name: String
		let content: String
		let conversationKey: String
		let error: Bool?
		let expected: String?
	}

	private struct Verify: Decodable {
		let name: String
		let bytes: String
		let gid: String?
		let error: Bool?
		let expectedId: String?
	}

	private struct Wire: Encodable {
		let action: String
		var sharedX: String? = nil
		var id: String? = nil
		var secret: String? = nil
		var keyHex: String? = nil
		var change: String? = nil
		var conversationKey: String? = nil
		var objectId: String? = nil
		var nonce: String? = nil
		var space: Space? = nil
		var content: String? = nil
		var bytes: String? = nil
		var gid: String? = nil
	}

	private struct Sealed: Decodable {
		let gid: String
		let parts: JSONValue
	}

	private struct Verified: Decodable {
		let id: String
		let change: JSONValue
	}

	private static let fixtures: Fixtures = {
		let url = Bundle.module.url(forResource: "wire_fixtures", withExtension: "json", subdirectory: "Fixtures")!
		return try! JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
	}()

	func testBlind() async throws {
		let fixtures = Self.fixtures.blind
		XCTAssertFalse(fixtures.isEmpty)
		for fixture in fixtures {
			let blind: String = try await GlonCore.shared.call("wire", Wire(action: "blind", id: fixture.id, secret: fixture.secret, keyHex: fixture.keyHex))
			XCTAssertEqual(blind, fixture.expected, fixture.name)
		}
	}

	func testConversationKeys() async throws {
		let fixtures = Self.fixtures.conversationKeys
		XCTAssertFalse(fixtures.isEmpty)
		for fixture in fixtures {
			let key: String = try await GlonCore.shared.call("wire", Wire(action: "conversation_key", sharedX: fixture.sharedX))
			XCTAssertEqual(key, fixture.expected, fixture.sharedX)
		}
	}

	func testSeal() async throws {
		let fixtures = Self.fixtures.seal
		XCTAssertEqual(fixtures.count, 2)
		for fixture in fixtures {
			let sealed: Sealed = try await GlonCore.shared.call("wire", Wire(
				action: "seal", secret: fixture.secret, change: fixture.change, conversationKey: fixture.conversationKey,
				objectId: fixture.objectId, nonce: fixture.nonce, space: fixture.space
			))
			XCTAssertEqual(sealed.gid, fixture.expected["gid"]?.string, "\(fixture.name): gid")
			XCTAssertEqual(sealed.parts, fixture.expected["parts"], "\(fixture.name): parts")
		}
	}

	func testSealRejectsChangeBeyondChunkLimit() async {
		let change = String(repeating: "A", count: 64 * 40_000 + 1)
		let secret = String(repeating: "7f", count: 32)
		do {
			let _: Sealed = try await GlonCore.shared.call("wire", Wire(action: "seal", secret: secret, change: change, conversationKey: secret, objectId: "x"))
			XCTFail("65 chunks must be rejected")
		} catch {
			XCTAssertEqual(error as? GlonError, .engine("change exceeds chunk limit"))
		}
	}

	func testOpen() async throws {
		let fixtures = Self.fixtures.open
		XCTAssertEqual(fixtures.count, 2)
		for fixture in fixtures {
			let request = Wire(action: "open", conversationKey: fixture.conversationKey, content: fixture.content)
			if fixture.error == true {
				do {
					let _: String = try await GlonCore.shared.call("wire", request)
					XCTFail("\(fixture.name): must throw")
				} catch {
					XCTAssertEqual(error as? GlonError, .engine("nip44 decrypt failed"), fixture.name)
				}
			} else {
				let part: String = try await GlonCore.shared.call("wire", request)
				XCTAssertEqual(part, fixture.expected, fixture.name)
			}
		}
	}

	func testVerify() async throws {
		let fixtures = Self.fixtures.verify
		let errors = ["tampered-body": "content address mismatch", "gid-match": "invalid protobuf change", "gid-mismatch": "chunk group id mismatch"]
		XCTAssertEqual(fixtures.filter { $0.error == true }.map(\.name).sorted(), errors.keys.sorted())
		for fixture in fixtures {
			let request = Wire(action: "verify", bytes: fixture.bytes, gid: fixture.gid)
			if let message = errors[fixture.name] {
				do {
					let _: Verified = try await GlonCore.shared.call("wire", request)
					XCTFail("\(fixture.name): must throw")
				} catch {
					XCTAssertEqual(error as? GlonError, .engine(message), fixture.name)
				}
			} else {
				let verified: Verified = try await GlonCore.shared.call("wire", request)
				XCTAssertEqual(verified.id, fixture.expectedId, "\(fixture.name): id")
				XCTAssertEqual(verified.change["id"]?.string, fixture.expectedId, "\(fixture.name): change id")
			}
		}
	}
}
