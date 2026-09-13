import Foundation
import GlonCore

// Shared spaces on the device: the keyring + replayed channel objects become
// the engine's shared view; the owner gift-wraps keys to members and collects
// join requests; a joiner imports keys from wraps or invite links. Ports
// backend.ts refreshShared and the gift-wrap half of sync.ts.

/// String key/value rows the host keeps beside the changes: what the
/// browser stored in localStorage. A store without durable meta (tests)
/// keeps them for the process lifetime.
public protocol MetaStore: Sendable {
	func meta(_ key: String) async throws -> String?
	/// Upserts; nil deletes.
	func setMeta(_ key: String, _ value: String?) async throws
}

public actor InMemoryMetaStore: MetaStore {
	private var rows: [String: String] = [:]

	public init() {}

	public func meta(_ key: String) throws -> String? { rows[key] }
	public func setMeta(_ key: String, _ value: String?) throws { rows[key] = value }
}

/// A knock on an owned space (sync.ts JoinRequest).
public struct JoinRequest: Codable, Sendable, Equatable {
	/// "spaceId/requesterHex" - stable dedupe key.
	public var key: String
	public var space: String
	public var spaceName: String
	public var requester: String
	public var requesterNpub: String
	/// kind-0 profile at request time, when the relays had one.
	public var name: String?
	public var picture: String?
	/// Unix milliseconds.
	public var at: Int64

	public init(key: String, space: String, spaceName: String, requester: String, requesterNpub: String, name: String? = nil, picture: String? = nil, at: Int64) {
		self.key = key; self.space = space; self.spaceName = spaceName; self.requester = requester; self.requesterNpub = requesterNpub; self.name = name; self.picture = picture; self.at = at
	}
}

let inviteRumorKind = 24891
let joinRequestRumorKind = 24892
private let allowlistKind = 30100
private let allowlistD = "roostr-allowlist"
private let wrapsSeenKey = "wraps-seen"
private let invitesSentKey = "invites-sent"
private let joinRequestsKey = "join-requests"
private let wrapsSeenLimit = 2000
private let profileTimeout: Duration = .seconds(3)

private let metaEncoder: JSONEncoder = {
	let encoder = JSONEncoder()
	encoder.outputFormatting = .withoutEscapingSlashes
	return encoder
}()
private let metaDecoder = JSONDecoder()

extension Backend {
	// ── Reconcile ──

	/// Queues a shared-space reconcile after the ones already queued.
	func scheduleRefreshShared() {
		let previous = refreshChain
		refreshChain = Task {
			await previous?.value
			await self.refreshSharedNow()
		}
	}

	/// Reconciles and waits for it.
	func refreshShared() async {
		scheduleRefreshShared()
		await refreshChain?.value
	}

	/// Build the shared view from local space keys + member fields, hand it to
	/// the engine, send keys and the relay allowlist for owned spaces, and
	/// (re)queue every change of a space under its current key: publication
	/// acknowledgements, not enqueue markers, determine durability.
	private func refreshSharedNow() async {
		do {
			try await ensure()
			let myPk = key.pubkey
			var infos: [SharedSpaceInfo] = []
			var membersBySpace: [String: [String]] = [:]
			var nameBySpace: [String: String] = [:]
			for (spaceId, entry) in try keyring.all().sorted(by: { $0.key < $1.key }) {
				guard SpaceKey.isHex32(entry.key) else { continue }
				let state = states[spaceId]?.state
				var writers = [entry.owner ?? myPk]
				var memberHexes: [String] = []
				for member in Self.members(of: state) {
					guard let hex = await Self.pubkeyHex(member.npub) else { continue }
					memberHexes.append(hex)
					if member.role == "writer" && !writers.contains(hex) { writers.append(hex) }
				}
				if memberHexes.isEmpty && entry.owner == nil { continue }
				membersBySpace[spaceId] = memberHexes
				nameBySpace[spaceId] = state?["fields"]?["name"]?["stringValue"]?.string ?? ""
				infos.append(SharedSpaceInfo(spaceId: spaceId, keyHex: entry.key, keyId: entry.keyId, writers: writers, owner: entry.owner))
			}
			await engine.setSharedSpaces(infos)

			// Owner duty: every member holds the current key - gift-wrap it to
			// anyone that hasn't received this keyId yet (adds and rotations).
			let owned = infos.filter { $0.owner == nil || $0.owner == myPk }
			for info in owned {
				guard let members = membersBySpace[info.spaceId], !members.isEmpty else { continue }
				queueInviteWraps(spaceId: info.spaceId, keyHex: info.keyHex, keyId: info.keyId, name: nameBySpace[info.spaceId] ?? "", members: members)
			}
			if !owned.isEmpty {
				var writers: [String] = []
				for info in owned { for writer in info.writers where !writers.contains(writer) { writers.append(writer) } }
				await publishAllowlist(writers: writers)
			}

			for info in infos {
				for objectId in states.keys where spaceOf(objectId) == info.spaceId {
					for change in try await store.changesFor(objectId: objectId) {
						if try await store.isPublished(key: "\(info.spaceId)/\(info.keyId)/\(change.id)") { continue }
						// Existing IDs address original wire bytes, not a canonical re-encoding.
						try await engine.publish(bytes: change.bytes, changeId: change.id, objectId: objectId, spaceId: info.spaceId)
					}
				}
			}
		} catch {
			// Nothing durable was skipped: the next reconcile retries from the store.
		}
	}

	/// `members` items of a channel state as (npub, role).
	private static func members(of state: JSONValue?) -> [(npub: String, role: String)] {
		(state?["fields"]?["members"]?["valuesValue"]?["items"]?.array ?? []).compactMap { item in
			guard let entries = item["mapValue"]?["entries"] else { return nil }
			return (entries["npub"]?["stringValue"]?.string ?? "", entries["role"]?["stringValue"]?.string ?? "")
		}
	}

	/// npub or 64-hex → lowercase hex pubkey (sync.ts npubToHex).
	static func pubkeyHex(_ text: String) async -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if let decoded = try? await Bech32.decode(trimmed), decoded.hrp == "npub" { return decoded.hex }
		let lower = trimmed.lowercased()
		return SpaceKey.isHex32(lower) ? lower : nil
	}

	// ── Owner duties ──

	/// Owner duty: publish the relay write-allowlist (retried on the next reconcile).
	private func publishAllowlist(writers: [String]) async {
		let others = writers.filter { $0 != key.pubkey }
		guard let event = try? key.sign(kind: allowlistKind, createdAt: Int64(Date().timeIntervalSince1970), tags: [["d", allowlistD]] + others.map { ["p", $0] }, content: "") else { return }
		try? await engine.publishEvent(event)
	}

	private func queueInviteWraps(spaceId: String, keyHex: String, keyId: Int64, name: String, members: [String]) {
		let previous = inviteChain
		inviteChain = Task {
			await previous?.value
			await self.sendInviteWraps(spaceId: spaceId, keyHex: keyHex, keyId: keyId, name: name, members: members)
		}
	}

	/// Gift-wrap the current space key to every member that hasn't received
	/// this keyId yet. Idempotent per (space, member, keyId); a relay refusal
	/// is retried on the next reconcile.
	private func sendInviteWraps(spaceId: String, keyHex: String, keyId: Int64, name: String, members: [String]) async {
		var sent: [String: Int64] = (try? await loadMeta(invitesSentKey, as: [String: Int64].self)) ?? [:]
		for hex in members where hex != key.pubkey {
			let sentKey = "\(spaceId)/\(hex)"
			if sent[sentKey] == keyId { continue }
			do {
				let content = try Self.json(["t": .string("space-invite"), "space": .string(spaceId), "name": .string(name), "key": .string(keyHex), "keyId": .int(keyId)])
				let wrap = try await GiftWrap.wrap(kind: inviteRumorKind, content: content, sender: key, recipient: hex)
				try await engine.publishEvent(wrap)
				sent[sentKey] = keyId
				try await saveMeta(invitesSentKey, sent)
			} catch {
				continue
			}
		}
	}

	// ── Gift wraps in ──

	/// One kind-1059 event addressed to us: a space-key invite from the
	/// space's administrator, or a join request on a space we administer.
	func handleWrap(_ event: NostrEvent) async {
		var seen = (try? await loadMeta(wrapsSeenKey, as: [String].self)) ?? []
		if seen.contains(event.id) { return }
		seen.append(event.id)
		if seen.count > wrapsSeenLimit { seen.removeFirst(seen.count - wrapsSeenLimit) }
		try? await saveMeta(wrapsSeenKey, seen)
		guard let rumor = try? await GiftWrap.unwrap(event, recipient: key),
			let payload = try? metaDecoder.decode(JSONValue.self, from: Data(rumor.content.utf8)) else { return }
		switch rumor.kind {
		case inviteRumorKind:
			guard payload["t"]?.string == "space-invite", let space = payload["space"]?.string, !space.isEmpty,
				let keyHex = payload["key"]?.string, SpaceKey.isHex32(keyHex),
				let keyId = payload["keyId"]?.int, keyId >= 1
			else { return }
			// Only the administrator we already trust may replace a key.
			if let previous = try? keyring.get(space), rumor.pubkey != (previous.owner ?? key.pubkey) { return }
			guard (try? keyring.import(space, key: keyHex, keyId: keyId, owner: rumor.pubkey)) != nil else { return }
			scheduleRefreshShared()
		case joinRequestRumorKind:
			guard payload["t"]?.string == "join-request", let space = payload["space"]?.string, !space.isEmpty else { return }
			// Only the administrator of the space collects requests: the keyring
			// holds its key without an owner (or naming us).
			guard let entry = try? keyring.get(space), entry.owner == nil || entry.owner == key.pubkey else { return }
			// The requester's public kind-0 profile, so the owner can put a
			// face to the knock before approving; npub alone otherwise.
			let profile = await fetchProfile(rumor.pubkey)
			guard let npub = try? await Bech32.npub(rumor.pubkey) else { return }
			await recordJoinRequest(JoinRequest(
				key: "\(space)/\(rumor.pubkey)",
				space: space,
				spaceName: states[space]?.state["fields"]?["name"]?["stringValue"]?.string ?? "",
				requester: rumor.pubkey,
				requesterNpub: npub,
				name: profile.name,
				picture: profile.picture,
				at: Int64(Date().timeIntervalSince1970 * 1000)
			))
		default:
			return
		}
	}

	private func fetchProfile(_ pubkey: String) async -> (name: String?, picture: String?) {
		let events = await engine.query([NostrFilter(authors: [pubkey], kinds: [0], limit: 3)], timeout: profileTimeout)
		guard let newest = events.max(by: { $0.created_at < $1.created_at }),
			let meta = try? metaDecoder.decode(JSONValue.self, from: Data(newest.content.utf8))
		else { return (nil, nil) }
		let display = meta["display_name"]?.string ?? ""
		return (display.isEmpty ? meta["name"]?.string : display, meta["picture"]?.string)
	}

	private func recordJoinRequest(_ request: JoinRequest) async {
		var requests = await joinRequests().filter { $0.key != request.key }
		requests.append(request)
		try? await saveMeta(joinRequestsKey, requests)
	}

	// ── Contract surface ──

	public func joinRequests() async -> [JoinRequest] {
		(try? await loadMeta(joinRequestsKey, as: [JoinRequest].self)) ?? []
	}

	public func clearJoinRequest(key: String) async {
		let rest = await joinRequests().filter { $0.key != key }
		try? await saveMeta(joinRequestsKey, rest)
	}

	/// Knock on `space`: gift-wrap a join request to its owner (npub or hex)
	/// and publish it to `relays`; an empty list means this backend's relays.
	public func sendJoinRequest(space: String, owner: String, relays: [String]) async throws {
		guard let ownerHex = await Self.pubkeyHex(owner) else { throw BackendError.invalidPubkey(owner) }
		let content = try Self.json(["t": .string("join-request"), "space": .string(space)])
		let wrap = try await GiftWrap.wrap(kind: joinRequestRumorKind, content: content, sender: key, recipient: ownerHex)
		let targets = relays.compactMap(URL.init(string:)).map { WebSocketRelay(url: $0) }
		if targets.isEmpty {
			try await engine.publishEvent(wrap)
			return
		}
		let failures = await withTaskGroup(of: String?.self, returning: [String]?.self) { group in
			for relay in targets {
				group.addTask {
					do {
						try await relay.publish(wrap, timeout: .seconds(10))
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
		if let failures { throw BackendError.rejected(failures.joined(separator: " | ")) }
	}

	/// Accept an invite link (sync.ts importSpaceInvite): store the space key;
	/// the reconcile backfills the space from the relays. False when the link
	/// is malformed or names a different administrator than the installed key.
	public func importSpaceInvite(space: String, owner: String, key keyHex: String, keyId: Int64) async -> Bool {
		guard !space.isEmpty, SpaceKey.isHex32(keyHex), keyId >= 1, let ownerHex = await Self.pubkeyHex(owner) else { return false }
		if let previous = try? keyring.get(space), (previous.owner ?? key.pubkey) != ownerHex { return false }
		guard (try? keyring.import(space, key: keyHex, keyId: keyId, owner: ownerHex)) != nil else { return false }
		scheduleRefreshShared()
		return true
	}

	/// Live channels as the website's SpaceJSON, creation order oldest first:
	/// the first channel is the stable default space of unassigned objects.
	public func channels() async throws -> [JSONValue] {
		try await ensure()
		var spaces: [(createdAt: Int64, id: String, json: JSONValue)] = []
		for (id, cached) in states {
			let state = cached.state
			guard state["typeKey"]?.string == "channel", !(state["deleted"]?.bool ?? false) else { continue }
			let fields = state["fields"]
			let createdAt = state["createdAt"]?.int ?? 0
			var json: [String: JSONValue] = [
				"id": .string(id),
				"name": .string(fields?["name"]?["stringValue"]?.string ?? ""),
				"icon": .string(fields?["iconEmoji"]?["stringValue"]?.string ?? ""),
				"pinnedIds": .array((fields?["pinnedIds"]?["valuesValue"]?["items"]?.array ?? []).compactMap { $0["stringValue"]?.string }.filter { !$0.isEmpty }.map(JSONValue.string)),
				"members": .array(Self.members(of: state).map { .object(["npub": .string($0.npub), "role": .string($0.role)]) }),
				"keyId": .int(fields?["keyId"]?["intValue"]?.int ?? 1),
				"createdAt": .int(createdAt),
			]
			// Display order for the rail; absent means "use createdAt".
			if let order = fields?["order"]?["floatValue"] ?? fields?["order"]?["intValue"] { json["order"] = order }
			spaces.append((createdAt, id, .object(json)))
		}
		spaces.sort { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
		return spaces.map(\.json)
	}

	// ── Meta helpers ──

	private static func json(_ fields: [String: JSONValue]) throws -> String {
		String(decoding: try metaEncoder.encode(JSONValue.object(fields)), as: UTF8.self)
	}

	private func loadMeta<T: Decodable>(_ key: String, as type: T.Type) async throws -> T? {
		guard let raw = try await hostMeta.meta(key) else { return nil }
		return try metaDecoder.decode(type, from: Data(raw.utf8))
	}

	private func saveMeta<T: Encodable>(_ key: String, _ value: T) async throws {
		try await hostMeta.setMeta(key, String(decoding: try metaEncoder.encode(value), as: UTF8.self))
	}
}
