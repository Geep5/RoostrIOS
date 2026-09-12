import CryptoKit
import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// Fixtures were produced with nostr-tools; ids, signatures and bech32 forms
/// must match byte for byte, and ECDH must feed the engine's NIP-44 key
/// derivation to the published test vectors.
final class NostrTests: XCTestCase {
	private struct Fixtures: Decodable {
		let secret: String
		let pubkey: String
		let npub: String
		let nsec: String
		let selfConversationKey: String
		let events: [NostrEvent]
		let invalid: [NostrEvent]
	}

	private struct Vectors: Decodable {
		struct V2: Decodable { let valid: Valid }
		struct Valid: Decodable { let get_conversation_key: [ConversationKey] }
		struct ConversationKey: Decodable { let sec1: String; let pub2: String; let conversation_key: String }
		let v2: V2
	}

	private struct ConversationKeyRequest: Encodable {
		let action = "conversation_key"
		let sharedX: String
	}

	private static func load<T: Decodable>(_ name: String, as type: T.Type) -> T {
		let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
		return try! JSONDecoder().decode(type, from: Data(contentsOf: url))
	}

	private static let fixtures = load("nostr_fixtures", as: Fixtures.self)
	private static let vectors = load("nip44_vectors", as: Vectors.self)

	private var key: NostrKey { try! NostrKey(secret: Hex.decode(Self.fixtures.secret)!) }

	func testPubkeyDerivation() throws {
		XCTAssertEqual(key.pubkey, Self.fixtures.pubkey)
		XCTAssertEqual(key.secretHex, Self.fixtures.secret)
	}

	func testRejectsInvalidSecrets() {
		XCTAssertThrowsError(try NostrKey(secret: Data(repeating: 1, count: 31)))
		XCTAssertThrowsError(try NostrKey(secret: Data(repeating: 0, count: 32)))
		XCTAssertThrowsError(try NostrKey(secret: Data(repeating: 0xff, count: 32)))
	}

	func testFixtureIdsAndSignatures() {
		for event in Self.fixtures.events {
			XCTAssertEqual(NostrEvent.computeId(pubkey: event.pubkey, createdAt: event.created_at, kind: event.kind, tags: event.tags, content: event.content), event.id, event.content)
			XCTAssertTrue(NostrKey.verify(event), event.content)
		}
		for event in Self.fixtures.invalid {
			XCTAssertFalse(NostrKey.verify(event))
		}
	}

	func testControlCharactersEscapeLikeJSONStringify() {
		// nostr-tools serialises through JSON.stringify: \u0001 and \u001f become \u00XX, DEL and non-ASCII stay raw.
		let content = "a\u{01}b\u{1f}c\u{7f}é"
		let canonical = "[0,\"\(Self.fixtures.pubkey)\",1,1,[],\"a\\u0001b\\u001fc\u{7f}é\"]"
		let expected = Hex.encode(Data(SHA256.hash(data: Data(canonical.utf8))))
		XCTAssertEqual(NostrEvent.computeId(pubkey: Self.fixtures.pubkey, createdAt: 1, kind: 1, tags: [], content: content), expected)
	}

	func testSignRoundTrip() throws {
		let event = try key.sign(kind: 1, createdAt: 1_700_000_100, tags: [["t", "ünï"]], content: "sign ✓ \"quoted\" \\ back\n\ttabs 🎉")
		XCTAssertEqual(event.pubkey, Self.fixtures.pubkey)
		XCTAssertEqual(event.sig.count, 128)
		XCTAssertTrue(NostrKey.verify(event))
		var tampered = event
		tampered.content += "!"
		XCTAssertFalse(NostrKey.verify(tampered))
		var forged = event
		forged.id = NostrEvent.computeId(pubkey: forged.pubkey, createdAt: forged.created_at, kind: forged.kind, tags: forged.tags, content: forged.content + "!")
		forged.content += "!"
		XCTAssertFalse(NostrKey.verify(forged))
	}

	func testGenerateProducesUsableKey() throws {
		let fresh = NostrKey.generate()
		XCTAssertEqual(fresh.secret.count, 32)
		XCTAssertEqual(fresh.pubkey.count, 64)
		XCTAssertTrue(NostrKey.verify(try fresh.sign(kind: 1, createdAt: 1, tags: [], content: "")))
		XCTAssertNotEqual(NostrKey.generate(), fresh)
	}

	func testBech32() async throws {
		let npubText = try await Bech32.npub(Self.fixtures.pubkey)
		XCTAssertEqual(npubText, Self.fixtures.npub)
		let nsecText = try await Bech32.nsec(key)
		XCTAssertEqual(nsecText, Self.fixtures.nsec)
		let decoded = try await Bech32.decode(Self.fixtures.nsec)
		XCTAssertEqual(decoded.hrp, "nsec")
		XCTAssertEqual(decoded.hex, Self.fixtures.secret)
		let npub = try await Bech32.decode(Self.fixtures.npub)
		XCTAssertEqual(npub.hrp, "npub")
		XCTAssertEqual(npub.hex, Self.fixtures.pubkey)
		do {
			_ = try await Bech32.decode("npub1garbage")
			XCTFail("expected invalid bech32 to throw")
		} catch GlonError.engine {
		}
	}

	func testSelfConversationKey() async throws {
		let sharedX = try key.sharedX(with: key.pubkey)
		XCTAssertEqual(sharedX.count, 32)
		let conversationKey: String = try await GlonCore.shared.call("wire", ConversationKeyRequest(sharedX: Hex.encode(sharedX)))
		XCTAssertEqual(conversationKey, Self.fixtures.selfConversationKey)
	}

	func testNIP44ConversationKeyVectors() async throws {
		let vectors = Self.vectors.v2.valid.get_conversation_key
		XCTAssertFalse(vectors.isEmpty)
		for vector in vectors {
			let sec1 = try NostrKey(secret: Hex.decode(vector.sec1)!)
			let sharedX = try sec1.sharedX(with: vector.pub2)
			let conversationKey: String = try await GlonCore.shared.call("wire", ConversationKeyRequest(sharedX: Hex.encode(sharedX)))
			XCTAssertEqual(conversationKey, vector.conversation_key, vector.pub2)
		}
	}

	func testSharedXRejectsOffCurveAndMalformedPubkeys() {
		XCTAssertThrowsError(try key.sharedX(with: "abc"))
		XCTAssertThrowsError(try key.sharedX(with: String(repeating: "ff", count: 32)))
	}

	func testInMemoryIdentityStore() throws {
		let store = InMemoryIdentityStore()
		XCTAssertNil(try store.load())
		try store.save(key)
		XCTAssertEqual(try store.load(), key)
		try store.clear()
		XCTAssertNil(try store.load())
	}
}
