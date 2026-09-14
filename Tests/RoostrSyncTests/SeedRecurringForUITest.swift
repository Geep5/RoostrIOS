import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// Seeder for `Scripts/uitest-reminders.sh`: one recurring task, due in 30
/// minutes local time, on the relay named by the environment. Skips otherwise.
final class SeedRecurringForUITest: XCTestCase {
	func testSeed() async throws {
		let env = ProcessInfo.processInfo.environment
		guard let secret = env["ROOSTR_SEED_SECRET"], let relay = env["ROOSTR_SEED_RELAY"].flatMap(URL.init) else { throw XCTSkip("no seed config") }
		let backend = Backend(key: try NostrKey(secret: Hex.decode(secret)!), relays: [WebSocketRelay(url: relay)], store: try SQLiteChangeStore.inMemory(), keyring: InMemorySpaceKeyring())
		await backend.start()
		await backend.awaitIdle()
		_ = try await backend.mutate(action: "channel_create", params: .object(["name": .string("Personal")]))
		let created = try await backend.mutate(action: "create", params: .object(["name": .string("Water the plants"), "type_key": .string("task")]))
		let id = try XCTUnwrap(created["id"]?.string)
		let now = Date()
		let minutes = Int64((Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now) + 30) % 1440)
		_ = try await backend.mutate(action: "repeat_set", params: .object([
			"object_id": .string(id),
			"rule": .object(["freq": .string("day"), "interval": .int(1), "time": .int(minutes), "tz": .string(TimeZone.current.identifier)]),
			"now_ms": .int(Int64(now.timeIntervalSince1970 * 1000)),
			"tz_offset_min": .int(Int64(TimeZone.current.secondsFromGMT() / 60)),
		]))
		await backend.awaitIdle()
		await backend.stop()
		print("SEEDED_OBJECT \(id)")
	}
}
