import CryptoKit
import Foundation
import GlonCore

// The website's backend surface (RoostrWebsite/src/lib/engine/backend.ts)
// over the Swift replica: list/relation/query projections, the sync digest
// and the logout rule. Shapes are the website's `types.ts`, byte for byte,
// so the unchanged Svelte UI renders them.

/// `backend.ts logout`: the replica may only die once every change reached a relay or left the device.
public enum LogoutError: Error, CustomStringConvertible, Equatable {
	case unpublishedChanges(Int)

	public var description: String {
		switch self {
		case .unpublishedChanges: return "Unpublished changes remain on this device. Connect to a relay or explicitly export them before logging out."
		}
	}
}

/// Mirror of `query.ts`'s module state. The engine's query cache is
/// process-global (one `GlonCore`), so the host-side signature snapshot that
/// diffs against it is too; a different `Backend` instance is a different
/// vault and forces `reset`. A signature is the change count plus the checkpoint
/// hash: `ensure()` only replaces a state when one of them moved, and vanished ids leave `states`.
private final class QuerySignatures: @unchecked Sendable {
	static let shared = QuerySignatures()
	private let lock = NSLock()
	private var owner: ObjectIdentifier?
	private var signatures: [String: String] = [:]

	struct Diff {
		let upserts: [JSONValue]
		let removed: [String]
		let reset: Bool
		let next: [String: String]
	}

	func diff(owner: ObjectIdentifier, states: [String: Backend.Cached]) -> Diff {
		lock.withLock {
			let reset = self.owner != owner
			var next: [String: String] = [:]
			next.reserveCapacity(states.count)
			var upserts: [JSONValue] = []
			for (id, cached) in states {
				let signature = "\(cached.changeCount):\(cached.checkpointHash)"
				next[id] = signature
				if reset || signatures[id] != signature { upserts.append(cached.state) }
			}
			var removed: [String] = []
			if !reset {
				for id in signatures.keys where next[id] == nil { removed.append(id) }
			}
			return Diff(upserts: upserts, removed: removed, reset: reset, next: next)
		}
	}

	/// Failed dispatches leave the previous snapshot intact; only call after the engine accepted the update.
	func commit(owner: ObjectIdentifier, _ diff: Diff) {
		lock.withLock {
			self.owner = owner
			signatures = diff.next
		}
	}
}

private func fstr(_ fields: JSONValue?, _ key: String) -> String {
	fields?[key]?["stringValue"]?.string ?? ""
}

private func items(_ fields: JSONValue?, _ key: String) -> [JSONValue] {
	fields?[key]?["valuesValue"]?["items"]?.array ?? []
}

extension Backend {
	/// The Odin server's GET /api/objects summary exclusions, verbatim.
	static let hiddenListTypes: Set<String> = ["program", "typescript", "json", "proto", "relation", "channel", "skill", "peer", "pinned_fact", "milestone", "descriptor", "install", "vanish_log"]

	/// `fetchObjects`: website `ObjectSummary[]`, newest first.
	public func summaries() async throws -> [JSONValue] {
		try await ensure()
		var rows: [(updatedAt: Int64, id: String, row: JSONValue)] = []
		rows.reserveCapacity(states.count)
		for (id, cached) in states {
			let state = cached.state
			if state["deleted"]?.bool == true || Self.hiddenListTypes.contains(state["typeKey"]?.string ?? "") { continue }
			let fields = state["fields"]
			rows.append((state["updatedAt"]?.int ?? 0, id, .object([
				"id": .string(id),
				"typeKey": state["typeKey"] ?? .string(""),
				"name": .string(fstr(fields, "name")),
				"updatedAt": state["updatedAt"] ?? .int(0),
				"channelId": .string(fstr(fields, "channel")),
				"icon": .string(fstr(fields, "iconEmoji")),
				"done": .bool(fields?["done"]?["boolValue"]?.bool == true),
			])))
		}
		rows.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
		return rows.map(\.row)
	}

	/// `fetchRelations`: website `RelationDefJSON[]`; defs without a key are dropped.
	public func relations() async throws -> [JSONValue] {
		try await ensure()
		var out: [JSONValue] = []
		for (id, cached) in states.sorted(by: { $0.key < $1.key }) {
			let state = cached.state
			if state["deleted"]?.bool == true || state["typeKey"]?.string != "relation" { continue }
			let fields = state["fields"]
			let key = fstr(fields, "key")
			if key.isEmpty { continue }
			let options: [JSONValue] = items(fields, "options").compactMap { item in
				guard let entries = item["mapValue"]?["entries"] else { return nil }
				return .object([
					"id": .string(fstr(entries, "id")),
					"text": .string(fstr(entries, "text")),
					"color": .string(fstr(entries, "color")),
					"orderId": .string(fstr(entries, "orderId")),
				])
			}
			let format = fstr(fields, "format")
			var row: [String: JSONValue] = [
				"id": .string(id),
				"key": .string(key),
				"format": .string(format.isEmpty ? "shorttext" : format),
				"name": .string(fstr(fields, "name")),
				"iconEmoji": .string(fstr(fields, "iconEmoji")),
				"space": .string(fstr(fields, "channel")),
				"hidden": .bool(fields?["hidden"]?["boolValue"]?.bool == true),
				"readOnly": .bool(fields?["readOnly"]?["boolValue"]?.bool == true),
				"maxCount": fields?["maxCount"]?["intValue"] ?? .int(0),
				"objectTypes": .array(items(fields, "object_types").compactMap { $0["stringValue"]?.string }.filter { !$0.isEmpty }.map(JSONValue.string)),
				"options": .array(options),
			]
			let source = fstr(fields, "object_source")
			if !source.isEmpty { row["objectSource"] = .string(source) }
			out.append(.object(row))
		}
		return out
	}

	/// `fetchQuery`: the engine's incremental query over the replayed states,
	/// fed only what changed since the last call (`query.ts` cache protocol).
	public func query(body: JSONValue) async throws -> JSONValue {
		try await ensure()
		let owner = ObjectIdentifier(self)
		let diff = QuerySignatures.shared.diff(owner: owner, states: states)
		let result: JSONValue = try await Engine.call("query", [
			"upserts": .array(diff.upserts),
			"removed": .array(diff.removed.map(JSONValue.string)),
			"reset": .bool(diff.reset),
			"body": body,
			"nowMs": .int(Int64(Date().timeIntervalSince1970 * 1000)),
		])
		QuerySignatures.shared.commit(owner: owner, diff)
		return result
	}

	/// State fingerprint matching the desktop's GET /api/sync/digest: sha256
	/// over `"<objectId>:<sorted change hex ids>\n"` lines, objects sorted,
	/// vanished objects excluded (read from the synced vanish ledger object).
	public func syncDigest() async throws -> JSONValue {
		try await ensure()
		let ids = try await store.objectIds().filter { !vanished.contains($0) }.sorted()
		var text = ""
		var changes = 0
		var objects = 0
		for objectId in ids {
			let changeIds = try await store.changesFor(objectId: objectId).map(\.id).sorted()
			if changeIds.isEmpty { continue }
			text += "\(objectId):\(changeIds.joined(separator: ","))\n"
			changes += changeIds.count
			objects += 1
		}
		let digest = Hex.encode(Data(SHA256.hash(data: Data(text.utf8))))
		return .object(["digest": .string(digest), "objects": .int(Int64(objects)), "changes": .int(Int64(changes))])
	}

	/// One full history walk has completed on this device (`SyncStatus.bootstrapped`).
	public func bootstrapped() async -> Bool {
		(try? await store.bootstrapped()) ?? false
	}

	/// `backend.ts logout`: stops sync once no unpublished change would be
	/// lost. Pending publishes are written as a JSON `[PendingPublish]` to
	/// `exportTo` when given, otherwise their presence refuses the logout.
	/// Forgetting the key and deleting the database is the host's job.
	public func logout(exportTo: URL?) async throws {
		let pending = try await store.pendingPublishes()
		if !pending.isEmpty {
			guard let exportTo else { throw LogoutError.unpublishedChanges(pending.count) }
			try JSONEncoder().encode(pending).write(to: exportTo, options: .atomic)
		}
		await stop()
	}
}
