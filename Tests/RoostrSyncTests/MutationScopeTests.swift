import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// A mutation request carries no states: the planner reads the engine's query
/// cache (core `mutation_states`), which `applyMutation` flushes first. An
/// object the params name that the cache lacks comes back missing and is
/// retried once as overlay (`Backend.plan`). Same contract and test as
/// RoostrWebsite scripts/mutation-scope.test.ts.
final class MutationScopeTests: XCTestCase {
	/// Ids `statesOf` was asked for, across the planner's retry.
	private actor Asked {
		var ids: [[String]] = []
		func record(_ batch: [String]) { ids.append(batch) }
	}

	/// Writes the process-global cache behind every Backend's back, so the
	/// next Backend push resets it.
	private func cache(_ states: [JSONValue], of backend: Backend) async throws {
		let _: JSONValue = try await Engine.call("query", [
			"upserts": .array(states.map(packCoreValueMaps)),
			"removed": .array([]),
			"reset": .bool(true),
			"nowMs": .int(1),
		])
		backend.forgetQuerySnapshot()
	}

	/// The old contract: the caller's complete snapshot, the planner's reference answer.
	private func snapshotPlan(_ action: String, _ params: JSONValue, _ objects: [JSONValue], seed: String) async throws -> MutationPlan {
		try await Engine.call("mutation", [
			"action": .string(action), "params": params, "objects": .array(objects.map(packCoreValueMaps)),
			"timestamp": .int(1_000), "author": .string("scope-test"), "id_seed": .string(seed), "key_id": .int(0),
		])
	}

	private func plan(_ action: String, _ params: JSONValue, seed: String, asked: Asked, states: [JSONValue] = []) async throws -> MutationPlan {
		try await Backend.plan(action: action, params: params, timestamp: 1_000, author: "scope-test", idSeed: seed, keyId: 0) { ids in
			await asked.record(ids)
			return states.filter { ids.contains($0["id"]?.string ?? "") }
		}
	}

	private func blockAdd(_ state: JSONValue, target: String) throws -> JSONValue {
		let textBlock = try XCTUnwrap(state["blocks"]?.array?.first { $0["content"]?["text"] != nil })
		return .object([
			"object_id": .string(target),
			"block": .object(["content": .object(["text": .object(["text": .string("second")])])]),
			"target_id": textBlock["id"] ?? .null,
			"position": .int(2),
		])
	}

	func testMutationPlansOverTheCacheWithoutStates() async throws {
		let backend = Backend(key: NostrKey.generate(), relays: [], store: InMemoryChangeStore())
		let target = try await backend.createNote(name: "Target", text: "first")
		let big = try await backend.createNote(name: "Big", text: "seed")
		let states = await backend.states
		let targetState = try XCTUnwrap(states[target]?.state)

		// ~1.7 MB of blocks, inside one native query push (`queryPushBudget`):
		// the cache holds it, the mutation request never carries it.
		guard case .object(var huge) = try XCTUnwrap(states[big]?.state), case .array(var blocks) = huge["blocks"] ?? .null,
		      case .object(let template) = try XCTUnwrap(blocks.first { $0["content"]?["text"] != nil }) else { return XCTFail("note shape") }
		let filler = String(repeating: "lorem ipsum ", count: 25)
		for i in 0..<5_000 {
			var block = template
			block["id"] = .string("filler-\(i)")
			block["content"] = .object(["text": .object(["text": .string("\(i) \(filler)")])])
			blocks.append(.object(block))
		}
		huge["blocks"] = .array(blocks)
		try await cache([targetState, .object(huge)], of: backend)

		let params = try blockAdd(targetState, target: target)
		let asked = Asked()
		let planned = try await plan("block_add", params, seed: "seed", asked: asked)
		let askedIds = await asked.ids
		XCTAssertEqual(askedIds, [], "every named object came from the cache")
		XCTAssertFalse(planned.changes.isEmpty)
		let reference = try await snapshotPlan("block_add", params, [targetState, .object(huge)], seed: "seed")
		XCTAssertEqual(planned.changes, reference.changes)
		XCTAssertEqual(planned.result, reference.result)
	}

	func testObjectTheCacheLacksIsFetchedAndRetriedOnce() async throws {
		let backend = Backend(key: NostrKey.generate(), relays: [], store: InMemoryChangeStore())
		let target = try await backend.createNote(name: "Uncached", text: "first")
		let held = await backend.states[target]?.state
		let targetState = try XCTUnwrap(held)
		try await cache([], of: backend)

		let params = try blockAdd(targetState, target: target)
		let asked = Asked()
		let planned = try await plan("block_add", params, seed: "seed-missing", asked: asked, states: [targetState])
		let askedIds = await asked.ids
		XCTAssertEqual(askedIds, [[target]])
		let reference = try await snapshotPlan("block_add", params, [targetState], seed: "seed-missing")
		XCTAssertEqual(planned.changes, reference.changes)

		// An id no replica holds plans as the snapshot without it would.
		let ghost: JSONValue = .object(["object_id": .string("ghost-object"), "key": .string("status"), "value": .object(["stringValue": .string("done")])])
		let ghostPlan = try await plan("set_field", ghost, seed: "seed-ghost", asked: Asked())
		let ghostReference = try await snapshotPlan("set_field", ghost, [], seed: "seed-ghost")
		XCTAssertEqual(ghostPlan.changes, ghostReference.changes)
	}

	/// `createNote` is two consecutive mutations, the second on the object the
	/// first created: each commit reaches the cache before the next plan.
	func testConsecutiveMutationsSeeEachOther() async throws {
		let backend = Backend(key: NostrKey.generate(), relays: [], store: InMemoryChangeStore())
		let space = try await backend.mutate(action: "create", params: .object(["type_key": .string("channel"), "name": .string("Home")]))
		let note = try await backend.createNote(name: "Fresh", text: "hello")
		let held = await backend.states[note]?.state
		let state = try XCTUnwrap(held)
		XCTAssertEqual(state["blocks"]?.array?.count, 1, "the block landed on the object created just before")
		XCTAssertEqual(state["fields"]?["channel"]?["stringValue"], space["id"], "create found the space in the cache")

		try await backend.syncQueryCache()
		let response = try await Engine.mutation(action: "set_field", params: .object(["object_id": .string(note), "key": .string("done"), "value": .object(["boolValue": .bool(true)])]),
		                                          timestamp: 1_000, author: "scope-test", idSeed: "seed", keyId: 0)
		guard case .plan(let plan) = response else { return XCTFail("the committed note is in the cache") }
		XCTAssertEqual(plan.changes.count, 1)
	}
}
