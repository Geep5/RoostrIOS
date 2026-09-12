import Foundation

/// Schema-free JSON for engine payloads whose shape the host does not model
/// (operations, snapshots, field values). Preserves numbers as Double or Int
/// exactly as decoded so round-trips through the engine stay byte-stable.
public enum JSONValue: Codable, Equatable, Sendable {
	case null
	case bool(Bool)
	case int(Int64)
	case double(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() { self = .null }
		else if let value = try? container.decode(Bool.self) { self = .bool(value) }
		else if let value = try? container.decode(Int64.self) { self = .int(value) }
		else if let value = try? container.decode(Double.self) { self = .double(value) }
		else if let value = try? container.decode(String.self) { self = .string(value) }
		else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
		else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
		else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value") }
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .null: try container.encodeNil()
		case .bool(let value): try container.encode(value)
		case .int(let value): try container.encode(value)
		case .double(let value): try container.encode(value)
		case .string(let value): try container.encode(value)
		case .array(let value): try container.encode(value)
		case .object(let value): try container.encode(value)
		}
	}

	public subscript(key: String) -> JSONValue? {
		if case .object(let fields) = self { return fields[key] }
		return nil
	}

	public var string: String? {
		if case .string(let value) = self { return value }
		return nil
	}
}
