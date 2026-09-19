import Foundation
import Glon

public enum GlonError: Error, Equatable {
	/// The linked engine speaks a different ABI than this wrapper.
	case abiMismatch(UInt32)
	/// Encoded request exceeds the engine's fixed 16 MiB request buffer.
	case requestTooLarge(Int)
	/// The engine rejected the request (invalid JSON, unknown method, domain error).
	case engine(String)
	/// The engine returned bytes that are not a `{result}` / `{error}` envelope.
	case malformedResponse
}

/// Serialises every call into the single-flight Odin engine. One instance per
/// process; the engine's query cache is process-global state behind this actor.
public actor GlonCore {
	public static let abiVersion: UInt32 = 2
	public static let requestLimit = 16 * 1024 * 1024
	public static let shared = GlonCore()

	private static let linkedABI: UInt32 = {
		core_init()
		return core_abi_version()
	}()

	private let encoder = JSONEncoder()
	private let decoder = JSONDecoder()

	private init() {}

	/// Executes `{method, payload}` and decodes the envelope's `result`.
	public func call<Payload: Encodable, Result: Decodable>(_ method: String, _ payload: Payload) throws -> Result {
		guard Self.linkedABI == Self.abiVersion else { throw GlonError.abiMismatch(Self.linkedABI) }
		let request = try encoder.encode(Envelope(method: method, payload: payload))
		guard request.count <= Self.requestLimit, let buffer = core_reserve(UInt32(request.count)) else {
			throw GlonError.requestTooLarge(request.count)
		}
		defer { core_reset(0) }
		request.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
		guard core_execute() == 0, let pointer = core_response_pointer() else { throw GlonError.malformedResponse }
		let response = Data(bytes: pointer, count: Int(core_response_length()))
		let envelope: Response<Result>
		do { envelope = try decoder.decode(Response<Result>.self, from: response) } catch { throw GlonError.malformedResponse }
		if let error = envelope.error { throw GlonError.engine(error) }
		guard let result = envelope.result else { throw GlonError.malformedResponse }
		return result
	}

	/// Drops the engine's persistent query cache; the next query must send `reset`.
	public func resetAll() {
		core_reset(1)
	}
}

private struct Envelope<Payload: Encodable>: Encodable {
	let method: String
	let payload: Payload
}

private struct Response<Result: Decodable>: Decodable {
	let result: Result?
	let error: String?
}
