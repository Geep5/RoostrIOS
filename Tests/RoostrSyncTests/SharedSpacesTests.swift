import Foundation
import GlonCore
import XCTest
@testable import RoostrSync

/// Shared spaces end to end through an in-memory relay: keys, gift-wrapped
/// invites and join requests, the authority gate on import, key rotation.
/// The engine session is process-global, so owner and member run in turns:
/// each phase starts one backend on its own persistent store and stops it.
final class SharedSpacesTests: XCTestCase {
	private struct Nip59Fixture: Decodable {
		struct RumorSpec: Decodable {
			let kind: Int
			let tags: [[String]]
			let content: String
		}

		let recipientSecret: String
		let senderPubkey: String
		let rumor: RumorSpec
		let wrap: NostrEvent
	}

	private static let nip59: Nip59Fixture = {
		let url = Bundle.module.url(forResource: "nip59_fixture", withExtension: "json", subdirectory: "Fixtures")!
		return try! JSONDecoder().decode(Nip59Fixture.self, from: Data(contentsOf: url))
	}()

	/// One identity with the durable state a device keeps between launches.
	private final class Party {
		let key = NostrKey.generate()
		let keyring = InMemorySpaceKeyring()
		let store: SQLiteChangeStore
		let relay: FakeRelay

		init(relay: FakeRelay) throws {
			self.relay = relay
			self.store = try SQLiteChangeStore.inMemory()
		}

		func backend() -> Backend {
			Backend(key: key, relays: [relay], store: store, keyring: keyring)
		}
	}

	private struct Timeout: Error, CustomStringConvertible {
		let waitingFor: String
		var description: String { "timed out waiting for \(waitingFor)" }
	}

	private func eventually<T>(_ waitingFor: String, timeout: Duration = .seconds(10), _ probe: () async throws -> T?) async throws -> T {
		let deadline = ContinuousClock.now + timeout
		while ContinuousClock.now < deadline {
			if let value = try await probe() { return value }
			try await Task.sleep(for: .milliseconds(25))
		}
		throw Timeout(waitingFor: waitingFor)
	}

	/// Relay filters are `since cursor + 1` at second granularity: a writer's
	/// event must be newer than the reader's last import to reach a restarted
	/// reader, so phases that hand over between parties wait for a new second.
	private func nextSecond() async throws {
		let now = Date().timeIntervalSince1970
		try await Task.sleep(for: .milliseconds(Int((now.rounded(.up) - now) * 1000) + 50))
	}

	// ── NIP-59 wire parity ──

	func testUnwrapsGiftWrapProducedByNostrTools() async throws {
		let fixture = Self.nip59
		let recipient = try NostrKey(secret: Hex.decode(fixture.recipientSecret)!)
		XCTAssertEqual(fixture.wrap.kind, GiftWrap.wrapKind)
		XCTAssertEqual(fixture.wrap.tag("p"), recipient.pubkey)
		let rumor = try await GiftWrap.unwrap(fixture.wrap, recipient: recipient)
		XCTAssertEqual(rumor.kind, fixture.rumor.kind)
		XCTAssertEqual(rumor.tags, fixture.rumor.tags)
		XCTAssertEqual(rumor.content, fixture.rumor.content)
		XCTAssertEqual(rumor.pubkey, fixture.senderPubkey)
		XCTAssertEqual(rumor.id, NostrEvent.computeId(pubkey: rumor.pubkey, createdAt: rumor.created_at, kind: rumor.kind, tags: rumor.tags, content: rumor.content))

		let stranger = NostrKey.generate()
		do {
			_ = try await GiftWrap.unwrap(fixture.wrap, recipient: stranger)
			XCTFail("a wrap must not open for another key")
		} catch {}
	}

	func testWrapRoundTripMatchesNip59Shape() async throws {
		let sender = NostrKey.generate()
		let recipient = NostrKey.generate()
		let content = "{\"t\":\"join-request\",\"space\":\"s/1\"}"
		let before = Int64(Date().timeIntervalSince1970)
		let wrap = try await GiftWrap.wrap(kind: joinRequestRumorKind, content: content, sender: sender, recipient: recipient.pubkey)
		XCTAssertEqual(wrap.kind, 1059)
		XCTAssertEqual(wrap.tags, [["p", recipient.pubkey]])
		XCTAssertNotEqual(wrap.pubkey, sender.pubkey, "the wrap is signed by a one-off key")
		XCTAssertTrue(NostrKey.verify(wrap))
		XCTAssertTrue(wrap.created_at <= before + 1 && wrap.created_at >= before - 2 * 86_400, "created_at randomized within two days back")

		let rumor = try await GiftWrap.unwrap(wrap, recipient: recipient)
		XCTAssertEqual(rumor.pubkey, sender.pubkey)
		XCTAssertEqual(rumor.kind, joinRequestRumorKind)
		XCTAssertEqual(rumor.content, content)

		// Interop hook: ROOSTR_WRAP_OUT=<path> dumps a wrap for nostr-tools to open.
		if let path = ProcessInfo.processInfo.environment["ROOSTR_WRAP_OUT"] {
			let out: JSONValue = .object(["recipientSecret": .string(recipient.secretHex), "senderPubkey": .string(sender.pubkey), "content": .string(content), "wrap": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(wrap))])
			try JSONEncoder().encode(out).write(to: URL(fileURLWithPath: path))
		}
	}

	// ── Keyring ──

	func testKeyringImportKeepsNewerKeyAndRotationKeepsOwner() throws {
		let keyring = InMemorySpaceKeyring()
		let first = try keyring.ensure("s")
		XCTAssertEqual(first.keyId, 1)
		XCTAssertNil(first.owner)
		XCTAssertEqual(try keyring.ensure("s"), first, "ensure is idempotent")
		let rotated = try keyring.rotate("s")
		XCTAssertEqual(rotated.keyId, 2)
		XCTAssertNotEqual(rotated.key, first.key)

		let owner = String(repeating: "ab", count: 32)
		XCTAssertEqual(try keyring.import("s", key: String(repeating: "cd", count: 32), keyId: 1, owner: owner), rotated, "an older keyId never replaces a newer local key")
		let imported = try keyring.import("s", key: String(repeating: "cd", count: 32), keyId: 3, owner: owner)
		XCTAssertEqual(imported.keyId, 3)
		XCTAssertEqual(imported.owner, owner)
		XCTAssertEqual(try keyring.rotate("s").owner, owner)
	}

	// ── Owner ⇄ member lifecycle ──

	func testInviteJoinShareAuthorityAndRotation() async throws {
		let relay = FakeRelay()
		let owner = try Party(relay: relay)
		let member = try Party(relay: relay)
		let viewer = try Party(relay: relay)
		let ownerNpub = try await Bech32.npub(owner.key.pubkey)
		let memberNpub = try await Bech32.npub(member.key.pubkey)
		let viewerNpub = try await Bech32.npub(viewer.key.pubkey)

		// (a) The owner creates a space: its key lands in the owner's keyring.
		var ob = owner.backend()
		await ob.start()
		let created = try await ob.mutate(action: "channel_create", params: .object(["name": .string("Team")]))
		let spaceId = try XCTUnwrap(created["id"]?.string)
		await ob.awaitIdle()
		await ob.stop()
		let ownerKey = try XCTUnwrap(try owner.keyring.get(spaceId))
		XCTAssertEqual(ownerKey.keyId, 1)
		XCTAssertNil(ownerKey.owner)

		// The member knocks; the wrap waits on the relay for the owner.
		var mb = member.backend()
		await mb.start()
		try await mb.sendJoinRequest(space: spaceId, owner: ownerNpub, relays: [])
		await mb.stop()
		XCTAssertEqual(relay.stored.filter { $0.kind == 1059 && $0.tag("p") == owner.key.pubkey }.count, 1)

		// The owner sees the knock, adds the member as a writer and a viewer
		// too: both receive the key, gift-wrapped.
		ob = owner.backend()
		await ob.start()
		let request = try await eventually("the owner's join request") { await ob.joinRequests().first }
		XCTAssertEqual(request.space, spaceId)
		XCTAssertEqual(request.spaceName, "Team")
		XCTAssertEqual(request.requester, member.key.pubkey)
		XCTAssertEqual(request.requesterNpub, memberNpub)
		XCTAssertEqual(request.key, "\(spaceId)/\(member.key.pubkey)")
		await ob.clearJoinRequest(key: request.key)
		let cleared = await ob.joinRequests()
		XCTAssertTrue(cleared.isEmpty)
		_ = try await ob.mutate(action: "channel_member_add", params: .object(["channel_id": .string(spaceId), "npub": .string(memberNpub), "role": .string("writer")]))
		_ = try await ob.mutate(action: "channel_member_add", params: .object(["channel_id": .string(spaceId), "npub": .string(viewerNpub), "role": .string("viewer")]))
		_ = try await eventually("the member's invite wrap") { relay.stored.contains { $0.kind == 1059 && $0.tag("p") == member.key.pubkey } ? true : nil }
		_ = try await eventually("the viewer's invite wrap") { relay.stored.contains { $0.kind == 1059 && $0.tag("p") == viewer.key.pubkey } ? true : nil }
		await ob.awaitIdle()
		let invitesSent = try await eventually("the invites-sent record") { try await owner.store.meta("invites-sent") }
		XCTAssertTrue(invitesSent.contains("\"\(spaceId)/\(member.key.pubkey)\":1"), invitesSent)
		let sharedEvents = relay.stored.filter { $0.kind == 1078 && $0.pubkey == owner.key.pubkey }
		XCTAssertGreaterThan(sharedEvents.count, 0)
		await ob.stop()
		let wrapsBefore = relay.stored.filter { $0.kind == 1059 }.count
		try await nextSecond()

		// The member opens the invite: the key is installed under the owner and
		// the space backfills from its stream tag.
		mb = member.backend()
		await mb.start()
		let memberKey = try await eventually("the member's space key") { try member.keyring.get(spaceId) }
		XCTAssertEqual(memberKey.key, ownerKey.key)
		XCTAssertEqual(memberKey.keyId, 1)
		XCTAssertEqual(memberKey.owner, owner.key.pubkey)
		let space = try await eventually("the member's view of the space") { try await mb.channels().first { $0["id"]?.string == spaceId } }
		XCTAssertEqual(space["name"]?.string, "Team")
		XCTAssertEqual(space["keyId"]?.int, 1)
		let members = space["members"]?.array ?? []
		XCTAssertTrue(members.contains(.object(["npub": .string(memberNpub), "role": .string("writer")])), "\(members)")
		XCTAssertTrue(members.contains(.object(["npub": .string(viewerNpub), "role": .string("viewer")])), "\(members)")

		// (b) The member writes into the space.
		let noteResult = try await mb.mutate(action: "create", params: .object(["name": .string("Shared note"), "fields": .object(["channel": .object(["stringValue": .string(spaceId)])])]))
		let noteId = try XCTUnwrap(noteResult["id"]?.string)
		await mb.awaitIdle()
		_ = try await eventually("the member's shared note on the relay") { relay.stored.contains { $0.kind == 1078 && $0.pubkey == member.key.pubkey } ? true : nil }
		await mb.stop()

		// (c) The viewer holds the key too but may not write.
		let vb = viewer.backend()
		await vb.start()
		_ = try await eventually("the viewer's space key") { try viewer.keyring.get(spaceId) }
		_ = try await eventually("the viewer's view of the space") { try await vb.channels().first { $0["id"]?.string == spaceId } }
		let viewerNote = try await vb.mutate(action: "create", params: .object(["name": .string("Sneaky"), "fields": .object(["channel": .object(["stringValue": .string(spaceId)])])]))
		let viewerNoteId = try XCTUnwrap(viewerNote["id"]?.string)
		await vb.awaitIdle()
		_ = try await eventually("the viewer's note on the relay") { relay.stored.contains { $0.kind == 1078 && $0.pubkey == viewer.key.pubkey } ? true : nil }
		await vb.stop()
		try await nextSecond()

		// The owner imports the writer's note and drops the viewer's.
		ob = owner.backend()
		await ob.start()
		let imported = try await eventually("the owner's import of the member note") { try await ob.objects().first { $0.id == noteId } }
		XCTAssertEqual(imported.name, "Shared note")
		let note = try await ob.object(id: noteId)
		XCTAssertEqual(note["fields"]?["channel"]?["stringValue"]?.string, spaceId)
		await ob.awaitIdle()
		let ownerObjects = try await ob.objects()
		XCTAssertFalse(ownerObjects.contains { $0.id == viewerNoteId }, "a viewer's change fails the authority gate")

		// (d) Rotation: keyId 2, a fresh key, re-wrapped to every member.
		let rotated = try await ob.mutate(action: "channel_key_rotate", params: .object(["channel_id": .string(spaceId)]))
		XCTAssertEqual(rotated["key_id"]?.int, 2)
		let rotatedKey = try XCTUnwrap(try owner.keyring.get(spaceId))
		XCTAssertEqual(rotatedKey.keyId, 2)
		XCTAssertNotEqual(rotatedKey.key, ownerKey.key)
		_ = try await eventually("the rotated invite wraps") { relay.stored.filter { $0.kind == 1059 }.count >= wrapsBefore + 2 ? true : nil }
		await ob.awaitIdle()
		let rotatedSpace = try await ob.channels().first { $0["id"]?.string == spaceId }
		XCTAssertEqual(rotatedSpace?["keyId"]?.int, 2)
		await ob.stop()

		mb = member.backend()
		await mb.start()
		let memberRotated = try await eventually("the member's rotated key") { try member.keyring.get(spaceId).flatMap { $0.keyId == 2 ? $0 : nil } }
		XCTAssertEqual(memberRotated.key, rotatedKey.key)
		XCTAssertEqual(memberRotated.owner, owner.key.pubkey)
		let memberView = try await eventually("the member's rotated view") { try await mb.channels().first { $0["id"]?.string == spaceId && $0["keyId"]?.int == 2 } }
		XCTAssertEqual(memberView["name"]?.string, "Team")
		await mb.stop()
	}

	func testImportSpaceInviteRejectsForeignAdministrator() async throws {
		let relay = FakeRelay()
		let party = try Party(relay: relay)
		let backend = party.backend()
		let owner = NostrKey.generate()
		let ownerNpub = try await Bech32.npub(owner.pubkey)
		let key = String(repeating: "0a", count: 32)
		let accepted = await backend.importSpaceInvite(space: "space-x", owner: ownerNpub, key: key, keyId: 2)
		XCTAssertTrue(accepted)
		XCTAssertEqual(try party.keyring.get("space-x"), SpaceKey(key: key, keyId: 2, createdAt: try XCTUnwrap(try party.keyring.get("space-x")).createdAt, owner: owner.pubkey))

		let intruder = NostrKey.generate()
		let hijacked = await backend.importSpaceInvite(space: "space-x", owner: intruder.pubkey, key: String(repeating: "0b", count: 32), keyId: 3)
		XCTAssertFalse(hijacked, "another administrator may not replace an installed key")
		XCTAssertEqual(try party.keyring.get("space-x")?.keyId, 2)

		let malformed = await backend.importSpaceInvite(space: "space-y", owner: ownerNpub, key: "not-hex", keyId: 1)
		XCTAssertFalse(malformed)
		let zeroKeyId = await backend.importSpaceInvite(space: "space-y", owner: ownerNpub, key: key, keyId: 0)
		XCTAssertFalse(zeroKeyId)
		await backend.awaitIdle()
	}
}
