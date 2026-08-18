import AppKit
import Foundation
import HeraldKit
import OSLog
import UserNotifications

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "Notifications")

/// The ONLY place `UserNotifications` is touched for posting.
///
/// A value type so it can be handed to the ``NewMailNotifier`` actor; every call
/// goes straight to the system centre, which is itself thread-safe.
struct UserNotificationCenterAdapter: NewMailNotificationPosting {
    /// Injected so nothing constructs the system centre at init time — an
    /// unbundled process (a test host without a bundle id) traps in
    /// `UNUserNotificationCenter.current()`.
    private let center: @Sendable () -> UNUserNotificationCenter

    init(center: @escaping @Sendable () -> UNUserNotificationCenter = { .current() }) {
        self.center = center
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center().requestAuthorization(options: [.alert, .sound])
        } catch {
            // Denial is not an error, but a missing bundle / disabled centre is —
            // and either way Herald simply stays silent.
            logger.warning("Notification authorization failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    func post(_ notification: NewMailNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = .default
        content.userInfo = notification.userInfo
        // Same id replaces rather than stacks — the coalesced burst banner is
        // deliberately one per account.
        let request = UNNotificationRequest(
            identifier: notification.id,
            content: content,
            trigger: nil
        )
        do {
            try await center().add(request)
        } catch {
            logger.warning("Posting a new-mail notification failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

/// Turns a click on a banner into "activate Herald, show that conversation".
///
/// `NSObject` + delegate callbacks, so every method is `nonisolated` and hops to
/// the main actor itself: the system calls these off the main thread, and under
/// default-MainActor isolation an unannotated implementation would trap (see
/// "Herald Concurrency Rules", callback-isolation).
final class NewMailNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// Sendable because ``AppEnvironment`` is `@MainActor` (hence Sendable) and
    /// the route is a value.
    private let open: @Sendable (NewMailRoute) async -> Void

    init(open: @escaping @Sendable (NewMailRoute) async -> Void) {
        self.open = open
    }

    /// Installs itself as the system delegate. Must happen before any banner is
    /// posted, or a click on the first one is dropped.
    @MainActor
    func install(on center: UNUserNotificationCenter = .current()) {
        center.delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        // The response is a non-Sendable class: everything needed is copied out
        // here, synchronously, and only the value crosses to the main actor.
        let userInfo = Self.stringUserInfo(response.notification.request.content.userInfo)
        let isDefaultAction = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let open = open
        Task { @MainActor in
            defer { completionHandler() }
            guard isDefaultAction, let route = NewMailNotification.route(from: userInfo) else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            await open(route)
        }
    }

    /// Herald is frontmost: the list the banner is about is already updating in
    /// place, so a banner over it would be noise. Sound is dropped with it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            completionHandler(NSApplication.shared.isActive ? [] : [.banner, .sound])
        }
    }

    /// `[AnyHashable: Any]` → the Sendable payload the app actually wrote.
    /// Non-string entries (anything the system added) are dropped.
    nonisolated static func stringUserInfo(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, let value = value as? String else { continue }
            result[key] = value
        }
        return result
    }
}
