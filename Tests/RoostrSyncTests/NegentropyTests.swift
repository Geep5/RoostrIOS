import CryptoKit
import Foundation
import XCTest
@testable import RoostrSync

/// Negentropy V1 against transcripts of the reference implementation
/// (hoytech/negentropy js/Negentropy.js, client ↔ server, same frame limits):
/// every message Swift produces on either side must match byte for byte.
final class NegentropyTests: XCTestCase {
	private struct Scenario: Decodable {
		let name: String
		let seed: UInt32
		let n: Int
		let spread: UInt32
		let onlyClient: UInt32
		let onlyServer: UInt32
		let clientLimit: Int
		let serverLimit: Int
		let clientCount: Int
		let serverCount: Int
		let messages: [String]?
		let messageHashes: [String]
		let haveCount: Int
		let needCount: Int
		let haveHash: String
		let needHash: String
	}

	private static let scenarios: [Scenario] = {
		let url = Bundle.module.url(forResource: "negentropy_vectors", withExtension: "json", subdirectory: "Fixtures")!
		return try! JSONDecoder().decode([Scenario].self, from: Data(contentsOf: url))
	}()

	private static func sha(_ bytes: some DataProtocol) -> String { Hex.encode(Data(SHA256.hash(data: bytes))) }

	/// The generator's sets: id = sha256("seed:i"), LCG timestamps and membership.
	private static func sets(_ s: Scenario) -> (client: [(createdAt: Int64, id: String)], server: [(createdAt: Int64, id: String)]) {
		var x = s.seed
		func next() -> UInt32 { x = x &* 1664525 &+ 1013904223; return x }
		var client: [(createdAt: Int64, id: String)] = [], server: [(createdAt: Int64, id: String)] = []
		for i in 0..<s.n {
			let id = sha(Data("\(s.seed):\(i)".utf8))
			let ts = 1677970534 + Int64(next() % s.spread)
			let r = next() % 1000
			if r < s.onlyClient { client.append((ts, id)) }
			else if r < s.onlyClient + s.onlyServer { server.append((ts, id)) }
			else { client.append((ts, id)); server.append((ts, id)) }
		}
		return (client, server)
	}

	func testTranscriptsMatchReference() throws {
		XCTAssertFalse(Self.scenarios.isEmpty)
		for s in Self.scenarios {
			let (a, b) = Self.sets(s)
			XCTAssertEqual(a.count, s.clientCount, s.name)
			XCTAssertEqual(b.count, s.serverCount, s.name)
			var client = try Negentropy(storage: NegentropyStorage(a), frameSizeLimit: s.clientLimit)
			var server = try Negentropy(storage: NegentropyStorage(b), frameSizeLimit: s.serverLimit)
			var messages: [[UInt8]] = []
			var have: [String] = [], need: [String] = []
			var query = try client.initiate()
			while true {
				messages.append(query)
				let answer = try server.reconcile(query)
				XCTAssertTrue(answer.haveIds.isEmpty && answer.needIds.isEmpty, "\(s.name): the server never collects ids")
				guard let reply = answer.output else { return XCTFail("\(s.name): the server always answers") }
				messages.append(reply)
				let step = try client.reconcile(reply)
				have += step.haveIds
				need += step.needIds
				guard let next = step.output else { break }
				XCTAssertLessThan(messages.count, 1000, s.name)
				query = next
			}
			if let expected = s.messages {
				XCTAssertEqual(messages.map { Hex.encode(Data($0)) }, expected, s.name)
			}
			XCTAssertEqual(messages.map { Self.sha($0) }, s.messageHashes, s.name)
			XCTAssertEqual(have.count, s.haveCount, s.name)
			XCTAssertEqual(need.count, s.needCount, s.name)
			XCTAssertEqual(Self.sha(Data(have.sorted().joined(separator: ",").utf8)), s.haveHash, s.name)
			XCTAssertEqual(Self.sha(Data(need.sorted().joined(separator: ",").utf8)), s.needHash, s.name)
			// The sets differ by exactly have ∪ need.
			XCTAssertEqual(Set(need), Set(b.map(\.id)).subtracting(a.map(\.id)), s.name)
			XCTAssertEqual(Set(have), Set(a.map(\.id)).subtracting(b.map(\.id)), s.name)
		}
	}

	func testVarIntAndBoundEncoding() throws {
		var out: [UInt8] = []
		for n: UInt64 in [0, 1, 127, 128, 16383, 16384, 1677970534] { Negentropy.appendVarInt(n, to: &out) }
		XCTAssertEqual(Hex.encode(Data(out)), "00017f8100ff7f81800086a08f9866")
		// Empty set: version, infinity bound, IdList of zero ids.
		var empty = try Negentropy(storage: NegentropyStorage([]))
		XCTAssertEqual(Hex.encode(Data(try empty.initiate())), "6100000200")
	}

	func testRejectsMalformedInput() throws {
		XCTAssertThrowsError(try NegentropyStorage([(1, "zz")]))
		let id = String(repeating: "ab", count: 32)
		XCTAssertThrowsError(try NegentropyStorage([(1, id), (1, id)])) { XCTAssertEqual($0 as? NegentropyError, .duplicateItem) }
		XCTAssertThrowsError(try Negentropy(storage: NegentropyStorage([]), frameSizeLimit: 100))

		var client = try Negentropy(storage: NegentropyStorage([]))
		_ = try client.initiate()
		XCTAssertThrowsError(try client.reconcile([0x62])) { XCTAssertEqual($0 as? NegentropyError, .unsupportedVersion(0x62)) }
		XCTAssertThrowsError(try client.reconcile([0x10]))
		XCTAssertThrowsError(try client.reconcile([0x61, 0x00, 0x00, 0x02, 0x05])) // five ids promised, none sent
		XCTAssertThrowsError(try client.reconcile([0x61, 0x00, 0x21])) // bound key longer than an id
	}
}
