import Foundation
import Security

// Space keys: the device counterpart of the website's `roostr-space-keys`
// localStorage file (spacekeys.ts) and the desktop's channel-keys.json:
//   { version: 1, channels: { [spaceId]: { key, keyId, createdAt, owner? } } }
// `key` is 32 bytes hex and doubles as the NIP-44 conversation key of the
// space; `owner` (hex pubkey) is set on IMPORTED entries and names who
// administers the space. Owned spaces carry no owner: the local identity is.

public struct SpaceKey: Codable, Sendable, Equatable {
	public var key: String
	public var keyId: Int64
	public var createdAt: Int64
	public var owner: String?

	public init(key: String, keyId: Int64, createdAt: Int64, owner: String? = nil) {
		self.key = key; self.keyId = keyId; self.createdAt = createdAt; self.owner = owner
	}

	/// 64 lowercase hex characters: a space key or an x-only pubkey.
	public static func isHex32(_ text: String) -> Bool {
		text.utf8.count == 64 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
	}

	static func random() -> String {
		var rng = SystemRandomNumberGenerator()
		return Hex.encode(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }))
	}
}

public protocol SpaceKeyring: Sendable {
	func all() throws -> [String: SpaceKey]
	func get(_ spaceId: String) throws -> SpaceKey?
	func set(_ spaceId: String, _ key: SpaceKey) throws
	func remove(_ spaceId: String) throws
}

public extension SpaceKeyring {
	/// Key for a locally created space (keyId 1). Idempotent.
	@discardableResult
	func ensure(_ spaceId: String) throws -> SpaceKey {
		if let existing = try get(spaceId) { return existing }
		let entry = SpaceKey(key: SpaceKey.random(), keyId: 1, createdAt: Self.nowMs())
		try set(spaceId, entry)
		return entry
	}

	/// Rotate on member removal: new key, keyId + 1; an imported owner is kept.
	@discardableResult
	func rotate(_ spaceId: String) throws -> SpaceKey {
		let previous = try get(spaceId)
		let entry = SpaceKey(key: SpaceKey.random(), keyId: (previous?.keyId ?? 0) + 1, createdAt: Self.nowMs(), owner: previous?.owner)
		try set(spaceId, entry)
		return entry
	}

	/// Import an invited key; a newer local keyId wins (spacekeys.ts spaceKeyImport).
	@discardableResult
	func `import`(_ spaceId: String, key: String, keyId: Int64, owner: String) throws -> SpaceKey {
		if let previous = try get(spaceId), previous.keyId >= keyId { return previous }
		let entry = SpaceKey(key: key, keyId: keyId, createdAt: Self.nowMs(), owner: owner)
		try set(spaceId, entry)
		return entry
	}

	private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// The whole key file as one this-device-only generic-password item, so
/// keys survive reinstalls no better and no worse than the identity.
public final class KeychainSpaceKeyring: SpaceKeyring, @unchecked Sendable {
	private struct KeyFile: Codable {
		var version: Int
		var channels: [String: SpaceKey]
	}

	private let service: String
	private let account: String
	private let lock = NSLock()
	private let encoder = JSONEncoder()
	private let decoder = JSONDecoder()

	public init(service: String = "app.roostr.space-keys", account: String = "channel-keys") {
		self.service = service
		self.account = account
	}

	private var base: [CFString: Any] {
		[kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecAttrSynchronizable: false]
	}

	public func all() throws -> [String: SpaceKey] {
		try lock.withLock { try read().channels }
	}

	public func get(_ spaceId: String) throws -> SpaceKey? {
		try lock.withLock { try read().channels[spaceId] }
	}

	public func set(_ spaceId: String, _ key: SpaceKey) throws {
		try lock.withLock {
			var file = try read()
			file.channels[spaceId] = key
			try write(file)
		}
	}

	public func remove(_ spaceId: String) throws {
		try lock.withLock {
			var file = try read()
			guard file.channels.removeValue(forKey: spaceId) != nil else { return }
			try write(file)
		}
	}

	private func read() throws -> KeyFile {
		var query = base
		query[kSecReturnData] = true
		query[kSecMatchLimit] = kSecMatchLimitOne
		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)
		if status == errSecItemNotFound { return KeyFile(version: 1, channels: [:]) }
		guard status == errSecSuccess else { throw IdentityError.keychain(status) }
		guard let data = item as? Data, let file = try? decoder.decode(KeyFile.self, from: data), file.version == 1 else { throw IdentityError.corrupt }
		return file
	}

	private func write(_ file: KeyFile) throws {
		let data = try encoder.encode(file)
		var attributes = base
		attributes[kSecValueData] = data
		attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		var status = SecItemAdd(attributes as CFDictionary, nil)
		if status == errSecDuplicateItem {
			status = SecItemUpdate(base as CFDictionary, [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
		}
		guard status == errSecSuccess else { throw IdentityError.keychain(status) }
	}
}

/// Process-local keyring for tests and the macOS runner.
public final class InMemorySpaceKeyring: SpaceKeyring, @unchecked Sendable {
	private let lock = NSLock()
	private var channels: [String: SpaceKey]

	public init(_ channels: [String: SpaceKey] = [:]) {
		self.channels = channels
	}

	public func all() throws -> [String: SpaceKey] { lock.withLock { channels } }
	public func get(_ spaceId: String) throws -> SpaceKey? { lock.withLock { channels[spaceId] } }
	public func set(_ spaceId: String, _ key: SpaceKey) throws { lock.withLock { channels[spaceId] = key } }
	public func remove(_ spaceId: String) throws { lock.withLock { channels[spaceId] = nil } }
}
