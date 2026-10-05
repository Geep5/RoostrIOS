import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// The persisted replay memo (`replay_cache`): a cold start reuses a state
/// only when its row was written from exactly the changes and checkpoint the
/// store holds now, under the same engine; anything else replays.
final class ReplayCacheTests: XCTestCase {
	private let key = NostrKey.generate()

	private func backend(_ store: SQLiteChangeStore) -> Backend {
		Backend(key: key, relays: [], store: store, keyring: InMemorySpaceKeyring())
	}

	/// A vault replayed once with its memo written; returns the note ids.
	private func seeded(_ store: SQLiteChangeStore) async throws -> (first: String, second: String, states: [String: JSONValue]) {
		let writer = backend(store)
		let first = try await writer.createNote(name: "First", text: "alpha")
		let second = try await writer.createNote(name: "Second", text: "beta")
		_ = try await writer.mutate(action: "channel_create", params: .object(["name": .string("Personal")]))
		_ = try await writer.mutate(action: "bootstrap_space_defaults", params: .object([:]))
		try await writer.ensure()
		await writer.awaitIdle()
		let states = await writer.states.mapValues(\.state)
		await writer.stop()
		return (first, second, states)
	}

	/// Overwrites the memo of `id` with a state no replay produces, under its current input.
	private func tamper(_ store: SQLiteChangeStore, _ id: String, engineVersion: String = Backend.replayCacheVersion) async throws {
		let inputs = try await store.replayInputs()
		let input = try XCTUnwrap(inputs[id])
		let state = try JSONEncoder().encode(JSONValue.object(["id": .string(id), "typeKey": .string("note"), "fields": .object(["name": .object(["stringValue": .string("tampered")])])]))
		try await store.putCachedReplays([CachedReplay(objectId: id, input: input, state: state)], engineVersion: engineVersion)
	}

	private func name(_ backend: Backend, _ id: String) async throws -> String? {
		try await backend.object(id: id)["fields"]?["name"]?["stringValue"]?.string
	}

	/// Appends a rename on top of the object's heads, as a relay import would.
	private func appendRename(_ store: SQLiteChangeStore, _ id: String, to name: String) async throws {
		let history = try await store.changesFor(objectId: id)
		let heads = try await Engine.heads(history.map(\.json))
		let bytes = try await Engine.encode(.object([
			"objectId": .string(id), "parentIds": .array(heads.map(JSONValue.string)),
			"timestamp": .int(Int64(Date().timeIntervalSince1970 * 1000)), "author": .string("0123456789abcdef"),
			"ops": .array([.object(["fieldSet": .object(["key": .string("name"), "value": .object(["stringValue": .string(name)])])])]),
		]))
		let json = try await Engine.decode(bytes)
		_ = try await store.addChanges([ChangeRecord(id: try XCTUnwrap(json["id"]?.string), objectId: id, bytes: bytes, json: json)])
	}

	func testWarmStartServesStatesIdenticalToAFreshReplayWithoutReplaying() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let seed = try await seeded(store)
		let rows = try await store.cachedReplays(objectIds: Array(seed.states.keys), engineVersion: Backend.replayCacheVersion)
		XCTAssertEqual(Set(rows.keys), Set(seed.states.keys), "every replayed object has its memo")
		XCTAssertGreaterThan(seed.states.count, 3, "a space beside the notes")

		let warm = backend(store)
		try await warm.ensure()
		let replays = await warm.replayCount
		XCTAssertEqual(replays, 0, "nothing changed since the memo: no replay")
		let states = await warm.states.mapValues(\.state)
		XCTAssertEqual(states, seed.states, "a memo hit is the state a fresh replay produced")
		let channels = try await warm.channels()
		XCTAssertFalse(channels.isEmpty)
	}

	func testMatchingInputIsServedAndANewChangeInvalidatesIt() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let seed = try await seeded(store)
		try await tamper(store, seed.first)

		let hit = backend(store)
		let served = try await name(hit, seed.first)
		XCTAssertEqual(served, "tampered", "a row whose input matches is served as is")

		try await appendRename(store, seed.first, to: "Renamed")
		let next = backend(store)
		let renamed = try await name(next, seed.first)
		XCTAssertEqual(renamed, "Renamed", "a new change replays")
		let replays = await next.replayCount
		XCTAssertEqual(replays, 1, "only the changed object replays")
		await next.awaitIdle()
		let input = try await store.replayInputs()[seed.first]
		let row = try await store.cachedReplays(objectIds: [seed.first], engineVersion: Backend.replayCacheVersion)[seed.first]
		XCTAssertEqual(row?.input, input, "the fresh replay rewrote the memo")
	}

	func testANewCheckpointInvalidatesTheMemo() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let seed = try await seeded(store)
		try await tamper(store, seed.first)
		let ids = try await store.changesFor(objectId: seed.first).map(\.id)
		let heads = try await Engine.heads(try await store.changesFor(objectId: seed.first).map(\.json))
		let checkpoint = CheckpointSyncTests.checkpointBytes(objectId: seed.first, typeKey: "note", fields: [("name", "from-checkpoint")], heads: heads, covered: ids, createdAt: 2)
		let stored = try await store.putCheckpoint(CheckpointRecord(objectId: seed.first, bytes: checkpoint, hash: String(repeating: "ab", count: 32), heads: heads, covered: ids.count))
		XCTAssertTrue(stored)

		let next = backend(store)
		let replayed = try await name(next, seed.first)
		XCTAssertEqual(replayed, "from-checkpoint", "the same changes under a new checkpoint replay")
	}

	func testAnotherEngineVersionInvalidatesTheMemo() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let seed = try await seeded(store)
		try await tamper(store, seed.first, engineVersion: "an-older-core/1")

		let next = backend(store)
		let replayed = try await name(next, seed.first)
		XCTAssertEqual(replayed, "First", "a row another core wrote is never served")
		let replays = await next.replayCount
		XCTAssertEqual(replays, 1)
	}

	func testRebuildLocalStatesDropsTheMemoAndReplaysEverything() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let seed = try await seeded(store)
		try await tamper(store, seed.second)
		let warm = backend(store)
		let served = try await name(warm, seed.second)
		XCTAssertEqual(served, "tampered")

		try await warm.rebuildLocalStates()
		let rebuilt = try await name(warm, seed.second)
		XCTAssertEqual(rebuilt, "Second")
		let replays = await warm.replayCount
		XCTAssertEqual(replays, seed.states.count, "every object replayed from its changes")
		let states = await warm.states.mapValues(\.state)
		XCTAssertEqual(states, seed.states)
	}

	func testLogoutClearsTheMemo() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let seed = try await seeded(store)
		let session = backend(store)
		try await session.ensure()
		// No relay took the notes: logout needs them exported.
		let export = FileManager.default.temporaryDirectory.appendingPathComponent("roostr-pending-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: export) }
		try await session.logout(exportTo: export)
		let rows = try await store.cachedReplays(objectIds: Array(seed.states.keys), engineVersion: Backend.replayCacheVersion)
		XCTAssertTrue(rows.isEmpty)
	}

	func testReplayInputsMatchWhatReplayConsumes() async throws {
		let store = try SQLiteChangeStore.inMemory()
		let seed = try await seeded(store)
		let inputs = try await store.replayInputs()
		for id in seed.states.keys {
			let changes = try await store.changesFor(objectId: id)
			XCTAssertEqual(inputs[id], ReplayInput(changeIds: changes.map(\.id), checkpointHash: ""), id)
		}
	}
}
