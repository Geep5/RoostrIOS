import Foundation
import GlonCore

// Host half of the engine's sync session: relay I/O, signing, persistence and
// scheduling. Mirrors RoostrWebsite's RelaySync minus what the engine now
// owns (reassembly, cursor, replay obligations, the outbox and its backoff).

public enum SyncError: Error, Equatable {
	case saturatedPage
	case noSignedEvents
	case noRelays
	case rejected(String)
	case malformedChange
}

/// The engine's receive session is process-global and single-flight; only its
/// owner may feed or close it, so a newer engine silently retires an older one.
private enum SessionOwner {
	private static let lock = NSLock()
	nonisolated(unsafe) private static var current: ObjectIdentifier?

	static func claim(_ id: ObjectIdentifier) { lock.withLock { current = id } }
	static func release(_ id: ObjectIdentifier) { lock.withLock { if current == id { current = nil } } }
	static func owns(_ id: ObjectIdentifier) -> Bool { lock.withLock { current == id } }
}

/// What the host knows about a shared space: its key, the key version, and
/// who may author under it (backend.ts SharedSpaceInfo).
public struct SharedSpaceInfo: Sendable, Equatable {
	public var spaceId: String
	public var keyHex: String
	public var keyId: Int64
	/// Hex pubkeys allowed to author events: owner + writer members.
	public var writers: [String]
	/// Hex pubkey of the administrator; nil for spaces this device created.
	public var owner: String?

	public init(spaceId: String, keyHex: String, keyId: Int64, writers: [String], owner: String?) {
		self.spaceId = spaceId; self.keyHex = keyHex; self.keyId = keyId; self.writers = writers; self.owner = owner
	}
}

/// Installed space plus its blinded stream tag `blind(key, "space:"+id)`.
private struct SharedSpace: Sendable, Equatable {
	let info: SharedSpaceInfo
	let spaceTag: String
}

private struct ImportItem: Sendable {
	let bytes: Data
	let change: JSONValue
	let chunkKey: String?
	let provenance: SharedProvenance?
}

/// NIP-59 gift wrap: space-key invites and join requests, addressed by pubkey.
private let giftWrapKind = 1059
/// Gift wraps randomize created_at up to ~2 days back; look back further.
private let wrapLookbackSeconds: Int64 = 3 * 86_400

public actor SyncEngine {
	private static let pageLimit = 128
	private static let pageSpacing: Duration = .milliseconds(400)
	private static let publishSpacing: Duration = .milliseconds(120)
	private static let notifyDebounce: Duration = .milliseconds(100)
	private static let queryTimeout: Duration = .seconds(15)
	private static let publishTimeout: Duration = .seconds(10)
	private static let liveBackoffFloor: Duration = .seconds(2)
	private static let liveBackoffCeiling: Duration = .seconds(60)

	private let key: NostrKey
	private let relays: [RelayClient]
	private let store: ChangeStore
	private let pk: String

	private var spaces: [String: SharedSpace] = [:]
	private var cursor: Int64 = 0
	/// Host mirror of the session's replay obligations: chunk key → earliest created_at.
	private var replayGroups: [String: Int64] = [:]
	/// Earliest created_at a fault or discarded group makes suspect; nil = no obligation.
	private var discardedChunkFloor: Int64?
	private var replayFaultGeneration = 0
	private var historyComplete = false
	private var walkCoveredUntil: Int64?
	private var stopped = false
	private var liveUp = false
	/// History walks in flight (the bootstrap walk and shared-space backfills).
	private var activeWalks = 0
	private var activeLiveEvents = 0
	private var activeImports = 0
	private var importedCount = 0
	/// Mirror of the outbox's queued-not-in-flight count, for the status.
	private var pendingCount = 0
	private var queueRunning = false
	private var queueDirty = false

	private var walkTask: Task<Void, Never>?
	private var liveTask: Task<Void, Never>?
	private var outboxTask: Task<Void, Never>?
	private var importChain: Task<Error?, Never>?
	/// Walks run strictly in order, as the browser's backfillChain.
	private var backfillChain: Task<Result<Bool, Error>, Never>?
	private var cursorChain: Task<Void, Never>?
	private var notifyTask: Task<Void, Never>?
	private var pendingObjects: Set<String> = []

	private var lastStatus = SyncStatus(phase: .idle)
	private var statusSinks: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
	private var commitSinks: [UUID: AsyncStream<[String]>.Continuation] = [:]
	private var wrapSinks: [UUID: AsyncStream<NostrEvent>.Continuation] = [:]

	public init(key: NostrKey, relays: [RelayClient], store: ChangeStore) {
		self.key = key
		self.relays = relays
		self.store = store
		self.pk = key.pubkey
	}

	private var sessionOpen: Bool { SessionOwner.owns(ObjectIdentifier(self)) }

	private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

	// ── Lifecycle ──

	/// Opens the session, restores the outbox, launches the history walk in the
	/// background and returns once the live subscriptions are up.
	public func start() async {
		stopped = false
		historyComplete = false
		do {
			cursor = try await store.cursor()
			try await openSession()
			for pending in try await store.pendingPublishes() { try await offerToOutbox(pending) }
		} catch {
			emit(SyncStatus(phase: .error, imported: importedCount, pending: pendingCount, detail: "\(error)"))
			return
		}
		emit(SyncStatus(phase: .backfill, imported: 0, pending: pendingCount))

		// The incremental `since = cursor+1` shortcut is only sound once ONE full
		// history walk has completed on this device: the cursor tracks the newest
		// imported event, so an interrupted first bootstrap would otherwise skip
		// everything older, forever. The walk runs in the background; live
		// subscriptions come up first and imports dedupe against its pages.
		let bootstrapped = (try? await store.bootstrapped()) ?? false
		let floor: Int64? = bootstrapped ? nil : ((try? await store.bootstrapFloor()) ?? nil)
		let since: Int64 = bootstrapped ? cursor + 1 : 1
		activeWalks += 1
		walkTask = Task { await self.bootstrap(since: since, resumeUntil: floor, markBootstrapped: !bootstrapped) }
		if stopped { return }
		// Gift wraps addressed to us: created_at is randomized, so no cursor;
		// the consumer's seen-set dedupes.
		await fetchWraps(from: relays)
		if stopped { return }
		subscribeLive()
		emitLiveStatus()
	}

	public func stop() async {
		stopped = true
		liveUp = false
		walkTask?.cancel()
		liveTask?.cancel()
		outboxTask?.cancel()
		notifyTask?.cancel()
		notifyTask = nil
		await closeSession()
		for sink in statusSinks.values { sink.finish() }
		for sink in commitSinks.values { sink.finish() }
		for sink in wrapSinks.values { sink.finish() }
		statusSinks.removeAll()
		commitSinks.removeAll()
		wrapSinks.removeAll()
	}

	/// Test helper: resolves when no walk, import, live event or publish is in flight.
	public func awaitIdle() async {
		while activeWalks > 0 || activeImports > 0 || activeLiveEvents > 0 || queueRunning {
			try? await Task.sleep(for: .milliseconds(20))
		}
	}

	private func openSession() async throws {
		let groups = try await store.replayGroups()
		let state: SessionState = try await Engine.sync("session", [
			"pk": .string(pk),
			"conversationKey": .string(try await Engine.conversationKey(sharedX: try key.sharedX(with: pk))),
			"secret": .string(key.secretHex),
			"spaces": .array(spaces.values.map(Self.spaceJSON)),
			"cursor": .int(cursor),
			"replayGroups": .array(groups.map { .array([.string($0.0), .int($0.1)]) }),
		])
		SessionOwner.claim(ObjectIdentifier(self))
		mirror(state.replayGroups)
	}

	private func closeSession() async {
		guard sessionOpen else { return }
		let _: Bool? = try? await Engine.sync("close")
		SessionOwner.release(ObjectIdentifier(self))
	}

	private static func spaceJSON(_ space: SharedSpace) -> JSONValue {
		.object(["spaceId": .string(space.info.spaceId), "keyHex": .string(space.info.keyHex), "keyId": .int(space.info.keyId)])
	}

	/// Replace the shared-space view the session decrypts under. A space whose
	/// stream tag is new gets a full backfill plus a live subscription.
	public func setSharedSpaces(_ infos: [SharedSpaceInfo]) async {
		let previousTags = Set(spaces.values.map(\.spaceTag))
		var next: [String: SharedSpace] = [:]
		for info in infos {
			guard SpaceKey.isHex32(info.keyHex), let tag = try? await Engine.blind(keyHex: info.keyHex, id: "space:\(info.spaceId)") else { continue }
			next[info.spaceId] = SharedSpace(info: info, spaceTag: tag)
		}
		spaces = next
		if sessionOpen {
			let _: SessionState? = try? await Engine.sync("spaces", ["spaces": .array(next.values.map(Self.spaceJSON))])
		}
		let tags = Set(next.values.map(\.spaceTag))
		if stopped || !liveUp { return } // start() wires subscriptions itself
		if tags != previousTags { subscribeLive() }
		if !tags.subtracting(previousTags).isEmpty {
			activeWalks += 1
			Task { await self.bootstrap(since: 1, resumeUntil: nil, markBootstrapped: false) }
		}
	}

	private func mirror(_ groups: [ReplayGroup]) {
		replayGroups = Dictionary(groups.map { ($0.key, $0.at) }, uniquingKeysWith: { _, last in last })
	}

	// ── Status / commit streams ──

	public func statusUpdates() -> AsyncStream<SyncStatus> {
		let id = UUID()
		let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
		statusSinks[id] = continuation
		continuation.yield(lastStatus)
		continuation.onTermination = { _ in Task { await self.dropStatusSink(id) } }
		return stream
	}

	/// Object ids whose changes were imported from a relay.
	public func commitUpdates() -> AsyncStream<[String]> {
		let id = UUID()
		let (stream, continuation) = AsyncStream<[String]>.makeStream()
		commitSinks[id] = continuation
		continuation.onTermination = { _ in Task { await self.dropCommitSink(id) } }
		return stream
	}

	private func dropStatusSink(_ id: UUID) { statusSinks[id] = nil }
	private func dropCommitSink(_ id: UUID) { commitSinks[id] = nil }

	private func emit(_ status: SyncStatus) {
		lastStatus = status
		for sink in statusSinks.values { sink.yield(status) }
	}

	private func statusDetail() -> String? {
		historyComplete ? nil : "verifying full history in background · \(importedCount) changes so far"
	}

	private func emitLiveStatus() {
		emit(SyncStatus(phase: liveUp ? .live : .backfill, imported: importedCount, pending: pendingCount, detail: liveUp ? statusDetail() : nil))
	}

	// ── Backfill ──

	/// Runs one history walk; the caller has counted it in `activeWalks`.
	private func bootstrap(since: Int64, resumeUntil: Int64?, markBootstrapped: Bool) async {
		defer { activeWalks -= 1 }
		do {
			let complete = try await backfill(since: since, resumeUntil: resumeUntil)
			if stopped { return }
			if markBootstrapped && complete { try await store.setBootstrapped() }
			emitLiveStatus()
		} catch {
			if stopped { return }
			emit(SyncStatus(phase: .error, imported: importedCount, pending: pendingCount, detail: "\(error)"))
		}
	}

	/// Walks run strictly in order: each waits for the previous one.
	private func backfill(since: Int64, resumeUntil: Int64?) async throws -> Bool {
		let previous = backfillChain
		let task = Task<Result<Bool, Error>, Never> {
			_ = await previous?.value
			do {
				return .success(try await self.walkHistory(since: since, resumeUntil: resumeUntil))
			} catch {
				await self.recordReplayFault(1)
				await self.persistCursor()
				return .failure(error)
			}
		}
		backfillChain = task
		return try await task.value.get()
	}

	/// Returns true only when EVERY relay was walked to exhaustion.
	private func walkHistory(since: Int64, resumeUntil: Int64?) async throws -> Bool {
		historyComplete = false
		// A full-history walk persists its progress page by page: a phone that
		// suspends mid-bootstrap resumes from the floor instead of restarting
		// from event zero. The floor is only meaningful while bootstrapping.
		let trackFloor = since <= 1
		walkCoveredUntil = resumeUntil
		// An unresolved group may be missing fragments older than any observed
		// part; only actual repair scans need full history.
		var since = replayGroups.isEmpty ? since : 0
		if let floor = discardedChunkFloor { since = min(since, floor) }
		// The persisted cursor is also the durable replay floor. Keep this
		// obligation until a covering scan imports every page without new faults.
		discardedChunkFloor = min(discardedChunkFloor ?? since, since)
		let checkpoint = replayFaultGeneration
		await persistCursor()

		var filters = [NostrFilter(authors: [pk], kinds: [Engine.changeKind], since: since)]
		for space in spaces.values { filters.append(NostrFilter(kinds: [Engine.changeKind], since: since, tagged: ["h": [space.spaceTag]])) }
		var byId: [String: NostrEvent] = [:]
		var complete = !relays.isEmpty
		await withTaskGroup(of: (events: [NostrEvent], complete: Bool).self) { group in
			for relay in relays {
				for filter in filters {
					group.addTask { await self.walkRelay(relay, filter: filter, resumeUntil: resumeUntil, trackFloor: trackFloor) }
				}
			}
			for await result in group {
				for event in result.events { byId[event.id] = event }
				if !result.complete { complete = false }
			}
		}

		var batch: [ImportItem] = []
		let ordered = byId.values.sorted { $0.created_at != $1.created_at ? $0.created_at < $1.created_at : $0.id < $1.id }
		for event in ordered {
			if let item = try await eventToChange(event) { batch.append(item) }
		}
		try await importBatch(batch, immediateNotify: true)

		historyComplete = complete && !stopped && replayGroups.isEmpty && activeLiveEvents == 0 && activeImports == 0 &&
			replayFaultGeneration == checkpoint && since <= (discardedChunkFloor ?? Int64.max)
		if historyComplete {
			discardedChunkFloor = nil
			if trackFloor { try await store.setBootstrapFloor(nil) }
		} else {
			await recordReplayFault(since)
		}
		let repaired = historyComplete
		await persistCursor()
		// Persistence yields to live handlers; restore the obligation if a new
		// group or fault appeared while committing the repaired cursor.
		if repaired && (!historyComplete || stopped || !replayGroups.isEmpty || activeLiveEvents > 0 || activeImports > 0 || replayFaultGeneration != checkpoint) {
			await recordReplayFault(since)
			await persistCursor()
		}
		return historyComplete
	}

	/// Pages one relay from `resumeUntil` back to `filter.since`; `complete` only on a genuine short page.
	private func walkRelay(_ relay: RelayClient, filter: NostrFilter, resumeUntil: Int64?, trackFloor: Bool) async -> (events: [NostrEvent], complete: Bool) {
		var events: [NostrEvent] = []
		var until = resumeUntil
		do {
			while true {
				if stopped { return (events, false) }
				var page = filter
				page.until = until
				page.limit = Self.pageLimit
				let batch = try await relay.query([page], timeout: Self.queryTimeout)
				events.append(contentsOf: batch)
				if batch.count < Self.pageLimit { return (events, true) }
				let oldest = batch.lazy.map(\.created_at).min()!
				if let until, oldest >= until { throw SyncError.saturatedPage }
				until = oldest
				// Coverage is only as deep as the slowest concurrent walker.
				if trackFloor {
					walkCoveredUntil = min(walkCoveredUntil ?? oldest, oldest)
					try await store.setBootstrapFloor(walkCoveredUntil)
				}
				try await Task.sleep(for: Self.pageSpacing)
			}
		} catch {
			emit(SyncStatus(phase: .backfill, imported: importedCount, pending: pendingCount, detail: "\(relay.url): \(String(describing: error).prefix(100))"))
			return (events, false)
		}
	}

	// ── Event → change ──

	private static func eventJSON(_ event: NostrEvent) -> JSONValue {
		.object([
			"pubkey": .string(event.pubkey),
			"created_at": .int(event.created_at),
			"kind": .int(Int64(event.kind)),
			"tags": .array(event.tags.map { .array($0.map(JSONValue.string)) }),
			"content": .string(event.content),
		])
	}

	/// Feed one signature-verified relay event to the session; returns the
	/// decoded change when a full change (possibly reassembled) is available.
	private func eventToChange(_ event: NostrEvent) async throws -> ImportItem? {
		guard event.kind == Engine.changeKind, NostrKey.verify(event) else { return nil }
		guard sessionOpen else { return nil } // stopped or retired
		let r: IngestResult = try await Engine.sync("ingest", ["event": Self.eventJSON(event), "nowMs": .int(Self.nowMs())])
		cursor = r.cursor
		if let at = r.faultAt { await recordReplayFault(at) }
		if let groups = r.replayGroups { mirror(groups) }
		guard let item = r.item else { return nil }
		guard let bytes = Data(base64Encoded: item.bytes) else { throw SyncError.malformedChange }
		return ImportItem(bytes: bytes, change: item.change, chunkKey: item.chunkKey, provenance: item.provenance)
	}

	/// Report a reassembled group's import outcome to the session.
	private func settle(_ chunkKey: String, imported: Bool) async {
		guard sessionOpen else { return }
		let r: SettleResult? = try? await Engine.sync("settle", ["chunkKey": .string(chunkKey), "imported": .bool(imported)])
		if let groups = r?.replayGroups { mirror(groups) }
	}

	/// Imports run strictly in order: each batch waits for the previous one.
	private func importBatch(_ batch: [ImportItem], immediateNotify: Bool) async throws {
		if batch.isEmpty { return }
		activeImports += 1
		let previous = importChain
		let task = Task<Error?, Never> {
			_ = await previous?.value
			return await self.runImport(batch, immediateNotify: immediateNotify)
		}
		importChain = task
		if let failure = await task.value { throw failure }
	}

	/// Returns the failure that aborted the batch, after settling every unimported group.
	private func runImport(_ batch: [ImportItem], immediateNotify: Bool) async -> Error? {
		var settled: Set<String> = []
		var failure: Error?
		defer { activeImports -= 1 }
		do {
			// Same-second events sort by id, so a shared object's later change can
			// precede the one that creates it and the gate refuses it as never
			// created. Refused items get another pass once the batch has landed,
			// until a pass imports nothing more.
			var pending = batch
			while !pending.isEmpty {
				var refused: [ImportItem] = []
				for item in pending {
					if try await importOne(item, settled: &settled) { continue }
					refused.append(item)
				}
				if refused.count == pending.count { break }
				pending = refused
			}
			if immediateNotify { flushObjectNotify() } else { scheduleObjectNotify() }
		} catch {
			await recordReplayFault(1)
			await persistCursor()
			failure = error
		}
		for item in batch {
			if let chunkKey = item.chunkKey, !settled.contains(chunkKey) { await settle(chunkKey, imported: false) }
		}
		return failure
	}

	/// Stores one change unless the authority gate refuses it (false).
	private func importOne(_ item: ImportItem, settled: inout Set<String>) async throws -> Bool {
		guard let objectId = item.change["objectId"]?.string, let id = item.change["id"]?.string else { throw SyncError.malformedChange }
		if let provenance = item.provenance {
			// The installed key version and its administrator (the keyring's
			// owner, else this identity) decide; a rotated keyId is refused.
			guard let space = spaces[provenance.spaceId]?.info else { return false }
			let trustedSpace = try await Engine.replay(try await store.changesFor(objectId: provenance.spaceId).map(\.json))
			let existing = try await Engine.replay(try await store.changesFor(objectId: objectId).map(\.json))
			let verdict: AuthorizeResult = try await Engine.sync("authorize", [
				"change": item.change,
				"provenance": .object(["spaceId": .string(provenance.spaceId), "keyId": .int(provenance.keyId), "signer": .string(provenance.signer)]),
				"space": .object(["spaceId": .string(space.spaceId), "keyId": .int(space.keyId), "owner": .string(space.owner ?? pk)]),
				"trustedSpace": trustedSpace ?? .null,
				"existing": existing ?? .null,
			])
			if !verdict.ok { return false }
		}
		importedCount += try await store.addChanges([ChangeRecord(id: id, objectId: objectId, bytes: item.bytes, json: item.change)])
		let publishKey = item.provenance.map { "\($0.spaceId)/\($0.keyId)/\(id)" } ?? id
		try await store.markPublished(key: publishKey)
		if let chunkKey = item.chunkKey {
			settled.insert(chunkKey)
			await settle(chunkKey, imported: true)
		}
		pendingObjects.insert(objectId)
		return true
	}

	private func recordReplayFault(_ at: Int64) async {
		replayFaultGeneration += 1
		discardedChunkFloor = min(discardedChunkFloor ?? at, at)
		historyComplete = false
		// A fault means a suspect range that must be re-covered, not skipped.
		try? await store.setBootstrapFloor(nil)
	}

	/// Cursor writes run in order: `next = min(cursor, floor - 1)` where floor is
	/// the earliest obligation; regress freely, advance only on a complete walk.
	private func persistCursor() async {
		let previous = cursorChain
		let task = Task<Void, Never> {
			await previous?.value
			await self.writeCursor()
		}
		cursorChain = task
		await task.value
	}

	private func writeCursor() async {
		do {
			let saved = try await store.cursor()
			var floor = discardedChunkFloor
			for at in replayGroups.values { floor = min(floor ?? at, at) }
			let next = floor.map { min(cursor, max(0, $0 - 1)) } ?? cursor
			let advance = next < saved || (historyComplete && activeLiveEvents == 0 && activeImports == 0 && next > saved)
			try await store.setCursor(advance ? next : saved, replayGroups: replayGroups.map { ($0.key, $0.value) })
		} catch {
			emit(SyncStatus(phase: .error, imported: importedCount, pending: pendingCount, detail: "cursor: \(error)"))
		}
	}

	// ── Live ──

	private func subscribeLive() {
		liveTask?.cancel()
		let since = cursor + 1
		let tags = spaces.values.map(\.spaceTag)
		liveTask = Task {
			await withTaskGroup(of: Void.self) { group in
				for relay in self.relays {
					group.addTask { await self.liveLoop(relay, since: since, spaceTags: tags) }
				}
			}
		}
		liveUp = true
	}

	/// Personal changes, every installed space's stream, and gift wraps for us.
	private func liveFilters(since: Int64, spaceTags: [String]) -> [NostrFilter] {
		var filters = [NostrFilter(authors: [pk], kinds: [Engine.changeKind], since: since)]
		if !spaceTags.isEmpty { filters.append(NostrFilter(kinds: [Engine.changeKind], since: since, tagged: ["h": spaceTags])) }
		filters.append(NostrFilter(kinds: [giftWrapKind], since: Int64(Date().timeIntervalSince1970) - wrapLookbackSeconds, tagged: ["p": [pk]]))
		return filters
	}

	/// One relay's live subscription; a dropped stream resubscribes from the
	/// current cursor after 2 s, doubling up to 60 s. Wraps are re-queried on
	/// every reconnect: their created_at is randomized, so no cursor covers them.
	private func liveLoop(_ relay: RelayClient, since initial: Int64, spaceTags: [String]) async {
		var since = initial
		var backoff = Self.liveBackoffFloor
		var reconnecting = false
		while !stopped && !Task.isCancelled {
			if reconnecting { await fetchWraps(from: [relay]) }
			let stream = relay.subscribe(liveFilters(since: since, spaceTags: spaceTags))
			do {
				for try await event in stream {
					if event.kind == giftWrapKind { deliverWrap(event) } else { await handleLiveEvent(event) }
					backoff = Self.liveBackoffFloor
				}
			} catch {
				if stopped || Task.isCancelled { return }
				emit(SyncStatus(phase: .backfill, imported: importedCount, pending: pendingCount, detail: "\(relay.url): \(String(describing: error).prefix(100))"))
			}
			if stopped || Task.isCancelled { return }
			try? await Task.sleep(for: backoff)
			backoff = min(backoff * 2, Self.liveBackoffCeiling)
			since = cursor + 1
			reconnecting = true
		}
	}

	// ── Gift wraps ──

	/// Every stored wrap addressed to us, oldest first, from each of `relays`.
	private func fetchWraps(from relays: [RelayClient]) async {
		let filter = NostrFilter(kinds: [giftWrapKind], tagged: ["p": [pk]])
		var byId: [String: NostrEvent] = [:]
		await withTaskGroup(of: [NostrEvent].self) { group in
			for relay in relays {
				group.addTask { (try? await relay.query([filter], timeout: Self.queryTimeout)) ?? [] }
			}
			for await events in group {
				for event in events { byId[event.id] = event }
			}
		}
		for event in byId.values.sorted(by: { $0.created_at != $1.created_at ? $0.created_at < $1.created_at : $0.id < $1.id }) { deliverWrap(event) }
	}

	private func deliverWrap(_ event: NostrEvent) {
		guard event.kind == giftWrapKind, NostrKey.verify(event) else { return }
		for sink in wrapSinks.values { sink.yield(event) }
	}

	/// Signature-verified kind-1059 events addressed to this key, from the
	/// start-up query, reconnect catch-ups and the live subscription.
	public func wrapUpdates() -> AsyncStream<NostrEvent> {
		let id = UUID()
		let (stream, continuation) = AsyncStream<NostrEvent>.makeStream()
		wrapSinks[id] = continuation
		continuation.onTermination = { _ in Task { await self.dropWrapSink(id) } }
		return stream
	}

	private func dropWrapSink(_ id: UUID) { wrapSinks[id] = nil }

	/// Every event any relay returns for `filters` within `timeout`, deduplicated.
	public func query(_ filters: [NostrFilter], timeout: Duration) async -> [NostrEvent] {
		var byId: [String: NostrEvent] = [:]
		await withTaskGroup(of: [NostrEvent].self) { group in
			for relay in relays {
				group.addTask { (try? await relay.query(filters, timeout: timeout)) ?? [] }
			}
			for await events in group {
				for event in events { byId[event.id] = event }
			}
		}
		return Array(byId.values)
	}

	/// Sends one already-signed event (gift wrap, allowlist) to the relays;
	/// succeeds when any relay accepts it.
	public func publishEvent(_ event: NostrEvent) async throws {
		try await publishToAnyRelay(event)
	}

	private func handleLiveEvent(_ event: NostrEvent) async {
		activeLiveEvents += 1
		do {
			if let item = try await eventToChange(event) { try await importBatch([item], immediateNotify: false) }
		} catch {
			await recordReplayFault(1)
			emit(SyncStatus(phase: .error, imported: importedCount, pending: pendingCount, detail: "\(error)"))
		}
		activeLiveEvents -= 1
		await persistCursor()
	}

	// ── Object-change notification batching ──

	private func flushObjectNotify() {
		notifyTask?.cancel()
		notifyTask = nil
		if pendingObjects.isEmpty { return }
		let ids = Array(pendingObjects)
		pendingObjects.removeAll()
		for sink in commitSinks.values { sink.yield(ids) }
	}

	private func scheduleObjectNotify() {
		if notifyTask != nil || pendingObjects.isEmpty { return }
		notifyTask = Task {
			try? await Task.sleep(for: Self.notifyDebounce)
			if Task.isCancelled { return }
			self.notifyTask = nil
			self.flushObjectNotify()
		}
	}

	// ── Publish ──

	/// Hands a locally committed change to the outbox: the personal obligation
	/// (`key = changeId`) and, when `spaceId` names an installed space, the
	/// shared one (`key = spaceId/keyId/changeId`) sealed under the space key.
	/// `spaceId` is the object's `channel` field, or the object itself when it
	/// is a channel; "" is personal only.
	public func publish(bytes: Data, changeId: String, objectId: String, spaceId: String = "") async throws {
		var candidates = [PendingPublish(key: changeId, objectId: objectId, changeId: changeId, bytes: bytes)]
		if let space = spaces[spaceId]?.info {
			candidates.append(PendingPublish(key: "\(space.spaceId)/\(space.keyId)/\(changeId)", objectId: objectId, changeId: changeId, bytes: bytes, spaceId: space.spaceId, keyId: space.keyId))
		}
		for item in candidates {
			if try await store.isPublished(key: item.key) { continue }
			let saved = try await store.pending(key: item.key)
			if saved == nil { try await store.savePending(item) }
			try await offerToOutbox(saved ?? item)
		}
	}

	/// The engine outbox owns order, dedupe and the rotated-key rule; the store record stays either way.
	private func offerToOutbox(_ pending: PendingPublish) async throws {
		guard sessionOpen else { return } // stopped or retired: the next start() re-offers from the store
		var record: [String: JSONValue] = [
			"key": .string(pending.key),
			"objectId": .string(pending.objectId),
			"changeId": .string(pending.changeId),
			"bytes": .string(pending.bytes.base64EncodedString()),
			"hasEvents": .bool(pending.events != nil),
		]
		if let spaceId = pending.spaceId { record["spaceId"] = .string(spaceId) }
		if let keyId = pending.keyId { record["keyId"] = .int(keyId) }
		let r: EnqueueResult = try await Engine.sync("outbox_enqueue", ["pending": .object(record)])
		pendingCount = r.pending
		guard r.queued else { return }
		queueDirty = true
		emitLiveStatus()
		if !queueRunning {
			queueRunning = true
			outboxTask = Task { await self.runPublishQueue() }
		}
	}

	/// Drains the outbox: one event per spacing, outcomes reported back so the
	/// engine applies backoff and never drops an item while the session lives.
	private func runPublishQueue() async {
		while !stopped && sessionOpen && !Task.isCancelled {
			queueDirty = false
			let next: OutboxNext
			do {
				next = try await Engine.sync("outbox_next", ["nowMs": .int(Self.nowMs())])
			} catch {
				// An unsealable change: the engine backed it off; keep draining the rest.
				emit(SyncStatus(phase: .error, imported: importedCount, pending: pendingCount, detail: "publish rejected: \(String(describing: error).prefix(120))"))
				try? await Task.sleep(for: Self.publishSpacing)
				continue
			}
			pendingCount = next.pending
			guard let item = next.item else {
				if next.pending == 0 {
					// An enqueue that landed while the engine answered must not strand its item.
					if queueDirty { continue }
					break
				}
				try? await Task.sleep(for: .milliseconds(min(500, max(50, next.waitMs))))
				continue
			}
			let outcome = await publishOnce(item)
			if sessionOpen {
				let r: OutboxResultOutcome? = try? await Engine.sync("outbox_result", [
					"key": .string(item.key), "ok": .bool(outcome.ok), "sealed": .bool(outcome.sealed), "nowMs": .int(Self.nowMs()),
				])
				if let r { pendingCount = r.pending }
			}
			try? await Task.sleep(for: Self.publishSpacing)
		}
		queueRunning = false
		emitLiveStatus()
	}

	/// Signs the engine's sealed parts on the first attempt, persists the exact
	/// signed events before sending, then sends. `sealed` tells the engine the
	/// ciphertext is on disk so retries reuse it byte for byte.
	private func publishOnce(_ item: OutboxItem) async -> (ok: Bool, sealed: Bool) {
		var sealed = false
		do {
			if try await store.isPublished(key: item.key) { return (true, sealed) }
			guard var pending = try await store.pending(key: item.key) else {
				emit(SyncStatus(phase: .error, imported: importedCount, pending: pendingCount, detail: "publish skipped: no stored obligation for \(item.key)"))
				return (true, sealed)
			}
			if pending.events == nil {
				guard let parts = item.sealed?.parts else { throw SyncError.noSignedEvents }
				let createdAt = Int64(Date().timeIntervalSince1970)
				pending.events = try parts.map { try key.sign(kind: Engine.changeKind, createdAt: createdAt, tags: $0.tags, content: $0.content) }
			}
			// Persist BEFORE sending, including after any failed store attempt.
			try await store.savePending(pending)
			sealed = true
			let events = pending.events ?? []
			for event in events {
				try await publishToAnyRelay(event)
				if events.count > 1 { try await Task.sleep(for: Self.publishSpacing) }
			}
			try await store.markPublished(key: item.key)
			return (true, sealed)
		} catch {
			emit(SyncStatus(phase: .error, imported: importedCount, pending: pendingCount, detail: "publish rejected (attempt \(item.attempts + 1)): \(String(describing: error).prefix(120))"))
			return (false, sealed)
		}
	}

	/// Success is any relay's `OK true`; every rejection is reported otherwise.
	private func publishToAnyRelay(_ event: NostrEvent) async throws {
		if relays.isEmpty { throw SyncError.noRelays }
		let failures = await withTaskGroup(of: String?.self, returning: [String]?.self) { group in
			for relay in relays {
				group.addTask {
					do {
						try await relay.publish(event, timeout: Self.publishTimeout)
						return nil
					} catch {
						return "\(relay.url): \(String(describing: error).prefix(80))"
					}
				}
			}
			var errors: [String] = []
			var accepted = false
			for await failure in group {
				if let failure { errors.append(failure) } else { accepted = true }
			}
			return accepted ? nil : errors
		}
		if let failures { throw SyncError.rejected(failures.joined(separator: " | ")) }
	}
}
