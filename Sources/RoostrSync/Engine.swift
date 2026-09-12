import Foundation
import GlonCore

// Typed calls into the Odin engine. Every domain rule lives there; these
// shape payloads and decode results, nothing more.

public enum EngineError: Error, Equatable {
	case malformed(String)
}

/// Replay obligation the receive session mirrors to the host: chunk key → earliest created_at.
public struct ReplayGroup: Decodable, Sendable, Equatable {
	public let key: String
	public let at: Int64

	public init(key: String, at: Int64) { self.key = key; self.at = at }

	public init(from decoder: Decoder) throws {
		var container = try decoder.unkeyedContainer()
		key = try container.decode(String.self)
		at = try container.decode(Int64.self)
	}
}

public struct SessionState: Decodable, Sendable {
	public let cursor: Int64
	public let groups: Int
	public let replayGroups: [ReplayGroup]
	public let replayFloor: Int64?
}

public struct SharedProvenance: Decodable, Sendable, Equatable {
	public let spaceId: String
	public let keyId: Int64
	public let signer: String
}

public struct IngestItem: Decodable, Sendable {
	/// Base64 wire bytes of the full change.
	public let bytes: String
	public let change: JSONValue
	public let chunkKey: String?
	public let provenance: SharedProvenance?
}

public struct IngestResult: Decodable, Sendable {
	public let cursor: Int64
	public let item: IngestItem?
	public let faultAt: Int64?
	public let replayGroups: [ReplayGroup]?
	public let decryptFailure: Bool?
	public let decodeFailure: Bool?
	public let hTag: String?
}

public struct SettleResult: Decodable, Sendable {
	public let replayGroups: [ReplayGroup]?
}

public struct AuthorizeResult: Decodable, Sendable {
	public let ok: Bool
	public let reason: String
}

public struct VanishedEntry: Decodable, Sendable, Equatable {
	public let objectId: String
	public let at: Int64
}

public struct SealedPart: Decodable, Sendable, Equatable {
	public let content: String
	public let tags: [[String]]
}

public struct SealedParts: Decodable, Sendable, Equatable {
	public let gid: String
	public let parts: [SealedPart]
}

/// One publish obligation handed out by the engine outbox; `sealed` only until the host reports `sealed: true`.
public struct OutboxItem: Decodable, Sendable {
	public let key: String
	public let objectId: String
	public let changeId: String
	public let attempts: Int
	public let spaceId: String?
	public let keyId: Int64?
	public let sealed: SealedParts?
}

public struct OutboxNext: Decodable, Sendable {
	public let item: OutboxItem?
	public let waitMs: Int64
	public let pending: Int
}

public struct EnqueueResult: Decodable, Sendable {
	public let queued: Bool
	public let reason: String?
	public let pending: Int
}

public struct OutboxResultOutcome: Decodable, Sendable {
	public let pending: Int
}

public struct MutationPlan: Decodable, Sendable {
	public let changes: [JSONValue]
	public let result: JSONValue
	public let vanishIds: [String]
	public let vanishChanges: [JSONValue]

	enum CodingKeys: String, CodingKey {
		case changes, result
		case vanishIds = "vanish_ids"
		case vanishChanges = "vanish_changes"
	}
}

public enum Engine {
	public static let changeKind = 1078

	static func call<R: Decodable>(_ method: String, _ payload: [String: JSONValue]) async throws -> R {
		try await GlonCore.shared.call(method, JSONValue.object(payload))
	}

	// ── codec ──

	/// Wire bytes → ChangeJSON in the engine's ordered-pair map form.
	public static func decode(_ bytes: Data) async throws -> JSONValue {
		try await call("codec", ["action": .string("decode"), "bytes": .string(bytes.base64EncodedString())])
	}

	/// Recomputes the content address and returns canonical protobuf bytes.
	public static func encode(_ change: JSONValue) async throws -> Data {
		let base64: String = try await call("codec", ["action": .string("encode"), "change": change])
		guard let bytes = Data(base64Encoded: base64) else { throw EngineError.malformed("codec encode returned invalid base64") }
		return bytes
	}

	public static func hash(_ change: JSONValue) async throws -> String {
		try await call("codec", ["action": .string("hash"), "change": change])
	}

	// ── replay / mutation ──

	/// Replayed ObjectJSON (plain maps), or nil when there are no changes.
	public static func replay(_ changes: [JSONValue]) async throws -> JSONValue? {
		if changes.isEmpty { return nil }
		return try await call("replay", ["changes": .array(changes)])
	}

	/// Head change ids: changes no other change lists as a parent.
	public static func heads(_ changes: [JSONValue]) async throws -> [String] {
		try await call("mutation", ["action": .string("heads"), "changes": .array(changes)])
	}

	public static func mutation(action: String, params: JSONValue, objects: [JSONValue], timestamp: Int64, author: String, idSeed: String, keyId: Int64) async throws -> MutationPlan {
		try await call("mutation", [
			"action": .string(action),
			"params": params,
			"objects": .array(objects),
			"timestamp": .int(timestamp),
			"author": .string(author),
			"id_seed": .string(idSeed),
			"key_id": .int(keyId),
		])
	}

	// ── wire ──

	/// NIP-44 conversation key (hex) from the 32-byte ECDH x coordinate.
	public static func conversationKey(sharedX: Data) async throws -> String {
		try await call("wire", ["action": .string("conversation_key"), "sharedX": .string(Hex.encode(sharedX))])
	}

	// ── sync ──

	public static func sync<R: Decodable>(_ action: String, _ fields: [String: JSONValue] = [:]) async throws -> R {
		var payload = fields
		payload["action"] = .string(action)
		return try await call("sync", payload)
	}

	/// Object ids the synced vanish ledger names.
	public static func vanished(ledger: JSONValue?) async throws -> [VanishedEntry] {
		try await sync("vanished", ["ledger": ledger ?? .null])
	}
}

// ── Core value maps (port of core-values.ts) ──
//
// Protobuf maps carry insertion order, unlike Odin's JSON object maps. Only
// schema map slots become ordered pairs; user map keys are never interpreted
// as schema properties. Transport encoding, not a second domain codec.

public func packCoreValueMaps(_ value: JSONValue) -> JSONValue {
	transformCoreValue(value, unpack: false)
}

public func unpackCoreValueMaps(_ value: JSONValue) -> JSONValue {
	transformCoreValue(value, unpack: true)
}

private func mapSlot(_ value: JSONValue, unpack: Bool, strings: Bool) -> JSONValue {
	if unpack {
		guard case .array(let pairs) = value else { return value }
		var out: [String: JSONValue] = [:]
		out.reserveCapacity(pairs.count)
		for pair in pairs {
			guard case .array(let kv) = pair, kv.count == 2, case .string(let key) = kv[0] else { continue }
			out[key] = strings ? kv[1] : transformCoreValue(kv[1], unpack: true)
		}
		return .object(out)
	}
	guard case .object(let fields) = value else { return value }
	return .array(fields.map { key, item in .array([.string(key), strings ? item : transformCoreValue(item, unpack: false)]) })
}

private func transformCoreValue(_ value: JSONValue, unpack: Bool, slot: String = "") -> JSONValue {
	switch value {
	case .array(let items):
		return .array(items.map { transformCoreValue($0, unpack: unpack, slot: slot) })
	case .object(let fields):
		var out: [String: JSONValue] = [:]
		out.reserveCapacity(fields.count)
		for (key, item) in fields {
			switch key {
			case "entries":
				// ValueMap's only field. Its keys are opaque: never recurse into the dictionary itself.
				out[key] = mapSlot(item, unpack: unpack, strings: false)
			case "meta":
				out[key] = mapSlot(item, unpack: unpack, strings: true)
			case "fields":
				// Blocks use a ValueMap wrapper; objects/snapshots use a direct map.
				let block = slot == "block" || slot == "blocks" || fields["childrenIds"] != nil
				out[key] = block ? transformCoreValue(item, unpack: unpack) : mapSlot(item, unpack: unpack, strings: false)
			default:
				out[key] = transformCoreValue(item, unpack: unpack, slot: key)
			}
		}
		return .object(out)
	default:
		return value
	}
}

extension JSONValue {
	var array: [JSONValue]? {
		if case .array(let value) = self { return value }
		return nil
	}

	var object: [String: JSONValue]? {
		if case .object(let value) = self { return value }
		return nil
	}

	var int: Int64? {
		switch self {
		case .int(let value): return value
		case .double(let value): return Int64(exactly: value)
		default: return nil
		}
	}

	var bool: Bool? {
		if case .bool(let value) = self { return value }
		return nil
	}

	var double: Double? {
		switch self {
		case .double(let value): return value
		case .int(let value): return Double(value)
		default: return nil
		}
	}
}
