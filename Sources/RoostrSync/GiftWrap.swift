import Foundation
import GlonCore

// NIP-59 gift wrap, byte-compatible with nostr-tools/nip59: an unsigned
// rumor is sealed (kind 13, NIP-44 under sender↔recipient, signed by the
// sender) and the seal is wrapped (kind 1059, NIP-44 under a one-off key ↔
// recipient, signed by that key, tagged `p` recipient). Both created_at are
// randomized up to two days back so relays leak no timing. NIP-44 itself is
// the engine's `wire` method; the host only does ECDH and signing.

public enum GiftWrapError: Error, Equatable {
	case notWrap(Int)
	case notSeal(Int)
	case badSealSignature
	case rumorPubkeyMismatch
	case malformed(String)
}

/// Unsigned inner event; `id` is the NIP-01 hash over its fields.
public struct Rumor: Codable, Sendable, Equatable {
	public var id: String
	public var pubkey: String
	public var created_at: Int64
	public var kind: Int
	public var tags: [[String]]
	public var content: String
}

public enum GiftWrap {
	public static let sealKind = 13
	public static let wrapKind = 1059
	private static let twoDays: Int64 = 2 * 24 * 60 * 60

	private static let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .withoutEscapingSlashes
		return encoder
	}()
	private static let decoder = JSONDecoder()

	private static func now() -> Int64 { Int64((Date().timeIntervalSince1970).rounded()) }
	private static func randomNow() -> Int64 { now() - Int64.random(in: 0...twoDays) }

	/// Wrap `content` of `kind` from `sender` for the hex pubkey `recipient`.
	public static func wrap(kind: Int, content: String, tags: [[String]] = [], sender: NostrKey, recipient: String) async throws -> NostrEvent {
		let rumor = makeRumor(kind: kind, content: content, tags: tags, sender: sender)
		let seal = try await seal(rumor, sender: sender, recipient: recipient)
		return try await wrap(seal, recipient: recipient)
	}

	static func makeRumor(kind: Int, content: String, tags: [[String]], sender: NostrKey) -> Rumor {
		let createdAt = now()
		let id = NostrEvent.computeId(pubkey: sender.pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
		return Rumor(id: id, pubkey: sender.pubkey, created_at: createdAt, kind: kind, tags: tags, content: content)
	}

	static func seal(_ rumor: Rumor, sender: NostrKey, recipient: String) async throws -> NostrEvent {
		let plaintext = String(decoding: try encoder.encode(rumor), as: UTF8.self)
		let content = try await Engine.encrypt(plaintext, conversationKey: try conversationKey(sender, recipient))
		return try sender.sign(kind: sealKind, createdAt: randomNow(), tags: [], content: content)
	}

	static func wrap(_ seal: NostrEvent, recipient: String) async throws -> NostrEvent {
		let ephemeral = NostrKey.generate()
		let plaintext = String(decoding: try encoder.encode(seal), as: UTF8.self)
		let content = try await Engine.encrypt(plaintext, conversationKey: try conversationKey(ephemeral, recipient))
		return try ephemeral.sign(kind: wrapKind, createdAt: randomNow(), tags: [["p", recipient]], content: content)
	}

	/// Reverse of `wrap` for the recipient; verifies the seal's signature and
	/// that the rumor claims the sealer's pubkey (nostr-tools unwrapEvent).
	public static func unwrap(_ wrap: NostrEvent, recipient: NostrKey) async throws -> Rumor {
		guard wrap.kind == wrapKind else { throw GiftWrapError.notWrap(wrap.kind) }
		let sealJSON = try await Engine.decrypt(wrap.content, conversationKey: try conversationKey(recipient, wrap.pubkey))
		let seal: NostrEvent
		do { seal = try decoder.decode(NostrEvent.self, from: Data(sealJSON.utf8)) } catch { throw GiftWrapError.malformed("seal: \(error)") }
		guard seal.kind == sealKind else { throw GiftWrapError.notSeal(seal.kind) }
		guard NostrKey.verify(seal) else { throw GiftWrapError.badSealSignature }
		let rumorJSON = try await Engine.decrypt(seal.content, conversationKey: try conversationKey(recipient, seal.pubkey))
		let rumor: Rumor
		do { rumor = try decoder.decode(Rumor.self, from: Data(rumorJSON.utf8)) } catch { throw GiftWrapError.malformed("rumor: \(error)") }
		guard rumor.pubkey == seal.pubkey else { throw GiftWrapError.rumorPubkeyMismatch }
		return rumor
	}

	private static func conversationKey(_ key: NostrKey, _ pubkey: String) async throws -> String {
		try await Engine.conversationKey(sharedX: try key.sharedX(with: pubkey))
	}
}

// ── wire helpers the shared-space host needs beyond Engine.swift ──

extension Engine {
	/// NIP-44 v2 payload of `plaintext` under a hex conversation key.
	static func encrypt(_ plaintext: String, conversationKey: String) async throws -> String {
		try await call("wire", ["action": .string("encrypt"), "conversationKey": .string(conversationKey), "plaintext": .string(plaintext)])
	}

	static func decrypt(_ payload: String, conversationKey: String) async throws -> String {
		try await call("wire", ["action": .string("decrypt"), "conversationKey": .string(conversationKey), "payload": .string(payload)])
	}

	/// Shared-space blinded tag: sha256 of the key's hex text || id, first 16 hex.
	static func blind(keyHex: String, id: String) async throws -> String {
		try await call("wire", ["action": .string("blind"), "keyHex": .string(keyHex), "id": .string(id)])
	}

	/// Personal blinded tag: sha256 of the secret's hex text || id, first 16 hex.
	static func blind(secretHex: String, id: String) async throws -> String {
		try await call("wire", ["action": .string("blind"), "secret": .string(secretHex), "id": .string(id)])
	}
}
