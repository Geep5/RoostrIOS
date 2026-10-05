import CryptoKit
import Foundation
import GlonCore

// The replica backend the UI consumes: ties store + replay + sync + the
// engine's mutation planner together. All state lives on-device; relays are
// the only network. Shared-space duties (keyring reconcile, invites, join
// requests) live in Backend+Spaces.swift.

public enum BackendError: Error, Equatable {
	case unknownObject(String)
	case malformedPlan(String)
	/// Not an npub or 64-hex pubkey.
	case invalidPubkey(String)
	/// No relay accepted the event.
	case rejected(String)
	/// The action belongs to the space's other side: only the administrator
	/// deletes a space for everyone, only a member leaves one.
	case refused(String)
}

/// The synced vanish ledger object; the engine reads its entries.
let vanishLogId = "__vanished__"

public actor Backend {
	struct Cached {
		/// The changes and checkpoint the state was replayed from: replacing
		/// 500 changes with one checkpoint must not read as "unchanged".
		let input: ReplayInput
		let state: JSONValue
	}

	/// Persisted replays are valid only for the engine that computed them;
	/// the suffix versions the host's row encoding.
	static let replayCacheVersion = "\(GlonCore.sourceFingerprint)/1"
	/// Replays written per store transaction.
	static let replayWriteBatch = 64

	/// Test hook: `"<changeCount>:<checkpointHash>"` the cached state was replayed under.
	func cachedSignature(id: String) -> String? {
		states[id].map { "\($0.input.changeCount):\($0.input.checkpointHash)" }
	}

	/// Test hook: `Engine.replay` runs by this instance; a warm start runs none.
	private(set) var replayCount = 0

	let key: NostrKey
	let store: ChangeStore
	let engine: SyncEngine
	/// Space keys this device holds; owned spaces carry no owner.
	public let keyring: SpaceKeyring
	/// Host bookkeeping the browser kept in localStorage (wraps seen, invites
	/// sent, join requests); durable when the store offers meta rows.
	public let hostMeta: MetaStore
	/// Key-derived author id, parity with the Odin server (keys.ts authorIdFor).
	public let author: String
	/// Durable replay memo, when the store keeps one.
	let replayCache: ReplayCacheStore?

	var states: [String: Cached] = [:]
	/// Object ids the synced ledger says are gone, rule-derived ones (objects
	/// in a vanished or left space) included; rebuilt when it commits.
	var vanished: Set<String> = []
	/// The ids among `vanished` this identity merely left (left spaces and
	/// their objects): hidden here, untouched on the relays.
	var leftIds: Set<String> = []
	var dirty: Set<String> = []
	private var allDirty = true
	private var forwardTask: Task<Void, Never>?
	private var wrapTask: Task<Void, Never>?
	private var spaceVanishTask: Task<Void, Never>?
	/// Shared-space reconciles run one at a time, in order.
	var refreshChain: Task<Void, Never>?
	/// Invite wraps go out one batch at a time so the sent-map stays idempotent.
	var inviteChain: Task<Void, Never>?
	private var commitSinks: [UUID: AsyncStream<[String]>.Continuation] = [:]
	/// Actor reentrancy must not split a read/plan/commit claim transaction.
	private var mutationTail: Task<Void, Never>?
	private var rebuilding: Task<Void, Error>?
	/// Fresh replays waiting for the memo, written behind `ensure()` by `replayWriter`.
	private var replayWrites: [(id: String, input: ReplayInput, state: JSONValue)] = []
	private var replayWriter: Task<Void, Never>?
	/// Bumped when the memo is dropped: a scan that read it earlier must not apply its rows.
	private var replayCacheEpoch = 0
	private var stopped = false
	/// `bootstrap_space_defaults`, queued once start has finished.
	private var bootstrapTask: Task<Void, Never>?

	public init(key: NostrKey, relays: [RelayClient], store: ChangeStore, keyring: SpaceKeyring = KeychainSpaceKeyring()) {
		self.key = key
		self.store = store
		self.keyring = keyring
		self.hostMeta = (store as? MetaStore) ?? InMemoryMetaStore()
		self.replayCache = store as? ReplayCacheStore
		self.engine = SyncEngine(key: key, relays: relays, store: store)
		self.author = Self.authorId(secretHex: key.secretHex)
	}

	/// sha256 of the UTF-8 bytes of the 64-char secret hex STRING, first 16 hex chars.
	static func authorId(secretHex: String) -> String {
		String(Hex.encode(Data(SHA256.hash(data: Data(secretHex.utf8)))).prefix(16))
	}

	// ── Lifecycle ──

	/// Brings sync up: shared-space reconcile, the engine's session, history
	/// walk and live subscriptions. Readers need not wait for it - every read
	/// goes through `ensure()`, which serves the local replica at once. A start
	/// cancelled before it ran (the host tore the vault down) does nothing.
	public func start() async {
		if Task.isCancelled { return }
		stopped = false
		allDirty = true
		forwardTask?.cancel()
		wrapTask?.cancel()
		spaceVanishTask?.cancel()
		let commits = await engine.commitUpdates()
		forwardTask = Task {
			for await ids in commits {
				await self.imported(ids)
			}
		}
		let wraps = await engine.wrapUpdates()
		wrapTask = Task {
			for await event in wraps {
				await self.handleWrap(event)
			}
		}
		let spaceVanishes = await engine.spaceVanishUpdates()
		spaceVanishTask = Task {
			for await spaceId in spaceVanishes {
				await self.spaceVanishedByOwner(spaceId)
			}
		}
		// The session opens under the keyring's spaces; a second reconcile
		// after start republishes whatever the relays still lack.
		await refreshShared()
		if stopped { return }
		await engine.start()
		if stopped { return }
		scheduleRefreshShared()
		// Converge the bundled catalog (new relations/types the engine added
		// since this space was seeded) - same boot step as the native daemon;
		// idempotent, so a converged space commits nothing. It plans over every
		// state, so it runs behind start rather than on it.
		bootstrapTask = Task { _ = try? await self.mutate(action: "bootstrap_space_defaults", params: .object([:])) }
	}

	public func stop() async {
		stopped = true
		bootstrapTask?.cancel()
		bootstrapTask = nil
		forwardTask?.cancel()
		forwardTask = nil
		wrapTask?.cancel()
		wrapTask = nil
		spaceVanishTask?.cancel()
		spaceVanishTask = nil
		await engine.stop()
		for sink in commitSinks.values { sink.finish() }
		commitSinks.removeAll()
	}

	/// Reconnects every relay now, catches up from the cursor and flushes the
	/// outbox (`SyncEngine.resume`): foregrounding, network changes, refresh.
	public func resume() async {
		await engine.resume()
	}

	public func awaitIdle() async {
		await bootstrapTask?.value
		await refreshChain?.value
		await engine.awaitIdle()
		await replayWriter?.value
	}

	public func statusUpdates() async -> AsyncStream<SyncStatus> {
		await engine.statusUpdates()
	}

	/// Object ids whose state changed, from relay imports and local mutations alike.
	public func commitUpdates() -> AsyncStream<[String]> {
		let id = UUID()
		let (stream, continuation) = AsyncStream<[String]>.makeStream()
		commitSinks[id] = continuation
		continuation.onTermination = { _ in Task { await self.dropCommitSink(id) } }
		return stream
	}

	private func dropCommitSink(_ id: UUID) { commitSinks[id] = nil }

	private func imported(_ ids: [String]) async {
		for id in ids { dirty.insert(id) }
		notify(ids)
		// A synced commit on a space object can change members or keys; one on
		// the ledger can vanish a space.
		if ids.contains(where: { $0 == vanishLogId || states[$0]?.state["typeKey"]?.string == "channel" || (try? keyring.get($0)) != nil }) { scheduleRefreshShared() }
	}

	private func notify(_ ids: [String]) {
		for sink in commitSinks.values { sink.yield(ids) }
	}

	// ── Replayed state ──

	/// Recomputes dirty object states; an object whose replay input did not change keeps its cached replay.
	func ensure() async throws {
		if let rebuilding { return try await rebuilding.value }
		let work = Task {
			defer { rebuilding = nil }
			repeat { try await rebuildStates() } while allDirty || !dirty.isEmpty
		}
		rebuilding = work
		try await work.value
	}

	/// Drops the persisted replays and every in-memory state, then replays
	/// the whole replica from its stored changes and checkpoints; the engine's
	/// query cache reloads from the result.
	public func rebuildLocalStates() async throws {
		try await clearReplayCache()
		states.removeAll()
		allDirty = true
		try await ensure()
		forgetQuerySnapshot()
		notify(Array(states.keys))
	}

	/// Forgets the persisted replays: queued writes are dropped, the one in
	/// flight lands first, and a scan that already read the rows discards them.
	func clearReplayCache() async throws {
		replayCacheEpoch += 1
		replayWrites.removeAll()
		await replayWriter?.value
		try await replayCache?.clearCachedReplays()
	}

	private func rebuildStates() async throws {
		var rebuilt = false
		let ids: [String]
		if allDirty {
			allDirty = false
			rebuilt = true
			dirty.removeAll()
			ids = try await restoreCachedStates()
		} else {
			ids = Array(dirty)
			dirty.removeAll()
		}
		var fresh: [(id: String, input: ReplayInput, state: JSONValue)] = []
		for id in ids {
			let changes = try await store.changesFor(objectId: id)
			let checkpoint = try await store.checkpoint(objectId: id)
			if changes.isEmpty && checkpoint == nil { states[id] = nil; continue }
			let input = ReplayInput(changeIds: changes.map(\.id), checkpointHash: checkpoint?.hash ?? "")
			if states[id]?.input == input { continue }
			replayCount += 1
			do {
				if let state = try await Engine.replay(changes.map(\.json), checkpoint: checkpoint?.bytes) {
					states[id] = Cached(input: input, state: state)
					fresh.append((id, input, state))
				}
			} catch {
				// One malformed legacy object must never brick the vault.
				continue
			}
		}
		persistReplays(fresh)
		try await enforceVanished(rebuilt: rebuilt, touched: ids)
	}

	/// Full scan: takes every persisted replay whose input is exactly what the
	/// store holds now under this engine; returns the ids that still need a replay.
	private func restoreCachedStates() async throws -> [String] {
		let ids = try await store.objectIds()
		guard let replayCache else { return ids }
		let epoch = replayCacheEpoch
		let inputs = try await replayCache.replayInputs()
		var misses: [String] = []
		var wanted: [String] = []
		for id in ids {
			guard let input = inputs[id] else { misses.append(id); continue }
			if states[id]?.input != input { wanted.append(id) }
		}
		let rows = try await replayCache.cachedReplays(objectIds: wanted, engineVersion: Self.replayCacheVersion)
		let decoded = await Self.decodeReplays(rows.values.filter { $0.input == inputs[$0.objectId] })
		guard epoch == replayCacheEpoch else { return ids }
		for id in wanted {
			if let state = decoded[id], let input = inputs[id] {
				states[id] = Cached(input: input, state: state)
			} else {
				misses.append(id)
			}
		}
		return misses
	}

	/// Off the actor: decoding a vault's states is the bulk of a warm start.
	private nonisolated static func decodeReplays(_ rows: [CachedReplay]) async -> [String: JSONValue] {
		let decoder = JSONDecoder()
		var states: [String: JSONValue] = [:]
		states.reserveCapacity(rows.count)
		for row in rows {
			if let state = try? decoder.decode(JSONValue.self, from: row.state) { states[row.objectId] = state }
		}
		return states
	}

	/// Queues fresh replays for the memo; never awaited by readers or imports.
	private func persistReplays(_ fresh: [(id: String, input: ReplayInput, state: JSONValue)]) {
		guard replayCache != nil, !fresh.isEmpty else { return }
		replayWrites += fresh
		if replayWriter == nil { replayWriter = Task(priority: .utility) { await self.drainReplayWrites() } }
	}

	private func drainReplayWrites() async {
		defer { replayWriter = nil }
		while !replayWrites.isEmpty, let replayCache {
			let batch = Array(replayWrites.prefix(Self.replayWriteBatch))
			replayWrites.removeFirst(batch.count)
			let rows = await Self.encodeReplays(batch)
			do {
				try await replayCache.putCachedReplays(rows, engineVersion: Self.replayCacheVersion)
			} catch {
				// A memo that cannot be written only costs a replay next start.
				replayWrites.removeAll()
			}
		}
	}

	/// Off the actor: encoding a vault's states is the bulk of a write.
	private nonisolated static func encodeReplays(_ batch: [(id: String, input: ReplayInput, state: JSONValue)]) async -> [CachedReplay] {
		let encoder = JSONEncoder()
		return batch.compactMap { item in
			(try? encoder.encode(item.state)).map { CachedReplay(objectId: item.id, input: item.input, state: $0) }
		}
	}

	/// The ledger wins over whatever replayed: a relay copy of a vanished object
	/// can arrive ahead of, or without, the delete change that tombstones it,
	/// and an object in a vanished or left space goes with it. A full sweep or
	/// a ledger change checks every state; otherwise only the touched ones.
	private func enforceVanished(rebuilt: Bool, touched: [String]) async throws {
		let sweep = rebuilt || touched.contains(vanishLogId)
		guard sweep || !vanished.isEmpty, let ledger = states[vanishLogId]?.state else { return }
		let stubs: [JSONValue] = (sweep ? Array(states.keys) : touched).compactMap { id in
			guard let state = states[id]?.state else { return nil }
			return .object(["id": .string(id), "channel": .string(state["fields"]?["channel"]?["stringValue"]?.string ?? "")])
		}
		let entries = try await Engine.vanished(ledger: ledger, objects: stubs)
		let dropped = Set(entries.map(\.objectId))
		let left = Set(entries.filter { $0.left == true }.map(\.objectId))
		// States already dropped are no longer swept: keep what earlier passes found.
		vanished = rebuilt ? dropped : vanished.union(dropped)
		leftIds = rebuilt ? left : leftIds.union(left)
		for id in dropped { states[id] = nil }
	}

	/// objectId → owning space id ("" = personal). Channels own themselves.
	func spaceOf(_ objectId: String) -> String {
		guard let state = states[objectId]?.state else { return "" }
		return state["typeKey"]?.string == "channel" ? objectId : (state["fields"]?["channel"]?["stringValue"]?.string ?? "")
	}

	/// Non-deleted objects, newest first; the vanish ledger and vanished ids are excluded.
	public func objects() async throws -> [ObjectSummary] {
		try await ensure()
		var out: [ObjectSummary] = []
		out.reserveCapacity(states.count)
		for (id, cached) in states {
			let state = cached.state
			if id == vanishLogId || vanished.contains(id) { continue }
			let typeKey = state["typeKey"]?.string ?? ""
			let deleted = state["deleted"]?.bool ?? false
			if deleted || typeKey == "vanish_log" { continue }
			out.append(ObjectSummary(
				id: id,
				typeKey: typeKey,
				name: state["fields"]?["name"]?["stringValue"]?.string ?? "",
				updatedAt: state["updatedAt"]?.int ?? 0,
				deleted: deleted
			))
		}
		out.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
		return out
	}

	/// Replayed ObjectJSON with plain maps.
	public func object(id: String) async throws -> JSONValue {
		try await ensure()
		guard let cached = states[id] else { throw BackendError.unknownObject(id) }
		return unpackCoreValueMaps(cached.state)
	}

	// ── Mutations ──

	/// Runs the engine's mutation planner over the current state and commits
	/// every planned change (encode → store → publish). Returns the plan's result.
	/// Key material stays in the host: a rotation plans under the next keyId
	/// and rotates the keyring only once the engine accepted the request; a
	/// new channel gets its key right after its creating change; leaving a
	/// space drops its key once the ledger entry committed.
	public func mutate(action: String, params: JSONValue) async throws -> JSONValue {
		try refuseForeignSpaceAction(action: action, params: params)
		return try await enqueueMutation(action: action, params: params)
	}

	/// Only the administrator deletes a space for everyone; only a member leaves one.
	private func refuseForeignSpaceAction(action: String, params: JSONValue) throws {
		switch action {
		case "space_leave":
			let spaceId = params["channel_id"]?.string ?? ""
			if !spaceId.isEmpty, spaceOwner(try keyring.get(spaceId)).isEmpty {
				throw BackendError.refused("space \(spaceId) is administered by this identity: delete it for everyone instead of leaving")
			}
		case "vanish":
			var ids = params["object_ids"]?.array?.compactMap(\.string) ?? []
			if let id = params["object_id"]?.string { ids.append(id) }
			let keys = try keyring.all()
			for id in ids where !spaceOwner(keys[id]).isEmpty {
				throw BackendError.refused("space \(id) is administered by someone else: leave it instead of deleting it")
			}
		default:
			return
		}
	}

	/// Queues a mutation behind the ones already running, unchecked.
	func enqueueMutation(action: String, params: JSONValue) async throws -> JSONValue {
		let previous = mutationTail
		let work = Task {
			await previous?.value
			return try await applyMutation(action: action, params: params)
		}
		mutationTail = Task { _ = try? await work.value }
		return try await work.value
	}

	private func applyMutation(action: String, params: JSONValue) async throws -> JSONValue {
		try await ensure()
		let channelId = params["channel_id"]?.string ?? ""
		let rotating = action == "channel_member_remove" || action == "channel_key_rotate"
		let keyId: Int64 = rotating ? ((try keyring.get(channelId)?.keyId) ?? 0) + 1 : 0
		let plan = try await Engine.mutation(
			action: action,
			params: params,
			objects: Self.mutationObjects(states.values.map(\.state), params: params),
			timestamp: Int64(Date().timeIntervalSince1970 * 1000),
			author: author,
			idSeed: UUID().uuidString.lowercased(),
			keyId: keyId
		)
		var keyringChanged = false
		if rotating {
			try keyring.rotate(channelId)
			keyringChanged = true
		}
		var touchedShared = false
		for (index, change) in plan.changes.enumerated() {
			try await commit(change)
			guard let objectId = change["objectId"]?.string else { continue }
			if action == "channel_create" && index == 0 {
				try keyring.ensure(objectId)
				keyringChanged = true
			}
			// The ledger decides which spaces stay synced.
			if objectId == vanishLogId || spaceOf(objectId) == objectId { touchedShared = true }
		}
		// Browsers enforce the synced ledger locally; native hosts additionally purge files.
		for change in plan.vanishChanges { try await commit(change) }
		if !plan.vanishChanges.isEmpty { touchedShared = true }
		if action == "space_leave" {
			try keyring.remove(channelId)
			keyringChanged = true
		}
		if keyringChanged || touchedShared { scheduleRefreshShared() }
		return unpackCoreValueMaps(plan.result)
	}

	/// The states a mutation plans over. The planner reads blocks only of the
	/// objects its params name (targets, senders, recipients); every other
	/// state goes without its blocks, which are most of a vault's bytes and
	/// would overrun the core's per-request arena on a large one.
	static func mutationObjects(_ states: [JSONValue], params: JSONValue) -> [JSONValue] {
		var named: Set<String> = []
		func collect(_ value: JSONValue) {
			switch value {
			case .string(let text): named.insert(text)
			case .array(let items): items.forEach(collect)
			case .object(let fields): fields.values.forEach(collect)
			default: break
			}
		}
		collect(params)
		return states.map { state in
			guard case .object(var fields) = state, let id = fields["id"]?.string, !named.contains(id), fields["blocks"] != nil else {
				return packCoreValueMaps(state)
			}
			fields["blocks"] = .array([])
			return packCoreValueMaps(.object(fields))
		}
	}

	/// Creates a note and its first text block; returns the object id.
	public func createNote(name: String, text: String) async throws -> String {
		let created = try await mutate(action: "create", params: .object(["name": .string(name)]))
		guard let id = created["id"]?.string else { throw BackendError.malformedPlan("create returned no id") }
		_ = try await mutate(action: "block_add", params: .object([
			"object_id": .string(id),
			"block": .object(["content": .object(["text": .object(["text": .string(text)])])]),
			"target_id": .string(""),
			"position": .int(0),
		]))
		return id
	}

	/// Encodes, addresses, durably persists and publishes one planned change.
	private func commit(_ planned: JSONValue) async throws {
		guard var fields = planned.object, let objectId = fields["objectId"]?.string else { throw BackendError.malformedPlan("change without objectId") }
		let history = try await store.changesFor(objectId: objectId)
		let checkpoint = try await store.checkpoint(objectId: objectId)
		fields["parentIds"] = .array(try await Engine.heads(history.map(\.json), checkpoint: checkpoint?.bytes).map(JSONValue.string))
		let bytes = try await Engine.encode(.object(fields))
		// Round-trip through decode so the stored JSON matches relay-imported changes byte for byte.
		let decoded = try await Engine.decode(bytes)
		guard let id = decoded["id"]?.string else { throw BackendError.malformedPlan("encoded change without id") }
		_ = try await store.addChanges([ChangeRecord(id: id, objectId: objectId, bytes: bytes, json: decoded)])
		dirty.insert(objectId)
		// The change's own scope decides whether it also goes out under a space key.
		try await ensure()
		try await engine.publish(bytes: bytes, changeId: id, objectId: objectId, spaceId: spaceOf(objectId))
		notify([objectId])
	}
}
