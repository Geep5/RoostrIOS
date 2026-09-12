import Foundation
import Observation
import GlonCore
import RoostrSync

/// Observable state behind the SwiftUI shell: identity, backend lifecycle,
/// sync status and the object list. All engine and I/O work lives in
/// `Backend`; this class only reflects it on the main actor.
@MainActor @Observable
public final class AppModel {
	public private(set) var key: NostrKey?
	public private(set) var npub = ""
	public private(set) var status = SyncStatus(phase: .idle)
	public private(set) var objects: [ObjectSummary] = []
	public private(set) var loaded = false
	public var lastError: String?

	private let identity: IdentityStore
	private let relayURLs: [URL]
	private let databasePath: String
	private var backend: Backend?
	private var store: SQLiteChangeStore?
	private var listeners: [Task<Void, Never>] = []

	public init(identity: IdentityStore, relayURLs: [URL], databasePath: String) {
		self.identity = identity
		self.relayURLs = relayURLs
		self.databasePath = databasePath
	}

	/// Production configuration: Keychain identity, `wss://roostr-relay.fly.dev`
	/// (override with `ROOSTR_RELAYS=wss://a,wss://b`), database in
	/// Application Support/Roostr (override with `ROOSTR_DB=/path/to.sqlite`).
	/// `ROOSTR_IDENTITY=memory` keeps the key in process memory instead of the
	/// Keychain, for the unsigned `swift run roostr-mac` developer runner;
	/// `ROOSTR_SECRET=<hex>` prefills it so the runner opens on the vault.
	public static func standard() -> AppModel {
		let env = ProcessInfo.processInfo.environment
		let relays = (env["ROOSTR_RELAYS"] ?? "wss://roostr-relay.fly.dev")
			.split(separator: ",")
			.compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
		let database = env["ROOSTR_DB"] ?? {
			let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			return support.appendingPathComponent("Roostr", isDirectory: true).appendingPathComponent("roostr.sqlite").path
		}()
		let prefilled = env["ROOSTR_SECRET"].flatMap(Hex.decode).flatMap { try? NostrKey(secret: $0) }
		let identity: IdentityStore = env["ROOSTR_IDENTITY"] == "memory" ? InMemoryIdentityStore(prefilled) : KeychainIdentityStore()
		return AppModel(identity: identity, relayURLs: relays, databasePath: database)
	}

	/// Loads the stored identity and, when present, brings the backend up.
	public func start() async {
		defer { loaded = true }
		do {
			guard let stored = try identity.load() else { return }
			try await login(stored)
		} catch {
			lastError = "\(error)"
		}
	}

	public func generateKey() async {
		await adopt(NostrKey.generate())
	}

	/// Accepts an `nsec1…` string or 64 hex chars of secret key.
	public func importKey(_ text: String) async {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		do {
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
			await adopt(try NostrKey(secret: secret))
		} catch {
			lastError = "\(error)"
		}
	}

	/// Stops sync, forgets the key and drops the replica: a different key
	/// must never see this database (same rule as the website's logout).
	public func logout() async {
		await teardown()
		do { try identity.clear() } catch { lastError = "\(error)" }
		try? FileManager.default.removeItem(atPath: databasePath)
		key = nil
		npub = ""
		objects = []
		status = SyncStatus(phase: .idle)
	}

	public func createNote(name: String, text: String) async throws -> String {
		guard let backend else { throw ModelError.notStarted }
		let id = try await backend.createNote(name: name, text: text)
		await refresh()
		return id
	}

	public func object(id: String) async throws -> JSONValue {
		guard let backend else { throw ModelError.notStarted }
		return try await backend.object(id: id)
	}

	public func refresh() async {
		guard let backend else { return }
		do { objects = try await backend.objects() } catch { lastError = "\(error)" }
	}

	// MARK: - Lifecycle

	private func adopt(_ newKey: NostrKey) async {
		do {
			try identity.save(newKey)
			try await login(newKey)
		} catch {
			lastError = "\(error)"
		}
	}

	private func login(_ newKey: NostrKey) async throws {
		await teardown()
		key = newKey
		npub = (try? await Bech32.npub(newKey.pubkey)) ?? newKey.pubkey
		let directory = (databasePath as NSString).deletingLastPathComponent
		try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
		let store = try SQLiteChangeStore(path: databasePath)
		let relays: [RelayClient] = relayURLs.map { WebSocketRelay(url: $0) }
		let backend = Backend(key: newKey, relays: relays, store: store)
		self.store = store
		self.backend = backend
		let statuses = await backend.statusUpdates()
		let commits = await backend.commitUpdates()
		listeners = [
			Task { [weak self] in
				for await update in statuses { self?.status = update }
			},
			Task { [weak self] in
				for await _ in commits { await self?.refresh() }
			},
		]
		await backend.start()
		await refresh()
	}

	private func teardown() async {
		for task in listeners { task.cancel() }
		listeners = []
		if let backend { await backend.stop() }
		if let store { await store.close() }
		backend = nil
		store = nil
	}
}

public enum ModelError: Error, CustomStringConvertible {
	case notStarted
	case invalidKey(String)

	public var description: String {
		switch self {
		case .notStarted: return "no identity loaded"
		case .invalidKey(let why): return why
		}
	}
}
