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

/// A reassembled kind-1079 payload as the session summarizes it (bytes stay opaque).
public struct CheckpointSummary: Decodable, Sendable, Equatable {
	public let objectId: String
	public let headIds: [String]
	public let covered: Int
	public let hash: String
}

/// A reassembled kind-31078 base as the session summarizes it (bytes stay opaque).
public struct BaseSummary: Decodable, Sendable, Equatable {
	public let objectId: String
	public let hash: String
	public let epoch: Int64
	public let createdAt: Int64
	public let headIds: [String]
	public let covered: Int
}

/// One decrypted relay payload: a change (kind 1078), a checkpoint (kind 1079) or a base (kind 31078 + 1080 parts).
public struct IngestItem: Decodable, Sendable {
	/// Base64 wire bytes of the full change, checkpoint or base.
	public let bytes: String
	public let change: JSONValue?
	/// The base hash a change's event named (`["b", hash]`); nil = pre-migration.
	public let b: String?
	public let checkpoint: CheckpointSummary?
	public let base: BaseSummary?
	public let chunkKey: String?
	public let provenance: SharedProvenance?
}

/// `classify`: how each held change relates to the object's current base (hex id lists).
public struct BaseClassification: Decodable, Sendable, Equatable {
	public struct Current: Decodable, Sendable, Equatable {
		public let hash: String
		public let epoch: Int64
	}

	/// nil: no base, every change is live.
	public let base: Current?
	public let live: [String]
	public let covered: [String]
	public let premigrationCovered: [String]
	public let orphan: [String]
	public let stale: [String]
	public let liveHeads: [String]
}

/// `rebase`: the orphans re-applied on the current base, in publish order.
public struct RebaseResult: Decodable, Sendable {
	public struct Rebased: Decodable, Sendable {
		public let orphan: String
		public let id: String
		public let change: JSONValue
		/// Base64 protobuf of the new change.
		public let bytes: String
	}

	/// Hash of the base every change was rebased onto: published as `["b", base]`.
	public let base: String
	public let changes: [Rebased]
}

/// Everything the core's state-sync actions read for ONE object: the bases
/// held, the changes (rebased orphans left out), the legacy checkpoint and
/// the ids of changes this device never published.
public struct ObjectHoldings: Sendable {
	public var bases: [BaseRecord]
	public var changes: [ChangeRecord]
	public var checkpoint: CheckpointRecord?
	public var pending: [String]

	public init(bases: [BaseRecord], changes: [ChangeRecord], checkpoint: CheckpointRecord?, pending: [String] = []) {
		self.bases = bases; self.changes = changes; self.checkpoint = checkpoint; self.pending = pending
	}

	/// Reads the object's holdings; `pending` lists the ids of unpublished changes (any object).
	public static func load(_ store: ChangeStore, objectId: String, pending: Set<String> = []) async throws -> ObjectHoldings {
		let changes = try await store.changesFor(objectId: objectId).filter { !$0.rebased }
		return ObjectHoldings(
			bases: try await store.bases(objectId: objectId),
			changes: changes,
			checkpoint: try await store.checkpoint(objectId: objectId),
			pending: pending.isEmpty ? [] : changes.map(\.id).filter(pending.contains)
		)
	}

	public var isEmpty: Bool { bases.isEmpty && changes.isEmpty && checkpoint == nil }

	/// The replay memo's key for this exact input.
	public var replayInput: ReplayInput {
		ReplayInput(changeIds: changes.map(\.id), checkpointHash: checkpoint?.hash ?? "", baseHashes: bases.map(\.hash))
	}

	/// The current base: highest epoch, then created_at, then hash.
	public var currentBase: BaseRecord? {
		bases.max { $1.outranks($0) }
	}

	var payload: [String: JSONValue] {
		var fields: [String: JSONValue] = [
			"bases": .array(bases.map { .string($0.bytes.base64EncodedString()) }),
			"changes": .array(changes.map(\.stateSyncJSON)),
			"pending": .array(pending.map(JSONValue.string)),
		]
		if let checkpoint { fields["checkpoint"] = .string(checkpoint.bytes.base64EncodedString()) }
		return fields
	}
}

public struct IngestResult: Decodable, Sendable {
	public let cursor: Int64
	public let item: IngestItem?
	public let faultAt: Int64?
	public let replayGroups: [ReplayGroup]?
	public let decryptFailure: Bool?
	public let decodeFailure: Bool?
	public let hTag: String?
	/// A verified kind-5 from the administrator of an installed space: that space is gone for every member.
	public let spaceVanished: String?
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
	/// The identity left the space (relay copies stay for everyone else).
	public let left: Bool?
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

/// A plan, or the ids the params name that the engine's query cache lacks
/// (core `mutation_states`): nothing was planned, and the host retries with
/// their states as overlay.
public enum MutationResponse: Decodable, Sendable {
	case plan(MutationPlan)
	case missing([String])

	enum CodingKeys: String, CodingKey { case missing }

	public init(from decoder: Decoder) throws {
		if let missing = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([String].self, forKey: .missing) {
			self = .missing(missing)
		} else {
			self = .plan(try MutationPlan(from: decoder))
		}
	}
}

public enum Engine {
	public static let changeKind = 1078
	/// One sealed Checkpoint protobuf per object (docs/checkpoint-sync.md); retired by bases, still imported.
	public static let checkpointKind = 1079
	/// Addressable base of one object (docs/state-sync.md); parts 2..n ride in `basePartKind`.
	public static let baseKind = 31078
	public static let basePartKind = 1080
	/// NIP-09 deletion; with `["h", spaceTag]` the space's stream (relay rule, space-vanish contract §4).
	public static let deletionKind = 5

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

	/// Replayed ObjectJSON (plain maps), or nil when there is nothing to replay.
	/// A checkpoint seeds the state; changes it covers are skipped, the rest replayed.
	public static func replay(_ changes: [JSONValue], checkpoint: Data? = nil) async throws -> JSONValue? {
		if changes.isEmpty && checkpoint == nil { return nil }
		var payload: [String: JSONValue] = ["changes": .array(changes)]
		if let checkpoint { payload["checkpoint"] = .string(checkpoint.base64EncodedString()) }
		return try await call("replay", payload)
	}

	/// Head change ids: changes no other change lists as a parent, plus checkpoint heads nothing built on.
	public static func heads(_ changes: [JSONValue], checkpoint: Data? = nil) async throws -> [String] {
		var payload: [String: JSONValue] = ["action": .string("heads"), "changes": .array(changes)]
		if let checkpoint { payload["checkpoint"] = .string(checkpoint.base64EncodedString()) }
		return try await call("mutation", payload)
	}

	/// Applies one locally committed, addressed change (the engine's own
	/// ordered-pair form) to the engine's query cache instead of re-sending its
	/// object's state (core `query_cache_apply`). False when the cache refused:
	/// it did not hold exactly the change's parents as heads, and is untouched.
	public static func applyCommitted(_ change: JSONValue) async throws -> Bool {
		let out: JSONValue = try await call("mutation", ["action": .string("apply"), "changes": .array([change])])
		return out["applied"]?.array?.count == 1
	}

	/// Plans over the engine's query cache, which the caller has brought up
	/// to date (`Backend.syncQueryCache`): the request carries no vault.
	/// `overlay` states win over the cache; `absent` ids the caller looked up
	/// and does not hold.
	public static func mutation(action: String, params: JSONValue, timestamp: Int64, author: String, idSeed: String, keyId: Int64, overlay: [JSONValue] = [], absent: [String] = []) async throws -> MutationResponse {
		var payload: [String: JSONValue] = [
			"action": .string(action),
			"params": params,
			"timestamp": .int(timestamp),
			"author": .string(author),
			"id_seed": .string(idSeed),
			"key_id": .int(keyId),
		]
		if !overlay.isEmpty { payload["overlay"] = .array(overlay.map(packCoreValueMaps)) }
		if !absent.isEmpty { payload["absent"] = .array(absent.map(JSONValue.string)) }
		return try await call("mutation", payload)
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

	// ── state sync (docs/state-sync.md "Core API") ──

	/// Current base state + live deltas; with no base, `replay` over every held change seeded by the checkpoint.
	public static func replayFromBase(_ holdings: ObjectHoldings) async throws -> JSONValue? {
		if holdings.isEmpty { return nil }
		return try await sync("replay_from_base", holdings.payload)
	}

	public static func classify(_ holdings: ObjectHoldings) async throws -> BaseClassification {
		try await sync("classify", holdings.payload)
	}

	/// Rebases `orphans` (hex ids; every orphan when nil) onto the current base.
	public static func rebase(_ holdings: ObjectHoldings, orphans: [String]? = nil) async throws -> RebaseResult {
		var payload = holdings.payload
		if let orphans { payload["orphans"] = .array(orphans.map(JSONValue.string)) }
		return try await sync("rebase", payload)
	}

	/// Every ledger entry plus each given `{id, channel}` stub whose channel
	/// names a vanished or left space: the complete set of ids to drop.
	public static func vanished(ledger: JSONValue?, objects: [JSONValue]) async throws -> [VanishedEntry] {
		try await sync("vanished", ["ledger": ledger ?? .null, "objects": .array(objects)])
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
