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

/// One decrypted relay payload: a change (kind 1078) or a checkpoint (kind 1079).
private struct ImportItem: Sendable {
	let objectId: String
	let bytes: Data
	/// `bytes` as the core handed them over; the checkpoint gate takes them back verbatim.
	let base64: String
	let change: JSONValue?
	let checkpoint: CheckpointSummary?
	let chunkKey: String?
	let provenance: SharedProvenance?
	/// The relay events this item was read from: held once it imports.
	let held: [HeldEvent]
}

/// One stream a history pass covers: the NIP-77 filter and the paged walk's filter.
private struct HistoryStream: Sendable {
	let reconcile: NostrFilter
	let walk: NostrFilter
}

private enum Reconciled {
	/// Every id the relay holds beyond ours came back and imported.
	case complete
	case incomplete
	/// No usable NIP-77 answer (NEG-ERR, NOTICE, CLOSED, timeout, bad message): page instead.
	case unsupported
}

/// NIP-59 gift wrap: space-key invites and join requests, addressed by pubkey.
private let giftWrapKind = 1059
/// Gift wraps randomize created_at up to ~2 days back; look back further.
private let wrapLookbackSeconds: Int64 = 3 * 86_400

public actor SyncEngine {
	private static let pageLimit = 128
	/// Ids per `REQ {ids}` after a reconciliation: a checkpoint event can run
	/// to ~40k chars, so 100 stay well inside the relay's 8 MiB response budget.
	private static let fetchBatch = 100
	private static let checkpointFetchBatch = 8
	private static let walkRetryDelay: Duration = .seconds(30)
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
	/// Why the last history walk stopped short ("" once one completes); shown in the status detail.
	private var lastWalkFailure = ""
	/// The checkpoint pass of a walk has run: every object has its cached state, history is still streaming in.
	private var checkpointsLoaded = false
	private var walkRetry: Task<Void, Never>?
	private var walkCoveredUntil: Int64?
	private var stopped = false
	private var liveUp = false
	/// History walks in flight (the bootstrap walk and shared-space backfills).
	private var activeWalks = 0
	private var activeLiveEvents = 0
	private var activeImports = 0
	private var importedCount = 0
	private var checkpointCount = 0
	/// Mirror of the outbox's queued-not-in-flight count, for the status.
	private var pendingCount = 0
	private var queueRunning = false
	private var queueDirty = false

	private var walkTask: Task<Void, Never>?
	private var liveTask: Task<Void, Never>?
	private var outboxTask: Task<Void, Never>?
	private var resumeTask: Task<Void, Never>?
	private var importChain: Task<Error?, Never>?
	/// Walks run strictly in order, as the browser's backfillChain.
	private var backfillChain: Task<Result<Bool, Error>, Never>?
	private var cursorChain: Task<Void, Never>?
	private var notifyTask: Task<Void, Never>?
	private var pendingObjects: Set<String> = []
	/// Relays that answered NEG-OPEN with a NOTICE: this process pages them.
	private var negentropyUnsupported: Set<URL> = []
	/// Held events of chunk groups still assembling, by `pubkey/kind/gid`.
	private var heldParts: [String: [HeldEvent]] = [:]

	private var lastStatus = SyncStatus(phase: .idle)
	private var statusSinks: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
	private var commitSinks: [UUID: AsyncStream<[String]>.Continuation] = [:]
	private var wrapSinks: [UUID: AsyncStream<NostrEvent>.Continuation] = [:]
	private var spaceVanishSinks: [UUID: AsyncStream<String>.Continuation] = [:]

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
			// A device an earlier build walked from a kind-30079 manifest floor
			// never held the older history: this also clears its bootstrapped
			// flag, so it walks from zero once (docs/checkpoint-sync.md).
			try await store.forgetCheckpointFloors()
			cursor = try await store.cursor()
			try await openSession()
			if stopped {
				await closeSession()
				return
			}
			for pending in try await store.pendingPublishes() { try await offerToOutbox(pending) }
		} catch {
			emit(SyncStatus(phase: .error, imported: importedCount, pending: pendingCount, detail: "\(error)"))
			return
		}
		emit(SyncStatus(phase: .backfill, imported: 0, pending: pendingCount))

		// The incremental `since = cursor+1` shortcut is only sound once ONE full
		// history walk has completed on this device: the cursor tracks the newest
		// imported event, so an interrupted first bootstrap would otherwise skip
		// everything older, forever. It only applies to relays paged without
		// NIP-77: a reconciliation always compares a stream's whole set. The
		// walk runs in the background; live subscriptions come up first and
		// imports dedupe against its pages.
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
		walkRetry?.cancel()
		walkRetry = nil
		liveTask?.cancel()
		outboxTask?.cancel()
		notifyTask?.cancel()
		notifyTask = nil
		await closeSession()
		for sink in statusSinks.values { sink.finish() }
		for sink in commitSinks.values { sink.finish() }
		for sink in wrapSinks.values { sink.finish() }
		for sink in spaceVanishSinks.values { sink.finish() }
		statusSinks.removeAll()
		commitSinks.removeAll()
		wrapSinks.removeAll()
		spaceVanishSinks.removeAll()
	}

	/// Brings sync back now instead of trusting sockets that may be dead: the
	/// app returned to the foreground, the network path changed, or the user
	/// asked to refresh. Drops every relay socket (one that outlived a
	/// suspension can be half-open and never fail), resubscribes live from the
	/// cursor without the reconnect backoff, re-fetches gift wraps and wakes
	/// the outbox so pending publishes go out at once. Concurrent calls share
	/// one pass; a no-op until `start()` has brought the live subscriptions up.
	public func resume() async {
		if let resumeTask { return await resumeTask.value }
		guard !stopped, liveUp else { return }
		let task = Task { await self.reconnect() }
		resumeTask = task
		await task.value
		resumeTask = nil
	}

	private func reconnect() async {
		emit(SyncStatus(phase: .backfill, imported: importedCount, pending: pendingCount, detail: "Reconnecting…"))
		liveTask?.cancel()
		for relay in relays { await relay.disconnect() }
		if stopped { return }
		subscribeLive()
		let reachable = await fetchWraps(from: relays)
		if stopped { return }
		await wakeOutbox()
		// No answer: the live loops report their failures and keep redialing.
		if reachable { emitLiveStatus() }
	}

	/// Test helper: resolves when no walk, import, live event, publish or
	/// debounced object notification is in flight.
	public func awaitIdle() async {
		while activeWalks > 0 || activeImports > 0 || activeLiveEvents > 0 || queueRunning || notifyTask != nil {
			try? await Task.sleep(for: .milliseconds(20))
		}
	}

	private func openSession() async throws {
		let groups = try await store.replayGroups()
		let state: SessionState = try await Engine.sync("session", [
			"pk": .string(pk),
			"conversationKey": .string(try await Engine.conversationKey(sharedX: try key.sharedX(with: pk))),
			"secret": .string(key.secretHex),
			"spaces": .array(spaces.values.map(spaceJSON)),
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

	/// A session space; `owner` is the administrator whose kind 5 vanishes it.
	private func spaceJSON(_ space: SharedSpace) -> JSONValue {
		.object(["spaceId": .string(space.info.spaceId), "keyHex": .string(space.info.keyHex), "keyId": .int(space.info.keyId), "owner": .string(space.info.owner ?? pk)])
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
			let _: SessionState? = try? await Engine.sync("spaces", ["spaces": .array(next.values.map(spaceJSON))])
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
		if historyComplete { return nil }
		let progress = "\(importedCount) changes\(checkpointCount > 0 ? ", \(checkpointCount) checkpoints" : "") so far"
		if lastWalkFailure.isEmpty { return checkpointsLoaded ? "verifying full history · \(progress)" : "loading spaces · \(progress)" }
		return "history incomplete, retrying · \(progress) · \(lastWalkFailure)"
	}

	private func emitLiveStatus() {
		emit(SyncStatus(phase: liveUp ? .live : .backfill, imported: importedCount, pending: pendingCount, detail: liveUp ? statusDetail() : nil))
	}

	// ── Backfill ──

	/// Runs one history walk; the caller has counted it in `activeWalks`. A
	/// walk that stops short is walked again from its floor until one
	/// completes: nothing else would ever finish the history.
	private func bootstrap(since: Int64, resumeUntil: Int64?, markBootstrapped: Bool) async {
		defer { activeWalks -= 1 }
		do {
			let complete = try await backfill(since: since, resumeUntil: resumeUntil)
			if stopped { return }
			if complete {
				lastWalkFailure = ""
				if markBootstrapped { try await store.setBootstrapped() }
				emitLiveStatus()
				return
			}
			if lastWalkFailure.isEmpty { lastWalkFailure = "a page did not import cleanly" }
		} catch {
			if stopped { return }
			lastWalkFailure = String(describing: error).prefix(100).description
		}
		emitLiveStatus()
		scheduleWalkRetry()
	}

	private func scheduleWalkRetry() {
		guard walkRetry == nil else { return }
		walkRetry = Task {
			try? await Task.sleep(for: Self.walkRetryDelay)
			walkRetry = nil
			if stopped { return }
			let bootstrapped = (try? await store.bootstrapped()) ?? false
			let floor: Int64? = bootstrapped ? nil : ((try? await store.bootstrapFloor()) ?? nil)
			activeWalks += 1
			await bootstrap(since: bootstrapped ? cursor + 1 : 1, resumeUntil: floor, markBootstrapped: !bootstrapped)
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

	/// Returns true only when EVERY relay was reconciled (NIP-77) or walked to
	/// exhaustion for every stream.
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

		let full = since <= 1
		// Checkpoints are walked to the end FIRST: every object renders from its
		// cache within a few pages, then the change history streams in behind
		// (docs/checkpoint-sync.md - a checkpoint never shortens the history).
		// A reconciliation always covers a stream's whole set, so its filter
		// takes the full walk's bounds whatever `since` an incremental walk uses.
		var checkpointStreams = [HistoryStream(
			reconcile: NostrFilter(authors: [pk], kinds: [Engine.checkpointKind]),
			walk: NostrFilter(authors: [pk], kinds: [Engine.checkpointKind], since: since)
		)]
		var changeStreams = [HistoryStream(
			reconcile: NostrFilter(authors: [pk], kinds: [Engine.changeKind]),
			walk: NostrFilter(authors: [pk], kinds: [Engine.changeKind], since: since)
		)]
		for space in spaces.values {
			let tagged = ["h": [space.spaceTag]]
			changeStreams.append(HistoryStream(
				reconcile: NostrFilter(kinds: [Engine.changeKind], tagged: tagged),
				walk: NostrFilter(kinds: [Engine.changeKind], since: since, tagged: tagged)
			))
			// The administrator's stream deletion travels with the checkpoints: unbounded on a full walk.
			checkpointStreams.append(HistoryStream(
				reconcile: NostrFilter(kinds: [Engine.checkpointKind, Engine.deletionKind], tagged: tagged),
				walk: NostrFilter(kinds: [Engine.checkpointKind, Engine.deletionKind], since: since, tagged: tagged)
			))
		}
		// Imported batch by batch, never buffered until the pass ends: a phone
		// that locks or suspends mid-walk keeps every page it fetched, and
		// spaces appear as their history lands (lib/engine/sync.ts walkHistory).
		// The checkpoint pass is short and re-walked whole on every resume, so
		// it neither starts from nor moves the bootstrap floor, which belongs
		// to the change walk alone.
		var complete = !relays.isEmpty
		for (streams, resume, track) in [(checkpointStreams, nil as Int64?, false), (changeStreams, resumeUntil, trackFloor)] {
			try await withThrowingTaskGroup(of: Bool.self) { group in
				for relay in relays {
					group.addTask { try await self.syncRelay(relay, streams: streams, resumeUntil: resume, trackFloor: track) }
				}
				for try await relayComplete in group where !relayComplete { complete = false }
			}
			if !checkpointsLoaded {
				checkpointsLoaded = true
				emitLiveStatus()
			}
		}
		// Every relay answered for every filter and nothing faulted: a
		// CHECKPOINT group still open is missing parts no relay holds (NIP-09
		// took a superseded checkpoint's chunks; the newer one covers the
		// object). The core retires only those - a change group stays until a
		// covering repair, since a missing change is missing data.
		if complete && !stopped && replayFaultGeneration == checkpoint && sessionOpen {
			let r: SettleResult? = try? await Engine.sync("retire", ["since": .int(full ? 0 : since)])
			if let groups = r?.replayGroups { mirror(groups) }
		}

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

	/// Reconciles `streams` with `relay` one at a time (the relay caps NIP-77
	/// sessions per connection), then pages, concurrently, every stream it
	/// could not reconcile. True only when every stream completed.
	private func syncRelay(_ relay: RelayClient, streams: [HistoryStream], resumeUntil: Int64?, trackFloor: Bool) async throws -> Bool {
		var complete = true
		var walks: [NostrFilter] = []
		for stream in streams {
			switch try await reconcileRelay(relay, filter: stream.reconcile) {
			case .complete: break
			case .incomplete: complete = false
			case .unsupported: walks.append(stream.walk)
			}
		}
		if walks.isEmpty { return complete }
		return try await withThrowingTaskGroup(of: Bool.self) { group in
			for filter in walks {
				group.addTask { try await self.walkRelay(relay, filter: filter, resumeUntil: resumeUntil, trackFloor: trackFloor) }
			}
			for try await walked in group where !walked { complete = false }
			return complete
		}
	}

	/// NIP-77 against the events this device holds for `filter`, then the
	/// relay's surplus fetched by id and imported batch by batch. A relay
	/// failure or an id the relay does not return leaves the stream
	/// incomplete; a store failure propagates.
	private func reconcileRelay(_ relay: RelayClient, filter: NostrFilter) async throws -> Reconciled {
		if stopped { return .incomplete }
		if negentropyUnsupported.contains(relay.url) { return .unsupported }
		let local = try NegentropyStorage(try await store.heldEvents(matching: filter).map { ($0.createdAt, $0.id) })
		let need: [String]
		do {
			need = try await relay.reconcile(filter, local: local, timeout: Self.queryTimeout)
		} catch RelayError.unsupported {
			negentropyUnsupported.insert(relay.url)
			return .unsupported
		} catch RelayError.negentropy, RelayError.closed, RelayError.timeout, is NegentropyError {
			return .unsupported
		} catch {
			lastWalkFailure = "\(relay.url): \(String(describing: error).prefix(100))"
			return .incomplete
		}
		var complete = true
		// Checkpoint events run to ~40k chars each: 100 per REQ is a multi-MB
		// burst that a slow phone link cannot drain before the relay's send
		// deadline, so the socket drops and the same batch fails forever.
		let batchSize = filter.kinds?.contains(Engine.checkpointKind) == true ? Self.checkpointFetchBatch : Self.fetchBatch
		for start in stride(from: 0, to: need.count, by: batchSize) {
			if stopped { return .incomplete }
			if start > 0 { try await Task.sleep(for: Self.pageSpacing) }
			let ids = Array(need[start..<min(start + batchSize, need.count)])
			let wanted = Set(ids)
			let batch: [NostrEvent]
			do {
				batch = try await relay.query([NostrFilter(ids: ids)], timeout: Self.queryTimeout).filter { wanted.contains($0.id) }
			} catch {
				lastWalkFailure = "\(relay.url): \(String(describing: error).prefix(100))"
				return .incomplete
			}
			let missing = wanted.subtracting(batch.map(\.id)).count
			if missing > 0 {
				complete = false
				lastWalkFailure = "\(relay.url): \(missing) reconciled events not returned"
			}
			try await importEvents(batch)
		}
		return complete ? .complete : .incomplete
	}

	/// Pages one relay from `resumeUntil` back to `filter.since`, importing each
	/// page; `true` only on a genuine short page. A relay failure ends this
	/// filter's walk (false); a store failure propagates.
	private func walkRelay(_ relay: RelayClient, filter: NostrFilter, resumeUntil: Int64?, trackFloor: Bool) async throws -> Bool {
		var until = resumeUntil
		while true {
			if stopped { return false }
			var page = filter
			page.until = until
			page.limit = Self.pageLimit
			let batch: [NostrEvent]
			do {
				batch = try await relay.query([page], timeout: Self.queryTimeout)
				if batch.count == Self.pageLimit, let until, batch.lazy.map(\.created_at).min()! >= until { throw SyncError.saturatedPage }
			} catch {
				lastWalkFailure = "\(relay.url): \(String(describing: error).prefix(100))"
				return false
			}
			try await importEvents(batch)
			if batch.count < Self.pageLimit { return true }
			let oldest = batch.lazy.map(\.created_at).min()!
			until = oldest
			// Coverage is only as deep as the slowest concurrent walker.
			if trackFloor {
				walkCoveredUntil = min(walkCoveredUntil ?? oldest, oldest)
				try await store.setBootstrapFloor(walkCoveredUntil)
			}
			try await Task.sleep(for: Self.pageSpacing)
		}
	}

	/// Ingests and imports one fetched batch, then reports progress.
	private func importEvents(_ batch: [NostrEvent]) async throws {
		// Checkpoints first within a second: a change the checkpoint already
		// folds in then lands as covered tail, never as a solitary orphan.
		var items: [ImportItem] = []
		for event in batch.sorted(by: { ($0.created_at, -$0.kind, $0.id) < ($1.created_at, -$1.kind, $1.id) }) {
			if let item = try await ingest(event) { items.append(item) }
		}
		try await importBatch(items, immediateNotify: true)
		emitLiveStatus()
	}

	// ── Event → change / checkpoint ──

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
	/// decoded payload when a full change or checkpoint (possibly reassembled)
	/// is available. A space administrator's kind 5 goes to the vanish sinks.
	/// An event the session consumed cleanly becomes held: with its item once
	/// that imports, with its group's item for a chunk part, else at once.
	private func ingest(_ event: NostrEvent) async throws -> ImportItem? {
		guard event.kind == Engine.changeKind || event.kind == Engine.checkpointKind || event.kind == Engine.deletionKind, NostrKey.verify(event) else { return nil }
		guard sessionOpen else { return nil } // stopped or retired
		let r: IngestResult = try await Engine.sync("ingest", ["event": Self.eventJSON(event), "nowMs": .int(Self.nowMs())])
		cursor = r.cursor
		if let at = r.faultAt { await recordReplayFault(at) }
		if let groups = r.replayGroups { mirror(groups) }
		if let spaceId = r.spaceVanished {
			for sink in spaceVanishSinks.values { sink.yield(spaceId) }
		}
		let held = HeldEvent(event)
		let group = event.tags.first { $0.first == "c" && $0.count > 1 }.map { "\(event.pubkey)/\(event.kind)/\($0[1])" }
		guard let item = r.item else {
			if r.faultAt == nil && r.decryptFailure != true && r.decodeFailure != true {
				if let group { heldParts[group, default: []].append(held) } else { try await store.recordHeld([held]) }
			}
			return nil
		}
		guard let bytes = Data(base64Encoded: item.bytes) else { throw SyncError.malformedChange }
		let objectId: String
		if let checkpoint = item.checkpoint { objectId = checkpoint.objectId }
		else if let id = item.change?["objectId"]?.string { objectId = id }
		else { throw SyncError.malformedChange }
		let parts = group.flatMap { heldParts.removeValue(forKey: $0) } ?? []
		return ImportItem(objectId: objectId, bytes: bytes, base64: item.bytes, change: item.change, checkpoint: item.checkpoint, chunkKey: item.chunkKey, provenance: item.provenance, held: parts + [held])
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

	/// Stores one change or checkpoint unless the authority gate refuses it (false).
	private func importOne(_ item: ImportItem, settled: inout Set<String>) async throws -> Bool {
		if let provenance = item.provenance, !(try await authorized(item, provenance)) { return false }
		if let checkpoint = item.checkpoint {
			// Keep a checkpoint when it beats the one held (more covered, then
			// hash). A superseded copy is still a clean import: re-scanning
			// would only produce it again.
			let record = CheckpointRecord(objectId: item.objectId, bytes: item.bytes, hash: checkpoint.hash, heads: checkpoint.headIds.sorted(), covered: checkpoint.covered)
			if try await store.putCheckpoint(record) {
				checkpointCount += 1
				pendingObjects.insert(item.objectId)
			}
		} else {
			guard let change = item.change, let id = change["id"]?.string else { throw SyncError.malformedChange }
			importedCount += try await store.addChanges([ChangeRecord(id: id, objectId: item.objectId, bytes: item.bytes, json: change)])
			let publishKey = item.provenance.map { "\($0.spaceId)/\($0.keyId)/\(id)" } ?? id
			try await store.markPublished(key: publishKey)
			pendingObjects.insert(item.objectId)
		}
		try await store.recordHeld(item.held)
		if let chunkKey = item.chunkKey {
			settled.insert(chunkKey)
			await settle(chunkKey, imported: true)
		}
		return true
	}

	/// The installed key version and its administrator (the keyring's owner,
	/// else this identity) decide; a rotated keyId is refused. A checkpoint
	/// bypasses per-op authority, so only the space owner may publish one.
	private func authorized(_ item: ImportItem, _ provenance: SharedProvenance) async throws -> Bool {
		guard let space = spaces[provenance.spaceId]?.info else { return false }
		let trustedSpace = try await replayStored(provenance.spaceId)
		let existing = try await replayStored(item.objectId)
		var payload: [String: JSONValue] = [
			"provenance": .object(["spaceId": .string(provenance.spaceId), "keyId": .int(provenance.keyId), "signer": .string(provenance.signer)]),
			"space": .object(["spaceId": .string(space.spaceId), "keyId": .int(space.keyId), "owner": .string(space.owner ?? pk)]),
			"trustedSpace": trustedSpace ?? .null,
			"existing": existing ?? .null,
		]
		if item.checkpoint != nil { payload["checkpoint"] = .string(item.base64) } else { payload["change"] = item.change ?? .null }
		let verdict: AuthorizeResult = try await Engine.sync(item.checkpoint != nil ? "authorizeCheckpoint" : "authorize", payload)
		return verdict.ok
	}

	/// Current state of a stored object: its checkpoint (if any) plus the tail.
	private func replayStored(_ objectId: String) async throws -> JSONValue? {
		let changes = try await store.changesFor(objectId: objectId).map(\.json)
		let checkpoint = try await store.checkpoint(objectId: objectId)
		return try await Engine.replay(changes, checkpoint: checkpoint?.bytes)
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

	/// Personal changes and checkpoints, every installed space's stream (with
	/// its administrator's stream deletion), and gift wraps for us.
	private func liveFilters(since: Int64, spaceTags: [String]) -> [NostrFilter] {
		let kinds = [Engine.changeKind, Engine.checkpointKind]
		var filters = [NostrFilter(authors: [pk], kinds: kinds, since: since)]
		if !spaceTags.isEmpty { filters.append(NostrFilter(kinds: kinds + [Engine.deletionKind], since: since, tagged: ["h": spaceTags])) }
		filters.append(NostrFilter(kinds: [giftWrapKind], since: Int64(Date().timeIntervalSince1970) - wrapLookbackSeconds, tagged: ["p": [pk]]))
		return filters
	}

	/// One relay's live subscription; a dropped stream resubscribes from the
	/// current cursor after 2 s, doubling up to 60 s. Wraps are re-queried on
	/// every reconnect: their created_at is randomized, so no cursor covers them.
	/// A reconnect the relay answers resets the backoff, reports live again and
	/// wakes the outbox, whose items backed off while the socket was down.
	private func liveLoop(_ relay: RelayClient, since initial: Int64, spaceTags: [String]) async {
		var since = initial
		var backoff = Self.liveBackoffFloor
		var reconnecting = false
		while !stopped && !Task.isCancelled {
			if reconnecting, await fetchWraps(from: [relay]), !stopped, !Task.isCancelled {
				backoff = Self.liveBackoffFloor
				await wakeOutbox()
				emitLiveStatus()
			}
			let stream = relay.subscribe(liveFilters(since: since, spaceTags: spaceTags))
			do {
				for try await event in stream {
					if event.kind == giftWrapKind { deliverWrap(event) } else { await handleLiveEvent(event) }
					backoff = Self.liveBackoffFloor
				}
			} catch {
				if stopped || Task.isCancelled { return }
				emit(SyncStatus(phase: .backfill, imported: importedCount, pending: pendingCount, detail: "Reconnecting… \(relay.url): \(String(describing: error).prefix(100))"))
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
	/// True when at least one relay answered.
	@discardableResult
	private func fetchWraps(from relays: [RelayClient]) async -> Bool {
		let filter = NostrFilter(kinds: [giftWrapKind], tagged: ["p": [pk]])
		var byId: [String: NostrEvent] = [:]
		var answered = false
		await withTaskGroup(of: [NostrEvent]?.self) { group in
			for relay in relays {
				group.addTask { try? await relay.query([filter], timeout: Self.queryTimeout) }
			}
			for await events in group {
				guard let events else { continue }
				answered = true
				for event in events { byId[event.id] = event }
			}
		}
		for event in byId.values.sorted(by: { $0.created_at != $1.created_at ? $0.created_at < $1.created_at : $0.id < $1.id }) { deliverWrap(event) }
		return answered
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

	/// Space ids whose administrator deleted them for every member (a verified
	/// kind 5 on the space's stream), from backfills and the live subscription.
	public func spaceVanishUpdates() -> AsyncStream<String> {
		let id = UUID()
		let (stream, continuation) = AsyncStream<String>.makeStream()
		spaceVanishSinks[id] = continuation
		continuation.onTermination = { _ in Task { await self.dropSpaceVanishSink(id) } }
		return stream
	}

	private func dropSpaceVanishSink(_ id: UUID) { spaceVanishSinks[id] = nil }

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
			if let item = try await ingest(event) { try await importBatch([item], immediateNotify: false) }
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
		drainOutbox()
	}

	private func drainOutbox() {
		if !queueRunning {
			queueRunning = true
			outboxTask = Task { await self.runPublishQueue() }
		}
	}

	/// The transport is back: queued publishes skip the backoff their failures earned.
	private func wakeOutbox() async {
		guard sessionOpen, !stopped else { return }
		guard let r: OutboxResultOutcome = try? await Engine.sync("outbox_wake") else { return }
		pendingCount = r.pending
		if r.pending > 0 {
			queueDirty = true
			drainOutbox()
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
			// A relay holds them now: a reconciliation must not fetch them back.
			try await store.recordHeld(events.map(HeldEvent.init))
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
