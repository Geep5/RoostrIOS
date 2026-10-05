import CryptoKit
import Foundation
import GlonCore

// Shared vocabulary of the sync host. The engine (GlonCore) owns every rule;
// these types are what the host moves between the relay, the store and the
// engine. Keep them plain: Codable, Sendable, no behavior beyond encoding.

/// NIP-01 event. `id` and `sig` are hex; `created_at` is unix seconds.
public struct NostrEvent: Codable, Equatable, Sendable {
	public var id: String
	public var pubkey: String
	public var created_at: Int64
	public var kind: Int
	public var tags: [[String]]
	public var content: String
	public var sig: String

	public init(id: String, pubkey: String, created_at: Int64, kind: Int, tags: [[String]], content: String, sig: String) {
		self.id = id; self.pubkey = pubkey; self.created_at = created_at; self.kind = kind; self.tags = tags; self.content = content; self.sig = sig
	}

	/// First value of the first tag named `name`, e.g. `tag("h")`.
	public func tag(_ name: String) -> String? {
		tags.first { $0.first == name }.flatMap { $0.count > 1 ? $0[1] : nil }
	}
}

/// NIP-01 REQ filter. `tagged` holds single-letter tag filters keyed without the `#`.
public struct NostrFilter: Encodable, Equatable, Sendable {
	public var ids: [String]?
	public var authors: [String]?
	public var kinds: [Int]?
	public var since: Int64?
	public var until: Int64?
	public var limit: Int?
	public var tagged: [String: [String]]

	public init(ids: [String]? = nil, authors: [String]? = nil, kinds: [Int]? = nil, since: Int64? = nil, until: Int64? = nil, limit: Int? = nil, tagged: [String: [String]] = [:]) {
		self.ids = ids; self.authors = authors; self.kinds = kinds; self.since = since; self.until = until; self.limit = limit; self.tagged = tagged
	}

	private struct Key: CodingKey {
		var stringValue: String
		var intValue: Int? { nil }
		init(stringValue: String) { self.stringValue = stringValue }
		init?(intValue: Int) { nil }
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		try container.encodeIfPresent(ids, forKey: Key(stringValue: "ids"))
		try container.encodeIfPresent(authors, forKey: Key(stringValue: "authors"))
		try container.encodeIfPresent(kinds, forKey: Key(stringValue: "kinds"))
		try container.encodeIfPresent(since, forKey: Key(stringValue: "since"))
		try container.encodeIfPresent(until, forKey: Key(stringValue: "until"))
		try container.encodeIfPresent(limit, forKey: Key(stringValue: "limit"))
		for (name, values) in tagged.sorted(by: { $0.key < $1.key }) {
			try container.encode(values, forKey: Key(stringValue: "#\(name)"))
		}
	}
}

/// Relay transport. One instance per relay URL; reconnects are the implementation's concern.
public protocol RelayClient: Sendable {
	var url: URL { get }
	/// Every stored event matching the filters up to the relay's EOSE. Throws on timeout or CLOSED.
	func query(_ filters: [NostrFilter], timeout: Duration) async throws -> [NostrEvent]
	/// Live events matching the filters until the consumer cancels the stream.
	func subscribe(_ filters: [NostrFilter]) -> AsyncThrowingStream<NostrEvent, Error>
	/// Resolves when the relay answers `OK true`; throws with the relay's message on `OK false` or timeout.
	func publish(_ event: NostrEvent, timeout: Duration) async throws
	/// NIP-77: reconciles the relay's stored events matching `filter` against
	/// `local` and returns the ids the relay holds that `local` lacks. Every
	/// relay answer must arrive within `timeout`. Throws `RelayError.negentropy`
	/// on NEG-ERR, `.unsupported` when the relay answers NEG-OPEN with a
	/// NOTICE, `.timeout`, or the transport error of a dropped socket.
	func reconcile(_ filter: NostrFilter, local: NegentropyStorage, timeout: Duration) async throws -> [String]
	/// Drops the connection: everything in flight fails and the next call dials
	/// again. A socket that outlived an app suspension or a network change can
	/// be half-open and never fail by itself.
	func disconnect() async
}

/// A relay event this device holds (imported from a relay or published by it):
/// its side of a NIP-77 reconciliation. `hTag` is the event's first `h` tag.
public struct HeldEvent: Sendable, Equatable {
	public var id: String
	public var createdAt: Int64
	public var kind: Int
	public var author: String
	public var hTag: String?

	public init(id: String, createdAt: Int64, kind: Int, author: String, hTag: String?) {
		self.id = id; self.createdAt = createdAt; self.kind = kind; self.author = author; self.hTag = hTag
	}

	public init(_ event: NostrEvent) {
		self.init(id: event.id, createdAt: event.created_at, kind: event.kind, author: event.pubkey, hTag: event.tag("h"))
	}
}

/// One stored change: exact wire bytes plus the engine's decoded JSON (`codec decode` shape).
public struct ChangeRecord: Sendable, Equatable {
	public let id: String
	public let objectId: String
	public let bytes: Data
	public let json: JSONValue

	public init(id: String, objectId: String, bytes: Data, json: JSONValue) {
		self.id = id; self.objectId = objectId; self.bytes = bytes; self.json = json
	}
}

/// Durable publication obligation, keyed `changeId` (personal) or `spaceId/keyId/changeId` (shared).
public struct PendingPublish: Codable, Sendable, Equatable {
	public var key: String
	public var objectId: String
	public var changeId: String
	public var bytes: Data
	public var spaceId: String?
	public var keyId: Int64?
	/// Exact signed ciphertext retained across retries and relaunches.
	public var events: [NostrEvent]?

	public init(key: String, objectId: String, changeId: String, bytes: Data, spaceId: String? = nil, keyId: Int64? = nil, events: [NostrEvent]? = nil) {
		self.key = key; self.objectId = objectId; self.changeId = changeId; self.bytes = bytes; self.spaceId = spaceId; self.keyId = keyId; self.events = events
	}
}

/// One object's stored checkpoint (kind 1079): computed state plus the change
/// ids it folds in. `hash` and `covered` decide supersession; never a timestamp.
public struct CheckpointRecord: Sendable, Equatable {
	public let objectId: String
	public let bytes: Data
	public let hash: String
	/// Sorted head change ids at checkpoint time.
	public let heads: [String]
	public let covered: Int

	public init(objectId: String, bytes: Data, hash: String, heads: [String], covered: Int) {
		self.objectId = objectId; self.bytes = bytes; self.hash = hash; self.heads = heads; self.covered = covered
	}
}

/// Persistence the sync loop needs; mirrors the browser's IndexedDB stores
/// (`changes`, `checkpoints`, `meta`) so behavior stays comparable. All methods are idempotent.
public protocol ChangeStore: Sendable {
	/// Adds records not already present (by id). Returns how many were new.
	func addChanges(_ records: [ChangeRecord]) async throws -> Int
	func changesFor(objectId: String) async throws -> [ChangeRecord]
	/// Every object held as changes or as a checkpoint.
	func objectIds() async throws -> [String]

	func checkpoint(objectId: String) async throws -> CheckpointRecord?
	/// Keeps `record` when it beats the stored one: more covered wins, then the larger hash. Returns whether it was stored.
	func putCheckpoint(_ record: CheckpointRecord) async throws -> Bool
	/// Drops the obsolete kind-30079 manifest floors an earlier build stored
	/// and, when one shortened a walk, the bootstrapped flag with it: that
	/// device never held the older history, so it walks from event zero once.
	func forgetCheckpointFloors() async throws

	func cursor() async throws -> Int64
	/// Persists the cursor together with the engine's replay obligations, atomically.
	func setCursor(_ cursor: Int64, replayGroups: [(String, Int64)]) async throws
	func replayGroups() async throws -> [(String, Int64)]
	func bootstrapped() async throws -> Bool
	func setBootstrapped() async throws
	func bootstrapFloor() async throws -> Int64?
	func setBootstrapFloor(_ floor: Int64?) async throws

	func pendingPublishes() async throws -> [PendingPublish]
	func pending(key: String) async throws -> PendingPublish?
	func savePending(_ item: PendingPublish) async throws
	func isPublished(key: String) async throws -> Bool
	/// Marks published and removes any pending record for the key.
	func markPublished(key: String) async throws

	/// Remembers relay events this device holds; idempotent by id.
	func recordHeld(_ events: [HeldEvent]) async throws
	/// Held events matching `filter`'s `kinds`, `authors`, `#h`, `since` and
	/// `until` (other fields are ignored): the local set of a reconciliation.
	func heldEvents(matching filter: NostrFilter) async throws -> [HeldEvent]
}

/// Exactly what `Engine.replay` consumes for one object: its stored change
/// ids in replay (insertion) order and the checkpoint it seeds from. A change
/// id is the hash of its bytes, so equal inputs replay to equal states.
public struct ReplayInput: Sendable, Equatable {
	public let changeCount: Int
	/// `ReplayInput.digest(changeIds:)` of the stored changes.
	public let changeDigest: String
	/// Checkpoint hash the state is replayed on top of; "" for none.
	public let checkpointHash: String

	public init(changeCount: Int, changeDigest: String, checkpointHash: String) {
		self.changeCount = changeCount; self.changeDigest = changeDigest; self.checkpointHash = checkpointHash
	}

	public init(changeIds: [String], checkpointHash: String) {
		self.init(changeCount: changeIds.count, changeDigest: Self.digest(changeIds: changeIds), checkpointHash: checkpointHash)
	}

	/// sha256 hex over each id followed by a newline, in replay order.
	public static func digest<S: Sequence>(changeIds: S) -> String where S.Element == String {
		var hasher = SHA256()
		for id in changeIds {
			hasher.update(data: Data(id.utf8))
			hasher.update(data: Data([0x0a]))
		}
		return Hex.encode(Data(hasher.finalize()))
	}
}

/// One persisted replay: the state JSON `Engine.replay` produced from `input`.
public struct CachedReplay: Sendable, Equatable {
	public let objectId: String
	public let input: ReplayInput
	public let state: Data

	public init(objectId: String, input: ReplayInput, state: Data) {
		self.objectId = objectId; self.input = input; self.state = state
	}
}

/// Durable replay memo beside the changes: a cold start reuses a state only
/// when its row was written from the same input under the same engine
/// version, and replays everything else. A cache, never a source of truth.
public protocol ReplayCacheStore: Sendable {
	/// Every stored object's current replay input, read without decoding change JSON.
	func replayInputs() async throws -> [String: ReplayInput]
	/// The rows of `objectIds` written under `engineVersion`, by object id.
	func cachedReplays(objectIds: [String], engineVersion: String) async throws -> [String: CachedReplay]
	/// Upserts `rows` in one transaction.
	func putCachedReplays(_ rows: [CachedReplay], engineVersion: String) async throws
	func clearCachedReplays() async throws
}

public enum SyncPhase: String, Sendable {
	case idle, backfill, live, error
}

public struct SyncStatus: Sendable, Equatable {
	public var phase: SyncPhase
	public var imported: Int
	public var pending: Int
	public var detail: String?

	public init(phase: SyncPhase, imported: Int = 0, pending: Int = 0, detail: String? = nil) {
		self.phase = phase; self.imported = imported; self.pending = pending; self.detail = detail
	}
}

/// Row the object list shows; projection of the engine's replayed state.
public struct ObjectSummary: Sendable, Equatable, Identifiable {
	public let id: String
	public let typeKey: String
	public let name: String
	public let updatedAt: Int64
	public let deleted: Bool

	public init(id: String, typeKey: String, name: String, updatedAt: Int64, deleted: Bool) {
		self.id = id; self.typeKey = typeKey; self.name = name; self.updatedAt = updatedAt; self.deleted = deleted
	}
}
