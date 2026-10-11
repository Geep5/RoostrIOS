import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// A mutation hands the planner full states only for the objects its params
/// name; every other object goes without blocks. A vault holding a huge
/// unrelated object (whose blocks alone would overrun the core's per-request
/// arena) still mutates, with the plan full states of the named objects give.
final class MutationScopeTests: XCTestCase {
	func testHugeUnrelatedObjectDoesNotChangeOrBreakThePlan() async throws {
		let backend = Backend(key: NostrKey.generate(), relays: [], store: InMemoryChangeStore())
		let target = try await backend.createNote(name: "Target", text: "first")
		let big = try await backend.createNote(name: "Big", text: "seed")
		try await backend.ensure()
		let states = await backend.states
		let targetState = try XCTUnwrap(states[target]?.state)
		let textBlock = try XCTUnwrap(targetState["blocks"]?.array?.first { $0["content"]?["text"] != nil })
		let textBlockId = try XCTUnwrap(textBlock["id"]?.string)

		// ~10 MB of blocks: what made the real vault's restart panic the core.
		guard case .object(var huge) = try XCTUnwrap(states[big]?.state), case .array(var blocks) = huge["blocks"] ?? .null,
		      case .object(let template) = try XCTUnwrap(blocks.first { $0["content"]?["text"] != nil }) else { return XCTFail("note shape") }
		let filler = String(repeating: "lorem ipsum ", count: 25)
		for i in 0..<25_000 {
			var block = template
			block["id"] = .string("filler-\(i)")
			block["content"] = .object(["text": .object(["text": .string("\(i) \(filler)")])])
			blocks.append(.object(block))
		}
		huge["blocks"] = .array(blocks)
		let full = packCoreValueMaps(.object(huge))
		XCTAssertGreaterThan(try JSONEncoder().encode(full).count, 8_000_000)

		let params: JSONValue = .object([
			"object_id": .string(target),
			"block": .object(["content": .object(["text": .object(["text": .string("second")])])]),
			"target_id": .string(textBlockId),
			"position": .int(2),
		])
		let scoped = Backend.mutationObjects([targetState, .object(huge)], params: params)
		XCTAssertLessThan(try JSONEncoder().encode(scoped).count, 100_000, "the unrelated object goes without its blocks")
		XCTAssertEqual(scoped.first { $0["id"]?.string == target }, packCoreValueMaps(targetState), "the named object keeps its full state")

		func plan(_ objects: [JSONValue]) async throws -> (changes: [JSONValue], result: JSONValue) {
			let p = try await Engine.mutation(action: "block_add", params: params, objects: objects, timestamp: 1_000, author: "scope-test", idSeed: "seed", keyId: 0)
			return (p.changes, p.result)
		}
		let withScope = try await plan(scoped)
		let reference = try await plan([packCoreValueMaps(targetState)])
		XCTAssertFalse(withScope.changes.isEmpty)
		XCTAssertEqual(withScope.changes, reference.changes)
		XCTAssertEqual(withScope.result, reference.result)
	}

	/// ~2,000 imported bookmarks with inline image icons crashed the core; the
	/// planner never reads other objects' icons, so they stay out of the request.
	func testUnrelatedImageIconsStayOutOfThePlan() async throws {
		let backend = Backend(key: NostrKey.generate(), relays: [], store: InMemoryChangeStore())
		let target = try await backend.createNote(name: "Target", text: "first")
		let other = try await backend.createNote(name: "Other", text: "seed")
		try await backend.ensure()
		let states = await backend.states
		let icon: JSONValue = .object(["stringValue": .string("data:image/png;base64," + String(repeating: "A", count: 16_000))])
		guard case .object(var named) = try XCTUnwrap(states[target]?.state), case .object(var namedFields) = named["fields"] ?? .null,
		      case .object(let otherState) = try XCTUnwrap(states[other]?.state), case .object(let otherFields) = otherState["fields"] ?? .null else { return XCTFail("note shape") }
		namedFields["iconImage"] = icon
		named["fields"] = .object(namedFields)
		let many: [JSONValue] = (0..<2_000).map { i in
			var o = otherState
			var f = otherFields
			f["iconImage"] = icon
			o["id"] = .string("icon-\(i)")
			o["fields"] = .object(f)
			return .object(o)
		}
		let scoped = Backend.mutationObjects([.object(named)] + many, params: .object(["object_id": .string(target)]))
		XCTAssertLessThan(try JSONEncoder().encode(scoped).count, 2_000_000, "unrelated icons stay out")
		XCTAssertEqual(scoped.first { $0["id"]?.string == target }, packCoreValueMaps(.object(named)), "the named object keeps its icon")
	}
}
