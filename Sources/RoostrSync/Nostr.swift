import CryptoKit
import Foundation
import GlonCore
import P256K

// secp256k1 identity for the host: key derivation, NIP-01 event ids, BIP-340
// signing/verification and the raw ECDH x coordinate the engine turns into a
// NIP-44 conversation key. Everything else about the wire lives in the engine.

public enum NostrKeyError: Error, Equatable {
	case invalidSecret
	case invalidPubkey
	case invalidHex(String)
}

public enum Hex {
	private static let digits = Array("0123456789abcdef".utf8)

	public static func encode(_ data: Data) -> String {
		var out = [UInt8](repeating: 0, count: data.count * 2)
		var i = 0
		for byte in data {
			out[i] = digits[Int(byte >> 4)]
			out[i + 1] = digits[Int(byte & 0x0f)]
			i += 2
		}
		return String(decoding: out, as: UTF8.self)
	}

	/// Case-insensitive; nil on odd length or non-hex characters.
	public static func decode(_ hex: String) -> Data? {
		let utf8 = Array(hex.utf8)
		guard utf8.count % 2 == 0 else { return nil }
		var out = Data(capacity: utf8.count / 2)
		var i = 0
		while i < utf8.count {
			guard let high = nibble(utf8[i]), let low = nibble(utf8[i + 1]) else { return nil }
			out.append(high << 4 | low)
			i += 2
		}
		return out
	}

	private static func nibble(_ c: UInt8) -> UInt8? {
		switch c {
		case 0x30...0x39: return c - 0x30
		case 0x61...0x66: return c - 0x61 + 10
		case 0x41...0x46: return c - 0x41 + 10
		default: return nil
		}
	}
}

public struct NostrKey: Sendable, Equatable {
	/// 32-byte secret scalar.
	public let secret: Data
	/// x-only public key, lowercase hex.
	public let pubkey: String

	public var secretHex: String { Hex.encode(secret) }

	/// Rejects anything but a 32-byte scalar in `[1, n-1]`.
	public init(secret: Data) throws {
		guard secret.count == 32, let key = try? P256K.Schnorr.PrivateKey(dataRepresentation: secret) else {
			throw NostrKeyError.invalidSecret
		}
		self.secret = secret
		self.pubkey = Hex.encode(Data(key.xonly.bytes))
	}

	public static func generate() -> NostrKey {
		// Random 32 bytes fail the scalar check with probability < 2^-128; retry keeps the API total.
		while true {
			if let key = try? P256K.Schnorr.PrivateKey(), let made = try? NostrKey(secret: key.dataRepresentation) { return made }
		}
	}

	/// Signs the NIP-01 canonical form; `id` and `sig` are filled in.
	public func sign(kind: Int, createdAt: Int64, tags: [[String]], content: String) throws -> NostrEvent {
		let id = NostrEvent.computeId(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
		var message = [UInt8](Hex.decode(id)!)
		var aux = [UInt8](repeating: 0, count: 32)
		var rng = SystemRandomNumberGenerator()
		for i in aux.indices { aux[i] = rng.next() }
		let key = try P256K.Schnorr.PrivateKey(dataRepresentation: secret)
		let signature = try aux.withUnsafeMutableBytes { buffer in
			try key.signature(message: &message, auxiliaryRand: buffer.baseAddress, strict: true)
		}
		return NostrEvent(id: id, pubkey: pubkey, created_at: createdAt, kind: kind, tags: tags, content: content, sig: Hex.encode(signature.dataRepresentation))
	}

	/// 32-byte x coordinate of `secret * pubkey` — input for the engine's `wire conversation_key`.
	public func sharedX(with pubkeyHex: String) throws -> Data {
		guard let x = Hex.decode(pubkeyHex), x.count == 32 else { throw NostrKeyError.invalidPubkey }
		let mine = try P256K.KeyAgreement.PrivateKey(dataRepresentation: secret)
		let theirs: P256K.KeyAgreement.PublicKey
		do { theirs = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data([0x02]) + x, format: .compressed) } catch { throw NostrKeyError.invalidPubkey }
		let point = mine.sharedSecretFromKeyAgreement(with: theirs, format: .compressed)
		return point.withUnsafeBytes { Data($0.dropFirst()) }
	}

	/// Recomputes the id and checks the BIP-340 signature against `pubkey`.
	public static func verify(_ event: NostrEvent) -> Bool {
		guard event.id == NostrEvent.computeId(pubkey: event.pubkey, createdAt: event.created_at, kind: event.kind, tags: event.tags, content: event.content),
			let pk = Hex.decode(event.pubkey), pk.count == 32,
			let sig = Hex.decode(event.sig), let signature = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: sig),
			let id = Hex.decode(event.id)
		else { return false }
		var message = [UInt8](id)
		return P256K.Schnorr.XonlyKey(dataRepresentation: pk).isValid(signature, for: &message)
	}
}

public extension NostrEvent {
	/// sha256 of `[0,pubkey,created_at,kind,tags,content]` serialised exactly as
	/// NIP-01 / `JSON.stringify` do: no whitespace, only `"` `\` and control
	/// characters escaped, everything else (including non-ASCII) verbatim.
	static func computeId(pubkey: String, createdAt: Int64, kind: Int, tags: [[String]], content: String) -> String {
		var out = [UInt8]()
		out.reserveCapacity(96 + content.utf8.count + tags.count * 32)
		out.append(contentsOf: "[0,".utf8)
		appendString(pubkey, to: &out)
		out.append(UInt8(ascii: ","))
		out.append(contentsOf: String(createdAt).utf8)
		out.append(UInt8(ascii: ","))
		out.append(contentsOf: String(kind).utf8)
		out.append(contentsOf: ",[".utf8)
		for (i, tag) in tags.enumerated() {
			if i > 0 { out.append(UInt8(ascii: ",")) }
			out.append(UInt8(ascii: "["))
			for (j, value) in tag.enumerated() {
				if j > 0 { out.append(UInt8(ascii: ",")) }
				appendString(value, to: &out)
			}
			out.append(UInt8(ascii: "]"))
		}
		out.append(contentsOf: "],".utf8)
		appendString(content, to: &out)
		out.append(UInt8(ascii: "]"))
		return Hex.encode(Data(SHA256.hash(data: out)))
	}

	private static func appendString(_ value: String, to out: inout [UInt8]) {
		out.append(UInt8(ascii: "\""))
		for byte in value.utf8 {
			switch byte {
			case UInt8(ascii: "\""): out.append(contentsOf: "\\\"".utf8)
			case UInt8(ascii: "\\"): out.append(contentsOf: "\\\\".utf8)
			case 0x0a: out.append(contentsOf: "\\n".utf8)
			case 0x0d: out.append(contentsOf: "\\r".utf8)
			case 0x09: out.append(contentsOf: "\\t".utf8)
			case 0x08: out.append(contentsOf: "\\b".utf8)
			case 0x0c: out.append(contentsOf: "\\f".utf8)
			case 0..<0x20:
				out.append(contentsOf: "\\u00".utf8)
				out.append(Hex.digit(byte >> 4))
				out.append(Hex.digit(byte & 0x0f))
			default: out.append(byte)
			}
		}
		out.append(UInt8(ascii: "\""))
	}
}

extension Hex {
	fileprivate static func digit(_ nibble: UInt8) -> UInt8 { digits[Int(nibble)] }
}

/// npub/nsec encoding, delegated to the engine's `wire` method.
public enum Bech32 {
	private struct Encode: Encodable {
		let action = "bech32_encode"
		let hrp: String
		let hex: String
	}

	private struct Decode: Encodable {
		let action = "bech32_decode"
		let text: String
	}

	private struct Decoded: Decodable {
		let hrp: String
		let hex: String
	}

	public static func npub(_ pubkeyHex: String) async throws -> String {
		try await GlonCore.shared.call("wire", Encode(hrp: "npub", hex: pubkeyHex))
	}

	public static func nsec(_ key: NostrKey) async throws -> String {
		try await GlonCore.shared.call("wire", Encode(hrp: "nsec", hex: key.secretHex))
	}

	public static func decode(_ text: String) async throws -> (hrp: String, hex: String) {
		let decoded: Decoded = try await GlonCore.shared.call("wire", Decode(text: text))
		return (decoded.hrp, decoded.hex)
	}
}
