import CryptoKit
import Foundation

// Negentropy range-based set reconciliation, protocol V1 (0x61), byte for byte
// as the reference implementation (https://github.com/hoytech/negentropy,
// js/Negentropy.js). NIP-77 carries its messages hex-encoded.

public enum NegentropyError: Error, Equatable {
	case malformed(String)
	case unsupportedVersion(UInt8)
	case duplicateItem
	case badId
	case frameSizeLimitTooSmall
	case alreadyInitiated
}

/// 32-byte id as four big-endian limbs: limb order compares like the bytes.
struct NegentropyId: Hashable, Comparable {
	var w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64

	static let zero = NegentropyId(w0: 0, w1: 0, w2: 0, w3: 0)

	init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
		self.w0 = w0; self.w1 = w1; self.w2 = w2; self.w3 = w3
	}

	/// Big-endian load of `count` (≤ 32) bytes, zero padded.
	init<C: Collection>(bytes: C) where C.Element == UInt8 {
		var limbs: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
		var i = 0
		for byte in bytes {
			let shift = UInt64(56 - 8 * (i % 8))
			switch i / 8 {
			case 0: limbs.0 |= UInt64(byte) << shift
			case 1: limbs.1 |= UInt64(byte) << shift
			case 2: limbs.2 |= UInt64(byte) << shift
			default: limbs.3 |= UInt64(byte) << shift
			}
			i += 1
		}
		self.init(w0: limbs.0, w1: limbs.1, w2: limbs.2, w3: limbs.3)
	}

	/// Lowercase or uppercase 64-char hex; nil otherwise.
	init?(hex: String) {
		var limbs: [UInt64] = [0, 0, 0, 0]
		var count = 0
		for c in hex.utf8 {
			let nibble: UInt8
			switch c {
			case 0x30...0x39: nibble = c - 0x30
			case 0x61...0x66: nibble = c - 0x61 + 10
			case 0x41...0x46: nibble = c - 0x41 + 10
			default: return nil
			}
			guard count < 64 else { return nil }
			limbs[count / 16] = limbs[count / 16] << 4 | UInt64(nibble)
			count += 1
		}
		guard count == 64 else { return nil }
		self.init(w0: limbs[0], w1: limbs[1], w2: limbs[2], w3: limbs[3])
	}

	subscript(limb: Int) -> UInt64 {
		switch limb {
		case 0: return w0
		case 1: return w1
		case 2: return w2
		default: return w3
		}
	}

	func byte(_ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: self[i / 8] >> UInt64(56 - 8 * (i % 8))) }

	/// The first `count` bytes kept, the rest zeroed.
	func prefix(_ count: Int) -> NegentropyId {
		func mask(_ limb: Int) -> UInt64 {
			let bytes = min(8, max(0, count - 8 * limb))
			return bytes == 0 ? 0 : bytes == 8 ? .max : ~(UInt64.max >> UInt64(8 * bytes))
		}
		return NegentropyId(w0: w0 & mask(0), w1: w1 & mask(1), w2: w2 & mask(2), w3: w3 & mask(3))
	}

	static func < (a: NegentropyId, b: NegentropyId) -> Bool {
		(a.w0, a.w1, a.w2, a.w3) < (b.w0, b.w1, b.w2, b.w3)
	}

	func write(_ count: Int, to out: inout [UInt8]) {
		for i in 0..<count { out.append(byte(i)) }
	}

	var hex: String {
		var bytes: [UInt8] = []
		bytes.reserveCapacity(32)
		write(32, to: &bytes)
		return Hex.encode(Data(bytes))
	}
}

struct NegentropyItem: Comparable {
	var timestamp: UInt64
	var id: NegentropyId

	static func < (a: NegentropyItem, b: NegentropyItem) -> Bool {
		a.timestamp != b.timestamp ? a.timestamp < b.timestamp : a.id < b.id
	}
}

/// Range bound: a timestamp (`.max` = infinity) and an id prefix of `length` bytes.
private struct Bound {
	var timestamp: UInt64
	var length: Int
	/// Prefix bytes, zero padded.
	var id: NegentropyId

	static func time(_ timestamp: UInt64) -> Bound { Bound(timestamp: timestamp, length: 0, id: .zero) }

	/// Item order against a bound: equal prefixes put the (longer) item above.
	func isAbove(_ item: NegentropyItem) -> Bool {
		if item.timestamp != timestamp { return item.timestamp < timestamp }
		return item.id.prefix(length) < id
	}
}

/// Sealed, sorted set of (created_at, id) items: one side of a reconciliation.
public struct NegentropyStorage: Sendable {
	let items: [NegentropyItem]

	/// Throws on a malformed id or a duplicate (timestamp, id).
	public init(_ entries: [(createdAt: Int64, id: String)]) throws {
		var items: [NegentropyItem] = []
		items.reserveCapacity(entries.count)
		for entry in entries {
			guard entry.createdAt >= 0, let id = NegentropyId(hex: entry.id) else { throw NegentropyError.badId }
			items.append(NegentropyItem(timestamp: UInt64(entry.createdAt), id: id))
		}
		items.sort()
		for i in items.indices.dropFirst() where items[i - 1] == items[i] { throw NegentropyError.duplicateItem }
		self.items = items
	}

	public var count: Int { items.count }

	/// First index in `begin..<end` not below `bound`.
	fileprivate func lowerBound(_ begin: Int, _ end: Int, _ bound: Bound) -> Int {
		var first = begin, count = end - begin
		while count > 0 {
			let step = count / 2
			if bound.isAbove(items[first + step]) {
				first += step + 1
				count -= step + 1
			} else {
				count = step
			}
		}
		return first
	}

	/// First 16 bytes of sha256(sum of ids as little-endian 256-bit ints mod 2^256 || varint(count)).
	func fingerprint(_ begin: Int, _ end: Int) -> [UInt8] {
		var sum: [UInt64] = [0, 0, 0, 0]
		for i in begin..<end {
			let id = items[i].id
			var carry: UInt64 = 0
			for limb in 0..<4 {
				// Little-endian limb k is big-endian limb k byte-swapped.
				let (partial, o1) = sum[limb].addingReportingOverflow(id[limb].byteSwapped)
				let (total, o2) = partial.addingReportingOverflow(carry)
				sum[limb] = total
				carry = o1 || o2 ? 1 : 0
			}
		}
		var input: [UInt8] = []
		input.reserveCapacity(42)
		for limb in sum {
			for shift in stride(from: 0, to: 64, by: 8) { input.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift))) }
		}
		Negentropy.appendVarInt(UInt64(end - begin), to: &input)
		return Array(SHA256.hash(data: input).prefix(Negentropy.fingerprintSize))
	}
}

/// One side of a reconciliation. The initiator calls `initiate()` then feeds
/// every answer to `reconcile(_:)` until it returns no output; `haveIds` /
/// `needIds` accumulate only on the initiator.
public struct Negentropy {
	static let protocolVersion: UInt8 = 0x61
	static let idSize = 32
	static let fingerprintSize = 16

	private enum Mode: UInt64 {
		case skip = 0, fingerprint = 1, idList = 2
	}

	private let storage: NegentropyStorage
	/// Max output bytes (0 = unlimited); the reference keeps 200 bytes of slack.
	private let frameSizeLimit: Int
	private var isInitiator = false
	private var lastTimestampIn: UInt64 = 0
	private var lastTimestampOut: UInt64 = 0

	public init(storage: NegentropyStorage, frameSizeLimit: Int = 0) throws {
		if frameSizeLimit != 0 && frameSizeLimit < 4096 { throw NegentropyError.frameSizeLimitTooSmall }
		self.storage = storage
		self.frameSizeLimit = frameSizeLimit
	}

	/// The opening message: the version byte plus the whole set split once.
	public mutating func initiate() throws -> [UInt8] {
		if isInitiator { throw NegentropyError.alreadyInitiated }
		isInitiator = true
		var output: [UInt8] = [Self.protocolVersion]
		splitRange(0, storage.count, .time(.max), &output)
		return output
	}

	/// Processes one peer message. The initiator gets nil output once the
	/// reconciliation is complete; ids are lowercase hex.
	public mutating func reconcile(_ query: [UInt8]) throws -> (output: [UInt8]?, haveIds: [String], needIds: [String]) {
		var haveIds: [String] = [], needIds: [String] = []
		var reader = Reader(bytes: query)
		lastTimestampIn = 0
		lastTimestampOut = 0

		var fullOutput: [UInt8] = [Self.protocolVersion]
		let version = try reader.byte()
		if version < 0x60 || version > 0x6F { throw NegentropyError.malformed("invalid protocol version byte") }
		if version != Self.protocolVersion {
			if isInitiator { throw NegentropyError.unsupportedVersion(version) }
			return (fullOutput, [], [])
		}

		let storageSize = storage.count
		var prevBound = Bound.time(0)
		var prevIndex = 0
		var skip = false

		while !reader.isAtEnd {
			var o: [UInt8] = []
			func doSkip() {
				if skip {
					skip = false
					encodeBound(prevBound, &o)
					Self.appendVarInt(Mode.skip.rawValue, to: &o)
				}
			}

			let currBound = try decodeBound(&reader)
			guard let mode = Mode(rawValue: try reader.varInt()) else { throw NegentropyError.malformed("unexpected mode") }

			let lower = prevIndex
			var upper = storage.lowerBound(prevIndex, storageSize, currBound)

			switch mode {
			case .skip:
				skip = true
			case .fingerprint:
				let theirs = try reader.bytes(Self.fingerprintSize)
				if !theirs.elementsEqual(storage.fingerprint(lower, upper)) {
					doSkip()
					splitRange(lower, upper, currBound, &o)
				} else {
					skip = true
				}
			case .idList:
				let numIds = try reader.varInt()
				guard numIds <= UInt64(reader.remaining / Self.idSize) else { throw NegentropyError.malformed("parse ends prematurely") }
				var theirs: [NegentropyId] = []
				for _ in 0..<numIds {
					let id = NegentropyId(bytes: try reader.bytes(Self.idSize))
					if isInitiator { theirs.append(id) }
				}
				if isInitiator {
					skip = true
					var unseen = Set(theirs)
					for i in lower..<upper {
						let id = storage.items[i].id
						if unseen.remove(id) == nil { haveIds.append(id.hex) }
					}
					// Their ids we lack, in their order.
					for id in theirs where unseen.remove(id) != nil { needIds.append(id.hex) }
				} else {
					doSkip()
					var responseIds: [UInt8] = []
					var numResponseIds: UInt64 = 0
					var endBound = currBound
					for i in lower..<upper {
						if exceededFrameSizeLimit(fullOutput.count + responseIds.count) {
							let item = storage.items[i]
							endBound = Bound(timestamp: item.timestamp, length: Self.idSize, id: item.id)
							upper = i
							break
						}
						storage.items[i].id.write(Self.idSize, to: &responseIds)
						numResponseIds += 1
					}
					encodeBound(endBound, &o)
					Self.appendVarInt(Mode.idList.rawValue, to: &o)
					Self.appendVarInt(numResponseIds, to: &o)
					o.append(contentsOf: responseIds)
					fullOutput.append(contentsOf: o)
					o = []
				}
			}

			if exceededFrameSizeLimit(fullOutput.count + o.count) {
				// Stop here; one fingerprint covers the remaining range.
				let remaining = storage.fingerprint(upper, storageSize)
				encodeBound(.time(.max), &fullOutput)
				Self.appendVarInt(Mode.fingerprint.rawValue, to: &fullOutput)
				fullOutput.append(contentsOf: remaining)
				break
			} else {
				fullOutput.append(contentsOf: o)
			}

			prevIndex = upper
			prevBound = currBound
		}

		return (fullOutput.count == 1 && isInitiator ? nil : fullOutput, haveIds, needIds)
	}

	private mutating func splitRange(_ lower: Int, _ upper: Int, _ upperBound: Bound, _ o: inout [UInt8]) {
		let numElems = upper - lower
		let buckets = 16
		if numElems < buckets * 2 {
			encodeBound(upperBound, &o)
			Self.appendVarInt(Mode.idList.rawValue, to: &o)
			Self.appendVarInt(UInt64(numElems), to: &o)
			for i in lower..<upper { storage.items[i].id.write(Self.idSize, to: &o) }
			return
		}
		let itemsPerBucket = numElems / buckets
		let bucketsWithExtra = numElems % buckets
		var curr = lower
		for i in 0..<buckets {
			let bucketSize = itemsPerBucket + (i < bucketsWithExtra ? 1 : 0)
			let fingerprint = storage.fingerprint(curr, curr + bucketSize)
			curr += bucketSize
			let nextBound = curr == upper ? upperBound : Self.minimalBound(storage.items[curr - 1], storage.items[curr])
			encodeBound(nextBound, &o)
			Self.appendVarInt(Mode.fingerprint.rawValue, to: &o)
			o.append(contentsOf: fingerprint)
		}
	}

	private func exceededFrameSizeLimit(_ n: Int) -> Bool {
		frameSizeLimit != 0 && n > frameSizeLimit - 200
	}

	private static func minimalBound(_ prev: NegentropyItem, _ curr: NegentropyItem) -> Bound {
		if curr.timestamp != prev.timestamp { return .time(curr.timestamp) }
		var shared = 0
		while shared < idSize, curr.id.byte(shared) == prev.id.byte(shared) { shared += 1 }
		let length = min(shared + 1, idSize)
		return Bound(timestamp: curr.timestamp, length: length, id: curr.id.prefix(length))
	}

	// MARK: Encoding

	static func appendVarInt(_ n: UInt64, to out: inout [UInt8]) {
		if n == 0 { out.append(0); return }
		var digits: [UInt8] = []
		var n = n
		while n != 0 {
			digits.append(UInt8(n & 127))
			n >>= 7
		}
		for i in stride(from: digits.count - 1, through: 0, by: -1) { out.append(i == 0 ? digits[i] : digits[i] | 128) }
	}

	private mutating func encodeBound(_ bound: Bound, _ out: inout [UInt8]) {
		if bound.timestamp == .max {
			lastTimestampOut = .max
			Self.appendVarInt(0, to: &out)
		} else {
			let delta = bound.timestamp - lastTimestampOut
			lastTimestampOut = bound.timestamp
			Self.appendVarInt(delta + 1, to: &out)
		}
		Self.appendVarInt(UInt64(bound.length), to: &out)
		bound.id.write(bound.length, to: &out)
	}

	private mutating func decodeBound(_ reader: inout Reader) throws -> Bound {
		let encoded = try reader.varInt()
		let timestamp: UInt64
		if encoded == 0 || lastTimestampIn == .max {
			timestamp = .max
		} else {
			let (sum, overflow) = (encoded - 1).addingReportingOverflow(lastTimestampIn)
			if overflow { throw NegentropyError.malformed("timestamp overflow") }
			timestamp = sum
		}
		lastTimestampIn = timestamp
		let length = try reader.varInt()
		if length > UInt64(Self.idSize) { throw NegentropyError.malformed("bound key too long") }
		let prefix = try reader.bytes(Int(length))
		return Bound(timestamp: timestamp, length: Int(length), id: NegentropyId(bytes: prefix))
	}
}

private struct Reader {
	let bytes: [UInt8]
	var offset = 0

	var isAtEnd: Bool { offset == bytes.count }
	var remaining: Int { bytes.count - offset }

	mutating func byte() throws -> UInt8 {
		guard offset < bytes.count else { throw NegentropyError.malformed("parse ends prematurely") }
		defer { offset += 1 }
		return bytes[offset]
	}

	mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
		guard remaining >= n else { throw NegentropyError.malformed("parse ends prematurely") }
		defer { offset += n }
		return bytes[offset..<offset + n]
	}

	mutating func varInt() throws -> UInt64 {
		var result: UInt64 = 0
		while true {
			let byte = try byte()
			guard result >> 57 == 0 else { throw NegentropyError.malformed("varint overflow") }
			result = result << 7 | UInt64(byte & 127)
			if byte & 128 == 0 { return result }
		}
	}
}
