import Foundation

public enum RelayError: Error, Equatable {
	/// No EOSE / OK within the caller's deadline.
	case timeout
	/// The relay ended the subscription (`CLOSED`) before EOSE.
	case closed(String)
	/// `OK false` for a published event.
	case rejected(String)
	/// No pong within the keepalive deadline: the socket is presumed half-open.
	case unresponsive
	/// `NEG-ERR` for a reconciliation, with the relay's reason.
	case negentropy(String)
	/// The relay answered `NEG-OPEN` with a `NOTICE`: it does not speak NIP-77.
	case unsupported(String)
}

/// NIP-01 and NIP-77 client over `URLSessionWebSocketTask`. Connects on first use; a
/// failed socket is dropped so the next call dials again. Transport errors
/// propagate as thrown by URLSession so callers can tell them from relay
/// answers. An open socket is pinged every `keepalive`; a missing pong after
/// `pongTimeout` fails it, since a socket that outlived a suspension or a
/// network change can otherwise wait on `receive()` forever.
public final class WebSocketRelay: RelayClient, @unchecked Sendable {
	public let url: URL
	private let core: Core

	public init(url: URL, session: URLSession = .shared, keepalive: Duration = .seconds(25), pongTimeout: Duration = .seconds(10)) {
		self.url = url
		self.core = Core(url: url, session: session, keepalive: keepalive, pongTimeout: pongTimeout)
	}

	public func query(_ filters: [NostrFilter], timeout: Duration) async throws -> [NostrEvent] {
		try await core.query(filters, timeout: timeout)
	}

	public func subscribe(_ filters: [NostrFilter]) -> AsyncThrowingStream<NostrEvent, Error> {
		let (stream, continuation) = AsyncThrowingStream<NostrEvent, Error>.makeStream()
		let id = Core.subscriptionId()
		let core = core
		continuation.onTermination = { _ in Task { await core.close(subscription: id) } }
		Task { await core.open(subscription: id, filters: filters, continuation: continuation) }
		return stream
	}

	public func publish(_ event: NostrEvent, timeout: Duration) async throws {
		try await core.publish(event, timeout: timeout)
	}

	public func reconcile(_ filter: NostrFilter, local: NegentropyStorage, timeout: Duration) async throws -> [String] {
		try await core.reconcile(filter, local: local, timeout: timeout)
	}

	public func disconnect() async {
		await core.disconnect()
	}
}

/// Outcome slot for one REQ or EVENT awaiting the relay's answer. The answer
/// may land between the send and the continuation attach (the actor is
/// reentrant across `await`), so it is parked in `outcome` until then.
private struct Waiter<Value> {
	var continuation: CheckedContinuation<Value, Error>?
	var outcome: Result<Value, Error>?
}

private struct Query {
	var events: [NostrEvent] = []
	var waiter = Waiter<[NostrEvent]>()
}

/// One NIP-77 session awaiting the relay's next NEG-MSG (hex).
private struct NegSession {
	var waiter = Waiter<String>()
	/// NEG-OPEN is still unanswered: a NOTICE now means the verb is unknown.
	var opening: Bool
}

private actor Core {
	let url: URL
	private let session: URLSession
	private let keepalive: Duration
	private let pongTimeout: Duration
	private let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .withoutEscapingSlashes
		return encoder
	}()
	private let decoder = JSONDecoder()

	private var socket: URLSessionWebSocketTask?
	private var pinger: Task<Void, Never>?
	/// The ping still waiting for its pong; cleared when it arrives.
	private var awaitingPong: UUID?
	private var queries: [String: Query] = [:]
	private var lives: [String: AsyncThrowingStream<NostrEvent, Error>.Continuation] = [:]
	private var publishes: [String: Waiter<Void>] = [:]
	private var negs: [String: NegSession] = [:]
	/// Streams the consumer dropped before their REQ went out.
	private var abandoned: Set<String> = []

	init(url: URL, session: URLSession, keepalive: Duration, pongTimeout: Duration) {
		self.url = url
		self.session = session
		self.keepalive = keepalive
		self.pongTimeout = pongTimeout
	}

	static func subscriptionId() -> String {
		var rng = SystemRandomNumberGenerator()
		return Hex.encode(Data((0..<8).map { _ in UInt8.random(in: .min ... .max, using: &rng) }))
	}

	/// Max bytes of one outgoing negentropy message: 500k hex chars, well under
	/// the relay's 1 MiB message cap.
	static let negFrameSizeLimit = 250_000

	// MARK: Requests

	func query(_ filters: [NostrFilter], timeout: Duration) async throws -> [NostrEvent] {
		let id = Self.subscriptionId()
		queries[id] = Query()
		do { try await send(.req(id, filters)) } catch { queries[id] = nil; throw error }
		let timer = deadline(timeout) { await self.settleQuery(id, .failure(RelayError.timeout), close: true) }
		defer { timer.cancel() }
		return try await withCheckedThrowingContinuation { continuation in
			if let outcome = queries[id]?.waiter.outcome {
				queries[id] = nil
				continuation.resume(with: outcome)
			} else {
				queries[id]?.waiter.continuation = continuation
			}
		}
	}

	func open(subscription id: String, filters: [NostrFilter], continuation: AsyncThrowingStream<NostrEvent, Error>.Continuation) async {
		if abandoned.remove(id) != nil { return }
		lives[id] = continuation
		do { try await send(.req(id, filters)) } catch {
			lives[id] = nil
			continuation.finish(throwing: error)
		}
	}

	func close(subscription id: String) async {
		guard lives.removeValue(forKey: id) != nil else { abandoned.insert(id); return }
		if socket != nil { try? await send(.close(id)) }
	}

	func publish(_ event: NostrEvent, timeout: Duration) async throws {
		let id = event.id
		publishes[id] = Waiter()
		do { try await send(.event(event)) } catch { publishes[id] = nil; throw error }
		let timer = deadline(timeout) { await self.settlePublish(id, .failure(RelayError.timeout)) }
		defer { timer.cancel() }
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			if let outcome = publishes[id]?.outcome {
				publishes[id] = nil
				continuation.resume(with: outcome)
			} else {
				publishes[id]?.continuation = continuation
			}
		}
	}

	/// Runs the initiator side to completion; collects the relay's ids we lack.
	/// The session is closed on every exit the relay has not closed itself.
	func reconcile(_ filter: NostrFilter, local: NegentropyStorage, timeout: Duration) async throws -> [String] {
		var negentropy = try Negentropy(storage: local, frameSizeLimit: Self.negFrameSizeLimit)
		let id = Self.subscriptionId()
		var message = try negentropy.initiate()
		var need: [String] = []
		var opened = false
		do {
			while true {
				negs[id] = NegSession(opening: !opened)
				let hex = Hex.encode(Data(message))
				try await send(opened ? .negMsg(id, hex) : .negOpen(id, filter, hex))
				opened = true
				let reply = try await negAnswer(id, timeout: timeout)
				guard let bytes = Hex.decode(reply) else { throw RelayError.negentropy("malformed NEG-MSG") }
				let step = try negentropy.reconcile([UInt8](bytes))
				need += step.needIds
				guard let next = step.output else { break }
				message = next
			}
		} catch {
			negs[id] = nil
			// NEG-ERR ends the session relay-side; a dead socket has none left.
			let closedByRelay: Bool
			if case RelayError.negentropy = error { closedByRelay = true } else { closedByRelay = false }
			if opened, !closedByRelay, socket != nil { try? await send(.negClose(id)) }
			throw error
		}
		negs[id] = nil
		if socket != nil { try? await send(.negClose(id)) }
		return need
	}

	private func negAnswer(_ id: String, timeout: Duration) async throws -> String {
		let timer = deadline(timeout) { await self.settleNeg(id, .failure(RelayError.timeout)) }
		defer { timer.cancel() }
		return try await withCheckedThrowingContinuation { continuation in
			if let outcome = negs[id]?.waiter.outcome {
				negs[id] = nil
				continuation.resume(with: outcome)
			} else if negs[id] != nil {
				negs[id]?.waiter.continuation = continuation
			} else {
				continuation.resume(throwing: RelayError.timeout)
			}
		}
	}

	// MARK: Settling

	private func settleQuery(_ id: String, _ outcome: Result<[NostrEvent], Error>, close: Bool) {
		guard var query = queries[id] else { return }
		if let continuation = query.waiter.continuation {
			queries[id] = nil
			continuation.resume(with: outcome)
		} else {
			query.waiter.outcome = outcome
			queries[id] = query
		}
		if close, socket != nil { Task { try? await self.send(.close(id)) } }
	}

	private func settlePublish(_ id: String, _ outcome: Result<Void, Error>) {
		guard var waiter = publishes[id] else { return }
		if let continuation = waiter.continuation {
			publishes[id] = nil
			continuation.resume(with: outcome)
		} else {
			waiter.outcome = outcome
			publishes[id] = waiter
		}
	}

	private func settleNeg(_ id: String, _ outcome: Result<String, Error>) {
		guard var session = negs[id], session.waiter.outcome == nil else { return }
		if let continuation = session.waiter.continuation {
			negs[id] = nil
			continuation.resume(with: outcome)
		} else {
			session.waiter.outcome = outcome
			negs[id] = session
		}
	}

	private func deadline(_ timeout: Duration, _ expire: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
		Task {
			do { try await Task.sleep(for: timeout) } catch { return }
			await expire()
		}
	}

	// MARK: Transport

	private func connect() -> URLSessionWebSocketTask {
		if let socket { return socket }
		let task = session.webSocketTask(with: url)
		socket = task
		task.resume()
		Task { await self.receive(on: task) }
		pinger = Task { await self.ping(on: task) }
		return task
	}

	private func send(_ frame: ClientFrame) async throws {
		let task = connect()
		let text = String(decoding: try encoder.encode(frame), as: UTF8.self)
		do { try await task.send(.string(text)) } catch {
			fail(error, on: task)
			throw error
		}
	}

	private func receive(on task: URLSessionWebSocketTask) async {
		while socket === task {
			let message: URLSessionWebSocketTask.Message
			do { message = try await task.receive() } catch {
				fail(error, on: task)
				return
			}
			let data: Data
			switch message {
			case .string(let text): data = Data(text.utf8)
			case .data(let bytes): data = bytes
			@unknown default: continue
			}
			guard let frame = try? decoder.decode(ServerFrame.self, from: data) else { continue }
			handle(frame)
		}
	}

	/// While `task` is current: a ping every `keepalive`, and a socket whose pong
	/// misses `pongTimeout` (or whose ping errors) is failed so callers redial.
	private func ping(on task: URLSessionWebSocketTask) async {
		while socket === task {
			do { try await Task.sleep(for: keepalive) } catch { return }
			guard socket === task else { return }
			let probe = UUID()
			awaitingPong = probe
			task.sendPing { [weak self] error in
				Task { await self?.ponged(probe, on: task, error) }
			}
			do { try await Task.sleep(for: pongTimeout) } catch { return }
			if awaitingPong == probe {
				fail(RelayError.unresponsive, on: task)
				return
			}
		}
	}

	private func ponged(_ probe: UUID, on task: URLSessionWebSocketTask, _ error: Error?) {
		if let error { fail(error, on: task); return }
		if awaitingPong == probe { awaitingPong = nil }
	}

	private func handle(_ frame: ServerFrame) {
		switch frame {
		case .event(let id, let event):
			if queries[id] != nil { queries[id]!.events.append(event) }
			else { lives[id]?.yield(event) }
		case .eose(let id):
			if let query = queries[id] { settleQuery(id, .success(query.events), close: true) }
		case .closed(let id, let message):
			settleQuery(id, .failure(RelayError.closed(message)), close: false)
			settleNeg(id, .failure(RelayError.closed(message)))
			lives.removeValue(forKey: id)?.finish(throwing: RelayError.closed(message))
		case .ok(let id, let accepted, let message):
			settlePublish(id, accepted ? .success(()) : .failure(RelayError.rejected(message)))
		case .negMsg(let id, let hex):
			settleNeg(id, .success(hex))
		case .negErr(let id, let reason):
			settleNeg(id, .failure(RelayError.negentropy(reason)))
		case .notice(let message):
			// NOTICE names no subscription; it only answers an unanswered NEG-OPEN.
			for (id, session) in negs where session.opening { settleNeg(id, .failure(RelayError.unsupported(message))) }
		case .other:
			break
		}
	}

	func disconnect() {
		guard let socket else { return }
		fail(URLError(.networkConnectionLost), on: socket)
	}

	/// Drops the socket if it is still current and fails everything waiting on it.
	private func fail(_ error: Error, on task: URLSessionWebSocketTask) {
		guard socket === task else { return }
		socket = nil
		pinger?.cancel()
		pinger = nil
		awaitingPong = nil
		task.cancel(with: .abnormalClosure, reason: nil)
		let queries = self.queries, lives = self.lives, publishes = self.publishes
		self.queries = [:]; self.lives = [:]; self.publishes = [:]
		for (id, _) in queries { settleFailed(&self.queries, id, queries[id]!, error) }
		for (_, continuation) in lives { continuation.finish(throwing: error) }
		for (id, _) in publishes { settleFailed(&self.publishes, id, publishes[id]!, error) }
		for id in Array(negs.keys) { settleNeg(id, .failure(error)) }
	}

	private func settleFailed(_ store: inout [String: Query], _ id: String, _ query: Query, _ error: Error) {
		if let continuation = query.waiter.continuation { continuation.resume(throwing: error) }
		else { var parked = query; parked.waiter.outcome = .failure(error); store[id] = parked }
	}

	private func settleFailed(_ store: inout [String: Waiter<Void>], _ id: String, _ waiter: Waiter<Void>, _ error: Error) {
		if let continuation = waiter.continuation { continuation.resume(throwing: error) }
		else { var parked = waiter; parked.outcome = .failure(error); store[id] = parked }
	}
}

// MARK: Frames

private enum ClientFrame: Encodable {
	case req(String, [NostrFilter])
	case close(String)
	case event(NostrEvent)
	case negOpen(String, NostrFilter, String)
	case negMsg(String, String)
	case negClose(String)

	func encode(to encoder: Encoder) throws {
		var container = encoder.unkeyedContainer()
		switch self {
		case .req(let id, let filters):
			try container.encode("REQ")
			try container.encode(id)
			for filter in filters { try container.encode(filter) }
		case .close(let id):
			try container.encode("CLOSE")
			try container.encode(id)
		case .event(let event):
			try container.encode("EVENT")
			try container.encode(event)
		case .negOpen(let id, let filter, let message):
			try container.encode("NEG-OPEN")
			try container.encode(id)
			try container.encode(filter)
			try container.encode(message)
		case .negMsg(let id, let message):
			try container.encode("NEG-MSG")
			try container.encode(id)
			try container.encode(message)
		case .negClose(let id):
			try container.encode("NEG-CLOSE")
			try container.encode(id)
		}
	}
}

private enum ServerFrame: Decodable {
	case event(String, NostrEvent)
	case eose(String)
	case closed(String, String)
	case ok(String, Bool, String)
	case notice(String)
	case negMsg(String, String)
	case negErr(String, String)
	case other

	init(from decoder: Decoder) throws {
		var container = try decoder.unkeyedContainer()
		switch try container.decode(String.self) {
		case "EVENT": self = .event(try container.decode(String.self), try container.decode(NostrEvent.self))
		case "EOSE": self = .eose(try container.decode(String.self))
		case "CLOSED": self = .closed(try container.decode(String.self), container.isAtEnd ? "" : try container.decode(String.self))
		case "OK":
			let id = try container.decode(String.self)
			let accepted = try container.decode(Bool.self)
			self = .ok(id, accepted, container.isAtEnd ? "" : try container.decode(String.self))
		case "NOTICE": self = .notice(container.isAtEnd ? "" : try container.decode(String.self))
		case "NEG-MSG": self = .negMsg(try container.decode(String.self), try container.decode(String.self))
		case "NEG-ERR": self = .negErr(try container.decode(String.self), container.isAtEnd ? "" : try container.decode(String.self))
		default: self = .other
		}
	}
}
