import CryptoKit
import Foundation
import Network
import XCTest
@testable import RoostrSync

/// Runs against the local RoostrRelay (`ws://127.0.0.1:7799`, open writes).
/// Skipped when nothing listens there.
final class RelayTests: XCTestCase {
	private static let url = URL(string: "ws://127.0.0.1:7799")!
	private static let timeout = Duration.seconds(5)

	private var relay: WebSocketRelay!
	private var key: NostrKey!

	override func setUp() async throws {
		relay = WebSocketRelay(url: Self.url)
		key = NostrKey.generate()
		let probe = try key.sign(kind: 1, createdAt: now(), tags: [], content: "probe")
		do { try await relay.publish(probe, timeout: Self.timeout) } catch let error as RelayError {
			throw error
		} catch {
			throw XCTSkip("relay unreachable at \(Self.url): \(error)")
		}
	}

	private func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

	private func publish(_ content: String, createdAt: Int64? = nil) async throws -> NostrEvent {
		let event = try key.sign(kind: 1, createdAt: createdAt ?? now(), tags: [], content: content)
		try await relay.publish(event, timeout: Self.timeout)
		return event
	}

	func testPublishThenQuery() async throws {
		let event = try await publish("hello ✓ \"quotes\" \\ \n\t")
		let found = try await relay.query([NostrFilter(authors: [key.pubkey], kinds: [1])], timeout: Self.timeout)
		XCTAssertTrue(found.contains(event))
		XCTAssertTrue(found.allSatisfy(NostrKey.verify))
	}

	func testQueryLimitReturnsExactlyOne() async throws {
		let first = try await publish("first", createdAt: now() - 10)
		// Strictly newer than the reachability probe, so no same-second tie-break decides the order.
		let second = try await publish("second", createdAt: now() + 2)
		let found = try await relay.query([NostrFilter(authors: [key.pubkey], kinds: [1], limit: 1)], timeout: Self.timeout)
		XCTAssertEqual(found.count, 1)
		XCTAssertEqual(found.first, second, "newest first")
		XCTAssertNotEqual(found.first, first)
	}

	func testQueryByIdAndUnknownIdIsEmpty() async throws {
		let event = try await publish("by id")
		let byId = try await relay.query([NostrFilter(ids: [event.id])], timeout: Self.timeout)
		XCTAssertEqual(byId, [event])
		let unknown = try await relay.query([NostrFilter(ids: [String(repeating: "0", count: 64)])], timeout: Self.timeout)
		XCTAssertEqual(unknown, [])
	}

	func testSubscribeReceivesLaterEvents() async throws {
		let stream = relay.subscribe([NostrFilter(authors: [key.pubkey], kinds: [1], since: now() - 1)])
		let received = Task { () -> NostrEvent? in
			for try await event in stream where event.content == "live" { return event }
			return nil
		}
		try await Task.sleep(for: .milliseconds(200))
		let live = try await publish("live")
		let got = try await withThrowingTaskGroup(of: NostrEvent?.self) { group in
			group.addTask { try await received.value }
			group.addTask { try await Task.sleep(for: Self.timeout); received.cancel(); return nil }
			let first = try await group.next()!
			group.cancelAll()
			return first
		}
		XCTAssertEqual(got, live)
	}

	func testPublishRejectsBadSignature() async throws {
		var event = try key.sign(kind: 1, createdAt: now(), tags: [], content: "forged")
		event.sig = String(repeating: "0", count: 128)
		do {
			try await relay.publish(event, timeout: Self.timeout)
			XCTFail("relay accepted an unsigned event")
		} catch RelayError.rejected {
		}
	}

	func testUnreachableRelayThrowsTransportError() async throws {
		let dead = WebSocketRelay(url: URL(string: "ws://127.0.0.1:1")!)
		for _ in 0..<2 {
			do {
				_ = try await dead.query([NostrFilter(kinds: [1], limit: 1)], timeout: Self.timeout)
				XCTFail("expected connection failure")
			} catch is RelayError {
				XCTFail("expected a transport error, not a relay answer")
			} catch {
			}
		}
	}

	func testSubscriptionFailsOnDisconnectAndNextCallRedials() async throws {
		let stream = relay.subscribe([NostrFilter(authors: [key.pubkey], kinds: [1])])
		let outcome = Task { () -> Bool in
			do {
				for try await _ in stream {}
				return false
			} catch {
				return true
			}
		}
		try await Task.sleep(for: .milliseconds(200))
		await relay.disconnect()
		let failed = await outcome.value
		XCTAssertTrue(failed, "live stream must finish with the transport error")
		// Same instance keeps working: a fresh dial on the next call.
		let event = try await publish("after failure")
		let found = try await relay.query([NostrFilter(ids: [event.id])], timeout: Self.timeout)
		XCTAssertEqual(found, [event])
	}
}

/// Keepalive against a local WebSocket endpoint that accepts the socket, reads
/// every frame and never answers NIP-01: with pongs off it is the half-open
/// peer a suspended or re-routed socket is left talking to.
final class RelayKeepaliveTests: XCTestCase {
	private func liveOutcome(_ relay: WebSocketRelay) -> StreamOutcome {
		StreamOutcome(relay.subscribe([NostrFilter(kinds: [1])]))
	}

	func testMissingPongFailsTheSocket() async throws {
		let server = try MuteWebSocketServer(answersPings: false)
		defer { server.stop() }
		let relay = WebSocketRelay(url: try await server.start(), keepalive: .milliseconds(200), pongTimeout: .milliseconds(300))
		let outcome = liveOutcome(relay)
		let deadline = ContinuousClock.now + .seconds(3)
		while !outcome.finished && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
		XCTAssertTrue(outcome.finished, "a socket without pongs must fail its live streams")
		XCTAssertEqual(outcome.error as? RelayError, .unresponsive)
	}

	func testAnsweredPingsKeepTheSocket() async throws {
		let server = try MuteWebSocketServer(answersPings: true)
		defer { server.stop() }
		let relay = WebSocketRelay(url: try await server.start(), keepalive: .milliseconds(200), pongTimeout: .milliseconds(300))
		let outcome = liveOutcome(relay)
		// Three full ping rounds.
		try await Task.sleep(for: .milliseconds(1_600))
		XCTAssertFalse(outcome.finished, "pongs keep a quiet socket open: \(String(describing: outcome.error))")
		outcome.cancel()
	}
}

/// `WebSocketRelay.reconcile` against scripted local endpoints: the frames on
/// the wire, NEG-ERR / NOTICE / silence, and a socket dropped mid-session.
final class RelayNegentropyTests: XCTestCase {
	private static func id(_ i: Int) -> String { Hex.encode(Data(SHA256.hash(data: Data("neg-\(i)".utf8)))) }

	private static func frame(_ text: String) -> [Any] {
		(try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] ?? []
	}

	private static func json(_ value: [Any]) -> String {
		String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
	}

	/// A NIP-77 relay over `storage` speaking through `MuteWebSocketServer`.
	private final class ScriptedRelay: @unchecked Sendable {
		private let storage: NegentropyStorage
		private let lock = NSLock()
		private var sessions: [String: Negentropy] = [:]
		private var filters: [[String: Any]] = []
		private var verbs: [String] = []

		init(_ storage: NegentropyStorage) { self.storage = storage }

		var seen: [String] { lock.withLock { verbs } }
		var openFilters: [[String: Any]] { lock.withLock { filters } }

		func respond(_ text: String) -> [String] {
			let frame = RelayNegentropyTests.frame(text)
			guard frame.count >= 2, let verb = frame[0] as? String, let sub = frame[1] as? String else { return [] }
			return lock.withLock {
				verbs.append(verb)
				if verb == "NEG-OPEN", let filter = frame[2] as? [String: Any] {
					filters.append(filter)
					sessions[sub] = try? Negentropy(storage: storage)
				}
				guard verb == "NEG-OPEN" || verb == "NEG-MSG" else {
					sessions[sub] = nil
					return []
				}
				guard let message = frame.last as? String, let bytes = Hex.decode(message),
				      let reply = try? sessions[sub]?.reconcile([UInt8](bytes)).output else { return [] }
				return [RelayNegentropyTests.json(["NEG-MSG", sub, Hex.encode(Data(reply))])]
			}
		}
	}

	func testReconcileReturnsWhatTheRelayHoldsBeyondOurs() async throws {
		let relayItems: [(createdAt: Int64, id: String)] = (0..<300).map { (Int64(1_700_000_000 + $0 / 3), Self.id($0)) }
		let ours: [(createdAt: Int64, id: String)] = relayItems.enumerated().filter { $0.offset % 7 != 0 }.map(\.element) + [(1_600_000_000, Self.id(-1))]
		let scripted = ScriptedRelay(try NegentropyStorage(relayItems))
		let server = try MuteWebSocketServer(answersPings: true, respond: scripted.respond)
		defer { server.stop() }
		let relay = WebSocketRelay(url: try await server.start())
		let need = try await relay.reconcile(NostrFilter(kinds: [1078]), local: try NegentropyStorage(ours), timeout: .seconds(5))
		let expected = relayItems.enumerated().filter { $0.offset % 7 == 0 }.map(\.element.id)
		XCTAssertEqual(Set(need), Set(expected))
		try await Task.sleep(for: .milliseconds(100))
		XCTAssertEqual(scripted.openFilters.first?["kinds"] as? [Int], [1078], "the filter rides along")
		XCTAssertEqual(scripted.seen.first, "NEG-OPEN")
		XCTAssertEqual(scripted.seen.last, "NEG-CLOSE", "a finished session is closed")
	}

	func testNegErrAndNoticeAndSilenceFailTheReconcile() async throws {
		let local = try NegentropyStorage([])
		let negErr = try MuteWebSocketServer(answersPings: true) { text in
			[Self.json(["NEG-ERR", Self.frame(text)[1], "blocked: too many records"])]
		}
		defer { negErr.stop() }
		do {
			_ = try await WebSocketRelay(url: try await negErr.start()).reconcile(NostrFilter(kinds: [1]), local: local, timeout: .seconds(5))
			XCTFail("NEG-ERR must fail the reconcile")
		} catch {
			XCTAssertEqual(error as? RelayError, .negentropy("blocked: too many records"))
		}

		let notice = try MuteWebSocketServer(answersPings: true) { _ in [Self.json(["NOTICE", "unknown message type"])] }
		defer { notice.stop() }
		do {
			_ = try await WebSocketRelay(url: try await notice.start()).reconcile(NostrFilter(kinds: [1]), local: local, timeout: .seconds(5))
			XCTFail("a NOTICE answering NEG-OPEN must fail the reconcile")
		} catch {
			XCTAssertEqual(error as? RelayError, .unsupported("unknown message type"))
		}

		let silent = try MuteWebSocketServer(answersPings: true)
		defer { silent.stop() }
		do {
			_ = try await WebSocketRelay(url: try await silent.start()).reconcile(NostrFilter(kinds: [1]), local: local, timeout: .milliseconds(300))
			XCTFail("an unanswered NEG-OPEN must time out")
		} catch {
			XCTAssertEqual(error as? RelayError, .timeout)
		}
	}

	func testDroppedSocketFailsTheReconcileAndTheNextCallRedials() async throws {
		let server = try MuteWebSocketServer(answersPings: true)
		defer { server.stop() }
		let relay = WebSocketRelay(url: try await server.start())
		let pending = Task { try await relay.reconcile(NostrFilter(kinds: [1]), local: try NegentropyStorage([]), timeout: .seconds(30)) }
		try await Task.sleep(for: .milliseconds(300))
		let started = ContinuousClock.now
		server.dropConnections()
		do {
			_ = try await pending.value
			XCTFail("a dropped socket must fail the reconcile")
		} catch {
			XCTAssertNil(error as? RelayError, "a transport error, not a relay answer: \(error)")
		}
		XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "fails at once, not at the timeout")
		// The same instance dials again.
		do {
			_ = try await relay.reconcile(NostrFilter(kinds: [1]), local: try NegentropyStorage([]), timeout: .milliseconds(300))
		} catch {
			XCTAssertEqual(error as? RelayError, .timeout, "the next call reaches the (silent) endpoint again")
		}
	}
}

/// How a live stream ended, if it has.
private final class StreamOutcome: @unchecked Sendable {
	private let lock = NSLock()
	private var ended = false
	private var failure: Error?
	private var task: Task<Void, Never>?

	init(_ stream: AsyncThrowingStream<NostrEvent, Error>) {
		task = Task { [weak self] in
			var error: Error?
			do { for try await _ in stream {} } catch let thrown { error = thrown }
			guard let self else { return }
			self.lock.withLock { self.ended = true; self.failure = error }
		}
	}

	var finished: Bool { lock.withLock { ended } }
	var error: Error? { lock.withLock { failure } }
	func cancel() { task?.cancel() }
}

/// Local WebSocket endpoint that reads every frame; `respond` (on the
/// server's queue) turns each text frame into the text frames sent back.
/// Without it, it never answers NIP-01.
private final class MuteWebSocketServer: @unchecked Sendable {
	private let listener: NWListener
	private let queue = DispatchQueue(label: "mute-websocket")
	private var connections: [NWConnection] = []
	private let respond: ((String) -> [String])?

	init(answersPings: Bool, respond: ((String) -> [String])? = nil) throws {
		self.respond = respond
		let websocket = NWProtocolWebSocket.Options()
		websocket.autoReplyPing = answersPings
		let parameters = NWParameters.tcp
		parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
		listener = try NWListener(using: parameters, on: .any)
		listener.newConnectionHandler = { [weak self] connection in
			guard let self else { return }
			self.connections.append(connection)
			connection.start(queue: self.queue)
			self.drain(connection)
		}
	}

	func start() async throws -> URL {
		let port: UInt16 = await withCheckedContinuation { continuation in
			var resumed = false
			listener.stateUpdateHandler = { [listener] state in
				guard case .ready = state, !resumed, let port = listener.port else { return }
				resumed = true
				continuation.resume(returning: port.rawValue)
			}
			listener.start(queue: queue)
		}
		return URL(string: "ws://127.0.0.1:\(port)")!
	}

	private func drain(_ connection: NWConnection) {
		connection.receiveMessage { [weak self] content, _, _, error in
			guard error == nil, let self else { return }
			if let respond = self.respond, let content, let text = String(data: content, encoding: .utf8) {
				for reply in respond(text) {
					let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
					let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
					connection.send(content: Data(reply.utf8), contentContext: context, isComplete: true, completion: .idempotent)
				}
			}
			self.drain(connection)
		}
	}

	/// Drops every accepted socket, as a relay restart or a dead network would.
	func dropConnections() {
		queue.sync {
			for connection in connections { connection.cancel() }
			connections.removeAll()
		}
	}

	func stop() {
		listener.cancel()
		queue.sync { for connection in connections { connection.cancel() } }
	}
}
