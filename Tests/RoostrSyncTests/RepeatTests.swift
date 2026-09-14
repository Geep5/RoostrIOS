import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// Recurring objects through the Swift host: the engine owns the rule and the
/// occurrence math; the host only supplies its clock and UTC offset.
final class RepeatTests: XCTestCase {
	func testRecurringTaskIsNeverDone() async throws {
		let backend = Backend(key: NostrKey.generate(), relays: [FakeRelay()], store: InMemoryChangeStore(), keyring: InMemorySpaceKeyring())
		await backend.start()
		defer { Task { await backend.stop() } }
		let created = try await backend.mutate(action: "create", params: .object(["name": .string("Water the plants"), "type_key": .string("task")]))
		let id = try XCTUnwrap(created["id"]?.string)

		// Sunday 2026-09-13 10:00 in UTC-7; a Sunday/Wednesday rule at 23:30 starts today.
		let now: Int64 = 1_789_318_800_000
		let clock: [String: JSONValue] = ["now_ms": .int(now), "tz_offset_min": .int(-420)]
		let rule: JSONValue = .object(["freq": .string("week"), "interval": .int(1), "weekdays": .array([.int(0), .int(3)]), "time": .int(1410), "tz": .string("America/Los_Angeles")])
		let set = try await backend.mutate(action: "repeat_set", params: .object(["object_id": .string(id), "rule": rule].merging(clock) { a, _ in a }))
		let today2330 = Int64(1_789_367_400_000) // 2026-09-14T06:30:00Z
		XCTAssertEqual(set["next"]?.int, today2330)

		// Ticking done completes the occurrence instead of finishing the task.
		let ticked = try await backend.mutate(action: "set_field", params: .object(["object_id": .string(id), "key": .string("done"), "value": .object(["boolValue": .bool(true)])].merging(clock) { a, _ in a }))
		XCTAssertEqual(ticked["next"]?.int, 1_789_626_600_000, "Wednesday 23:30 local") // 2026-09-17T06:30:00Z
		let object = try await backend.object(id: id)
		XCTAssertEqual(object["fields"]?["done"]?["boolValue"]?.bool, false)
		let repeatValue = object["fields"]?["repeat"]?["mapValue"]?["entries"]
		XCTAssertEqual(repeatValue?["count"]?["intValue"]?.int, 1)
		XCTAssertEqual(repeatValue?["last_done"]?["intValue"]?.int, now)

		// The scheduler's mark is single-use per occurrence.
		let fire: [String: JSONValue] = ["object_id": .string(id), "for_ms": .int(1_789_626_600_000), "machine": .string("mac-test"), "now_ms": .int(now)]
		_ = try await backend.mutate(action: "occurrence_fire", params: .object(fire))
		do {
			_ = try await backend.mutate(action: "occurrence_fire", params: .object(fire))
			XCTFail("second fire must be refused")
		} catch {
			XCTAssertEqual(error as? GlonError, .engine("occurrence already fired"))
		}
		let fired = try await backend.object(id: id)
		XCTAssertEqual(fired["fields"]?["repeat"]?["mapValue"]?["entries"]?["fired_by"]?["stringValue"]?.string, "mac-test")

		_ = try await backend.mutate(action: "repeat_clear", params: .object(["object_id": .string(id)]))
		let cleared = try await backend.object(id: id)
		XCTAssertNil(cleared["fields"]?["repeat"])
	}
}

extension RepeatTests {
	func testUpcomingOccurrencesListLiveRecurringObjectsSoonestFirst() async throws {
		let backend = Backend(key: NostrKey.generate(), relays: [FakeRelay()], store: InMemoryChangeStore(), keyring: InMemorySpaceKeyring())
		await backend.start()
		defer { Task { await backend.stop() } }
		let now: Int64 = 1_789_318_800_000 // Sun 2026-09-13 10:00 UTC-7
		let clock: [String: JSONValue] = ["now_ms": .int(now), "tz_offset_min": .int(-420)]
		func recurring(_ name: String, type: String, time: Int64, agent: Bool = false) async throws -> String {
			var fields: [String: JSONValue] = [:]
			if agent { fields["assignee"] = .object(["stringValue": .string("agent-1")]) }
			let created = try await backend.mutate(action: "create", params: .object(["name": .string(name), "type_key": .string(type), "fields": .object(fields)]))
			let id = try XCTUnwrap(created["id"]?.string)
			_ = try await backend.mutate(action: "repeat_set", params: .object(["object_id": .string(id), "rule": .object(["freq": .string("day"), "interval": .int(1), "time": .int(time)])].merging(clock) { a, _ in a }))
			return id
		}
		let evening = try await recurring("Water the plants", type: "task", time: 1200)   // 20:00 today
		let noon = try await recurring("Weekly review", type: "page", time: 720, agent: true) // 12:00 today
		let morning = try await recurring("Stretch", type: "task", time: 420)               // 07:00 → tomorrow
		_ = try await backend.mutate(action: "create", params: .object(["name": .string("Plain"), "type_key": .string("note")]))

		let upcoming = try await backend.upcomingOccurrences(after: now, limit: 64)
		XCTAssertEqual(upcoming.map(\.objectId), [noon, evening, morning])
		XCTAssertEqual(upcoming.map(\.agentOwned), [true, false, false])
		XCTAssertEqual(upcoming[0].name, "Weekly review")
		XCTAssertEqual(upcoming[0].at, 1_789_326_000_000) // 2026-09-13T19:00:00Z
		let capped = try await backend.upcomingOccurrences(after: now, limit: 2)
		XCTAssertEqual(capped.count, 2)

		// Completing moves an object later in the list; deleting removes it.
		_ = try await backend.mutate(action: "occurrence_complete", params: .object(["object_id": .string(noon)].merging(clock) { a, _ in a }))
		_ = try await backend.mutate(action: "delete", params: .object(["object_id": .string(evening)]))
		let after = try await backend.upcomingOccurrences(after: now, limit: 64)
		XCTAssertEqual(after.map(\.objectId), [morning, noon])
	}
}
