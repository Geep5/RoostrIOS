import Foundation
import RoostrSync
import UserNotifications

/// Device reminders for recurring objects. The phone runs no scheduler and no
/// agents; it only knows every object's next occurrence from the replica, so
/// after each commit it mirrors the soonest ones into pending local
/// notifications. Tapping one opens the object in the editor.
///
/// iOS keeps at most 64 pending notifications per app; the soonest 64 are
/// scheduled and the set is rebuilt on every change, so nothing drifts.
@MainActor
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
	nonisolated static let identifierPrefix = "repeat:"
	nonisolated static let objectKey = "objectId"
	nonisolated static let limit = 64

	/// Route requested by a notification tap; the editor consumes and clears it.
	var onOpen: ((String) -> Void)?
	/// After each reschedule: "pending=<n> <objectId>,…" (for tests and the debug overlay).
	var onScheduled: ((String) -> Void)?

	private let center: UNUserNotificationCenter?
	private var refresh: Task<Void, Never>?
	private var authorized = false

	override init() {
		// UNUserNotificationCenter aborts in processes without a bundle identifier (the `swift run` developer runner).
		center = Bundle.main.bundleIdentifier == nil ? nil : .current()
		super.init()
		center?.delegate = self
	}

	/// Asked the first time there is something to remind about, never on a
	/// bare launch. A denial leaves the rest of the app untouched.
	private func ensureAuthorized() async -> Bool {
		guard let center else { return false }
		let settings = await center.notificationSettings()
		switch settings.authorizationStatus {
		case .notDetermined:
			authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
		case .authorized, .provisional, .ephemeral:
			authorized = true
		default:
			authorized = false
		}
		return authorized
	}

	/// Follows the backend: reschedule after start and after every commit.
	func follow(_ backend: Backend) {
		refresh?.cancel()
		refresh = Task { [weak self] in
			await self?.reschedule(backend)
			for await _ in await backend.commitUpdates() {
				if Task.isCancelled { return }
				await self?.reschedule(backend)
			}
		}
	}

	func stop() {
		refresh?.cancel()
		refresh = nil
		center?.removeAllPendingNotificationRequests()
	}

	private func reschedule(_ backend: Backend) async {
		guard let center else { return }
		let now = Int64(Date().timeIntervalSince1970 * 1000)
		let upcoming: [Occurrence]
		do { upcoming = try await backend.upcomingOccurrences(after: now, limit: Self.limit) } catch {
			onScheduled?("error=\(error)")
			return
		}
		if upcoming.isEmpty && !authorized {
			onScheduled?("pending=0 (nothing upcoming)")
			return
		}
		guard await ensureAuthorized() else {
			onScheduled?("pending=0 (not authorized)")
			return
		}
		let wanted = Set(upcoming.map { Self.identifierPrefix + $0.id })
		let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
		let stale = pending.filter { !wanted.contains($0) }
		if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
		let present = Set(pending)
		for occurrence in upcoming where !present.contains(Self.identifierPrefix + occurrence.id) {
			let content = UNMutableNotificationContent()
			content.title = occurrence.name.isEmpty ? "Untitled" : occurrence.name
			content.body = occurrence.agentOwned ? "Due now · runs on the machine serving this space" : "Due now"
			content.sound = .default
			content.userInfo = [Self.objectKey: occurrence.objectId]
			let seconds = max(1, Double(occurrence.at - now) / 1000)
			let request = UNNotificationRequest(
				identifier: Self.identifierPrefix + occurrence.id,
				content: content,
				trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
			)
			do { try await center.add(request) } catch { onScheduled?("error=\(error)"); return }
		}
		let scheduled = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(Self.identifierPrefix) }
		onScheduled?("pending=\(scheduled.count) " + scheduled.map { $0.identifier.dropFirst(Self.identifierPrefix.count).split(separator: ":").first.map(String.init) ?? "" }.joined(separator: ","))
	}

	// MARK: UNUserNotificationCenterDelegate

	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
		[.banner, .sound]
	}

	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
		guard let objectId = response.notification.request.content.userInfo[Self.objectKey] as? String else { return }
		await MainActor.run { onOpen?(objectId) }
	}
}
