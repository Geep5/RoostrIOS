import Foundation
import Network
import Observation
import GlonCore
import RoostrSync

/// Observable state behind the SwiftUI shell: identity and the backend's
/// lifecycle. All engine and I/O work lives in `Backend`; the web editor
/// reaches it through `WebBridge`, for which this class is the host.
@MainActor @Observable
public final class AppModel: WebBridgeHost {
	public private(set) var key: NostrKey?
	public private(set) var npub = ""
	public private(set) var backend: Backend?
	public private(set) var loaded = false
	public var lastError: String?
	/// In-app path the editor should open next (set by a notification tap); the editor clears it.
	public var pendingRoute: String?
	/// Last reminder schedule summary; shown only with `ROOSTR_DEBUG_REMINDERS`.
	public private(set) var remindersDebug = ""
	public let showRemindersDebug = ProcessInfo.processInfo.environment["ROOSTR_DEBUG_REMINDERS"] == "1"

	private let identity: IdentityStore
	private let keyring: SpaceKeyring
	private let databasePath: String
	private var store: SQLiteChangeStore?
	/// The backend's `start()`, running behind the open editor.
	private var starting: Task<Void, Never>?
	private let reminders = Reminders()
	private let pathMonitor = NWPathMonitor()
	/// Interfaces of the last satisfied network path; nil while offline or before the first update.
	private var pathInterfaces: [String]?
	private var pathSeen = false

	public init(identity: IdentityStore, keyring: SpaceKeyring, databasePath: String) {
		self.identity = identity
		self.keyring = keyring
		self.databasePath = databasePath
		reminders.onOpen = { [weak self] objectId in self?.pendingRoute = "/app/object/\(objectId)" }
		reminders.onScheduled = { [weak self] summary in self?.remindersDebug = summary }
		pathMonitor.pathUpdateHandler = { [weak self] path in
			let interfaces = path.status == .satisfied ? path.availableInterfaces.map(\.name) : nil
			Task { @MainActor in self?.networkChanged(interfaces) }
		}
		pathMonitor.start(queue: .global(qos: .utility))
	}

	/// Production configuration: Keychain identity, relays from
	/// `RelaySettings` (`wss://roostr-relay.fly.dev`, override with
	/// `ROOSTR_RELAYS=wss://a,wss://b`), database in Application
	/// Support/Roostr (override with `ROOSTR_DB=/path/to.sqlite`).
	/// `ROOSTR_IDENTITY=memory` keeps the key in process memory instead of the
	/// Keychain, for the unsigned `swift run roostr-mac` developer runner;
	/// `ROOSTR_SECRET=<hex>` prefills it so the runner opens on the vault.
	public static func standard() -> AppModel {
		let env = ProcessInfo.processInfo.environment
		let database = env["ROOSTR_DB"] ?? {
			let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			return support.appendingPathComponent("Roostr", isDirectory: true).appendingPathComponent("roostr.sqlite").path
		}()
		let prefilled = env["ROOSTR_SECRET"].flatMap(Hex.decode).flatMap { try? NostrKey(secret: $0) }
		let memory = env["ROOSTR_IDENTITY"] == "memory"
		let identity: IdentityStore = memory ? InMemoryIdentityStore(prefilled) : KeychainIdentityStore()
		// The unsigned developer runner keeps space keys out of the login Keychain too.
		let keyring: SpaceKeyring = memory ? InMemorySpaceKeyring() : KeychainSpaceKeyring()
		return AppModel(identity: identity, keyring: keyring, databasePath: database)
	}

	/// Loads the stored identity and, when present, opens the vault: `loaded`
	/// turns true as soon as the backend exists, while sync starts behind it.
	public func start() async {
		defer { loaded = true }
		do {
			guard let stored = try identity.load() else { return }
			try await login(stored)
		} catch {
			lastError = "\(error)"
		}
	}

	/// Reconnects every relay now and catches up (`Backend.resume`): the app
	/// returned from the background, where iOS may have killed its sockets
	/// without telling them.
	public func resume() async {
		await backend?.resume()
	}

	/// Back online or onto another interface (Wi-Fi ⇄ cellular): sockets bound
	/// to the old path are dead, so reconnect instead of waiting for keepalive.
	private func networkChanged(_ interfaces: [String]?) {
		defer { pathInterfaces = interfaces; pathSeen = true }
		guard pathSeen, let interfaces, interfaces != pathInterfaces else { return }
		Task { await resume() }
	}

	public func generateKey() async throws {
		try await adopt(NostrKey.generate())
	}

	/// Accepts an `nsec1…` string or 64 hex chars of secret key. An existing
	/// identity is logged out first: its replica must never leak into the new one.
	public func importKey(_ text: String) async throws {
		let newKey = try await Self.parseSecret(text)
		if key != nil { try await logout(exportPending: false) }
		try await adopt(newKey)
	}

	/// Stops sync, forgets the key and drops the replica and its space keys:
	/// a different key must never see this database (same rule as the
	/// website's logout). Refuses while unpublished changes remain unless
	/// `exportPending`, which writes them to Documents/Roostr-pending-<unix ms>.json first.
	public func logout(exportPending: Bool) async throws {
		if let backend {
			try await backend.logout(exportTo: exportPending ? Self.pendingExportURL() : nil)
		}
		await teardown()
		try identity.clear()
		for spaceId in ((try? keyring.all()) ?? [:]).keys { try? keyring.remove(spaceId) }
		try? FileManager.default.removeItem(atPath: databasePath)
		key = nil
		npub = ""
	}

	/// Persists the relay list and reopens the vault against it.
	public func setRelays(_ relays: [String]) async throws {
		RelaySettings.save(relays)
		if let key { try await login(key) }
	}

	// MARK: - Lifecycle

	static func parseSecret(_ text: String) async throws -> NostrKey {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let hex: String
		if trimmed.lowercased().hasPrefix("nsec1") {
			let decoded = try await Bech32.decode(trimmed)
			guard decoded.hrp == "nsec" else { throw ModelError.invalidKey("expected an nsec, got \(decoded.hrp)") }
			hex = decoded.hex
		} else {
			hex = trimmed
		}
		guard let secret = Hex.decode(hex), secret.count == 32 else {
			throw ModelError.invalidKey("secret must be an nsec or 64 hex characters")
		}
		return try NostrKey(secret: secret)
	}

	private static func pendingExportURL() -> URL {
		let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		return documents.appendingPathComponent("Roostr-pending-\(Int64(Date().timeIntervalSince1970 * 1000)).json")
	}

	private func adopt(_ newKey: NostrKey) async throws {
		try identity.save(newKey)
		try await login(newKey)
	}

	/// Opens the replica under `newKey` and starts sync without waiting for
	/// it: every backend read serves the local replica at once, and the web
	/// UI's sync status covers the catch-up.
	private func login(_ newKey: NostrKey) async throws {
		await teardown()
		key = newKey
		npub = (try? await Bech32.npub(newKey.pubkey)) ?? newKey.pubkey
		let directory = (databasePath as NSString).deletingLastPathComponent
		try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
		let store = try SQLiteChangeStore(path: databasePath)
		let relays: [RelayClient] = RelaySettings.load().compactMap(URL.init(string:)).map { WebSocketRelay(url: $0) }
		let backend = Backend(key: newKey, relays: relays, store: store, keyring: keyring)
		self.store = store
		self.backend = backend
		reminders.follow(backend)
		starting = Task { await backend.start() }
	}

	private func teardown() async {
		reminders.stop()
		starting?.cancel()
		starting = nil
		if let backend { await backend.stop() }
		if let store { await store.close() }
		backend = nil
		store = nil
	}
}

public enum ModelError: Error, CustomStringConvertible {
	case invalidKey(String)

	public var description: String {
		switch self {
		case .invalidKey(let why): return why
		}
	}
}
