import Foundation
import GlonCore

/// One upcoming occurrence of a recurring object, for device reminders.
public struct Occurrence: Sendable, Equatable, Identifiable {
	public let objectId: String
	public let name: String
	public let typeKey: String
	/// Epoch ms of the occurrence (`repeat.next`).
	public let at: Int64
	/// Assigned to an agent: it runs on the machine serving the space, not here.
	public let agentOwned: Bool

	public var id: String { "\(objectId):\(at)" }
}

extension Backend {
	/// Live recurring objects whose current occurrence is still ahead of `now`,
	/// soonest first. The engine keeps `repeat.next`; this only reads it.
	public func upcomingOccurrences(after now: Int64, limit: Int) async throws -> [Occurrence] {
		try await ensure()
		var out: [Occurrence] = []
		for (id, cached) in states {
			let state = cached.state
			if id == vanishLogId || vanished.contains(id) || state["deleted"]?.bool == true { continue }
			guard let fields = state["fields"], let next = Self.repeatEntries(fields)?["next"]?["intValue"]?.int, next > now else { continue }
			out.append(Occurrence(
				objectId: id,
				name: fields["name"]?["stringValue"]?.string ?? "",
				typeKey: state["typeKey"]?.string ?? "",
				at: next,
				agentOwned: fields["assignee"] != nil || fields["agent"] != nil
			))
		}
		out.sort { $0.at != $1.at ? $0.at < $1.at : $0.objectId < $1.objectId }
		return Array(out.prefix(limit))
	}

	/// The `repeat` map's entries as a plain dictionary, whichever map form the state carries.
	static func repeatEntries(_ fields: JSONValue) -> [String: JSONValue]? {
		guard let entries = fields["repeat"]?["mapValue"]?["entries"] else { return nil }
		if let object = entries.object { return object }
		guard let pairs = entries.array else { return nil }
		var out: [String: JSONValue] = [:]
		for pair in pairs {
			guard let items = pair.array, items.count == 2, let key = items[0].string else { continue }
			out[key] = items[1]
		}
		return out
	}
}
