import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// The phone that could not open its vault ("query cache memory limit
/// exceeded"): 1,548 objects / 8.19 MB of state JSON, mostly small block JSON
/// objects, became 112 MB of core query cache (each object kept its parsed
/// JSON tree), the whole vault went to the core in one request, and a retry
/// reset parsed a second copy before freeing the first. A cached object now
/// holds only its compact typed state, `Backend.query` pushes in bounded
/// batches (`queryPushBudget`), and a reset frees the old snapshot first.
final class QueryCacheTests: XCTestCase {
	private let key = NostrKey.generate()

	/// cacheBytes as the core reports it: a one-change corpus push adding a probe object.
	private func cacheBytes() async throws -> Int {
		struct Pushed: Decodable { let cacheBytes: Int }
		let bytes = try await Engine.encode(.object([
			"objectId": .string("cache-probe"), "parentIds": .array([]), "timestamp": .int(1), "author": .string("probe"),
			"ops": .array([.object(["objectCreate": .object(["typeKey": .string("note")])])]),
		]))
		var blob = Data()
		var header = UInt32(bytes.count)
		withUnsafeBytes(of: &header) { blob.append(contentsOf: $0) }
		blob.append(bytes)
		let pushed: Pushed = try await GlonCore.shared.call("corpus", JSONValue.object(["action": .string("push"), "reset": .bool(false)]), blob: blob)
		return pushed.cacheBytes
	}

	func testBlockHeavyVaultQueriesAndRetriesWithinTheCache() async throws {
		// One blockAdd op as the planner writes it, re-addressed per block.
		let seedStore = InMemoryChangeStore()
		let seeder = Backend(key: key, relays: [], store: seedStore)
		let seedId = try await seeder.createNote(name: "seed", text: "seed")
		let seedChanges = try await seedStore.changesFor(objectId: seedId)
		let template = try XCTUnwrap(seedChanges.compactMap { $0.json["ops"]?.array?.first { $0["blockAdd"] != nil } }.first)
		guard case .object(var add) = template["blockAdd"] ?? .null, case .object(var block) = add["block"] ?? .null else { return XCTFail("blockAdd shape") }

		let store = InMemoryChangeStore()
		var records: [ChangeRecord] = []
		for i in 0..<1_500 {
			var ops: [JSONValue] = [
				.object(["objectCreate": .object(["typeKey": .string("note")])]),
				.object(["fieldSet": .object(["key": .string("name"), "value": .object(["stringValue": .string("Doc \(i)")])])]),
			]
			for b in 0..<90 {
				block["id"] = .string("doc-\(i)-\(b)")
				block["content"] = .object(["text": .object(["text": .string("line \(b) of doc \(i)")])])
				add["block"] = .object(block)
				ops.append(.object(["blockAdd": .object(add)]))
			}
			let bytes = try await Engine.encode(.object([
				"objectId": .string("doc-\(i)"), "parentIds": .array([]), "timestamp": .int(Int64(1_000 + i)), "author": .string("fixture"), "ops": .array(ops),
			]))
			let json = try await Engine.decode(bytes)
			records.append(ChangeRecord(id: try XCTUnwrap(json["id"]?.string), objectId: "doc-\(i)", bytes: bytes, json: json))
		}
		_ = try await store.addChanges(records)

		let backend = Backend(key: key, relays: [], store: store)
		try await backend.ensure()
		let payload = try await backend.states.values.reduce(0) { $0 + (try JSONEncoder().encode($1.state).count) }
		XCTAssertGreaterThan(payload, 10 * 1024 * 1024, "past the old cache ceiling at ~14x")

		await GlonCore.shared.resetAll()
		let found = try await backend.query(body: .object(["filters": .array([]), "limit": .int(1), "textQuery": .string("line 89 of doc 1499")]))
		XCTAssertEqual(found["total"]?.int, 1)
		let cached = try await cacheBytes()
		XCTAssertLessThan(cached, 5 * payload, "the typed model is the floor; the parsed JSON tree was ~14x")

		// "Retry opening vault": a new Backend resets over the live cache.
		let retry = Backend(key: key, relays: [], store: store)
		let again = try await retry.query(body: .object(["filters": .array([]), "limit": .int(1)]))
		XCTAssertEqual(again["total"]?.int, 1_500)
		let retried = try await cacheBytes()
		XCTAssertLessThan(Double(retried), Double(cached) * 1.1)
		await GlonCore.shared.resetAll()
	}
}
