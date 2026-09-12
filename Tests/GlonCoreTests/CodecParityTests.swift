import Foundation
import XCTest
@testable import GlonCore

/// Golden wire fixtures shared with glonOdin/core/codec_test.odin and the
/// website's parity-codec.ts: the engine must decode legacy bytes, re-derive
/// the same content address, and re-encode byte-identically through this bridge.
final class CodecParityTests: XCTestCase {
	private struct Fixture: Decodable {
		let name: String
		let id: String
		let bytesHex: String
	}

	private struct Codec: Encodable {
		let action: String
		var bytes: String? = nil
		var change: JSONValue? = nil
	}

	func testFixturesRoundTrip() async throws {
		let url = try XCTUnwrap(Bundle.module.url(forResource: "codec_fixtures", withExtension: "json", subdirectory: "Fixtures"))
		let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
		XCTAssertFalse(fixtures.isEmpty)
		let core = GlonCore.shared
		for fixture in fixtures {
			let wire = try XCTUnwrap(Data(hex: fixture.bytesHex), fixture.name).base64EncodedString()
			let change: JSONValue = try await core.call("codec", Codec(action: "decode", bytes: wire))
			XCTAssertEqual(change["id"]?.string, fixture.id, "\(fixture.name): decoded id")
			let hash: String = try await core.call("codec", Codec(action: "hash", change: change))
			XCTAssertEqual(hash, fixture.id, "\(fixture.name): content address")
			let encoded: String = try await core.call("codec", Codec(action: "encode", change: change))
			XCTAssertEqual(encoded, wire, "\(fixture.name): re-encoded bytes")
		}
	}

	func testEngineErrorsSurfaceAsThrows() async {
		do {
			let _: JSONValue = try await GlonCore.shared.call("nope", [String: String]())
			XCTFail("unknown method must throw")
		} catch {
			XCTAssertEqual(error as? GlonError, .engine("unknown core method"))
		}
	}
}

private extension Data {
	init?(hex: String) {
		guard hex.count % 2 == 0 else { return nil }
		var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
		var index = hex.startIndex
		while index < hex.endIndex {
			let next = hex.index(index, offsetBy: 2)
			guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
			bytes.append(byte)
			index = next
		}
		self.init(bytes)
	}
}
