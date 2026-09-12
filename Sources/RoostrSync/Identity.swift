import Foundation
import Security

/// Where the device keeps its one Nostr secret.
public protocol IdentityStore: Sendable {
	func load() throws -> NostrKey?
	func save(_ key: NostrKey) throws
	func clear() throws
}

public enum IdentityError: Error, Equatable {
	case keychain(OSStatus)
	/// Stored bytes are not a valid secret; `clear()` and regenerate.
	case corrupt
}

/// Generic-password item, this-device-only, never synced to iCloud.
public final class KeychainIdentityStore: IdentityStore {
	private let service: String
	private let account: String

	public init(service: String = "app.roostr.identity", account: String = "nostr-secret") {
		self.service = service
		self.account = account
	}

	private var base: [CFString: Any] {
		[kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecAttrSynchronizable: false]
	}

	public func load() throws -> NostrKey? {
		var query = base
		query[kSecReturnData] = true
		query[kSecMatchLimit] = kSecMatchLimitOne
		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw IdentityError.keychain(status) }
		guard let data = item as? Data, let key = try? NostrKey(secret: data) else { throw IdentityError.corrupt }
		return key
	}

	public func save(_ key: NostrKey) throws {
		var attributes = base
		attributes[kSecValueData] = key.secret
		attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		var status = SecItemAdd(attributes as CFDictionary, nil)
		if status == errSecDuplicateItem {
			status = SecItemUpdate(base as CFDictionary, [kSecValueData: key.secret, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
		}
		guard status == errSecSuccess else { throw IdentityError.keychain(status) }
	}

	public func clear() throws {
		let status = SecItemDelete(base as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else { throw IdentityError.keychain(status) }
	}
}

/// Process-local store for tests and the macOS runner.
public final class InMemoryIdentityStore: IdentityStore, @unchecked Sendable {
	private let lock = NSLock()
	private var key: NostrKey?

	public init(_ key: NostrKey? = nil) {
		self.key = key
	}

	public func load() throws -> NostrKey? {
		lock.withLock { key }
	}

	public func save(_ key: NostrKey) throws {
		lock.withLock { self.key = key }
	}

	public func clear() throws {
		lock.withLock { key = nil }
	}
}
