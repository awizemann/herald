import AppKit
import Foundation

/// The two user-facing switches for alerts, and the one place their keys and
/// defaults are written down.
///
/// Both default to ON when the key is absent: a mail client that says nothing on
/// first launch reads as broken, and the system's own permission prompt is the
/// real gate on banners.
enum NotificationSettings {
    nonisolated static let newMailKey = "notifications.newMail.enabled"
    nonisolated static let dockBadgeKey = "notifications.dockBadge.enabled"

    nonisolated static func newMailEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: newMailKey) as? Bool ?? true
    }

    nonisolated static func dockBadgeEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: dockBadgeKey) as? Bool ?? true
    }
}

/// The unread count on the Dock icon.
///
/// The formatting is a `nonisolated static` so it is assertable without a Dock:
/// zero means NO badge (an empty label still draws a bubble), and the count is
/// capped so a runaway inbox cannot stretch the tile.
enum DockBadge {
    nonisolated static let cap = 999

    nonisolated static func label(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > cap ? "\(cap)+" : String(count)
    }

    /// Writes the label onto the real Dock tile. `enabled == false` clears it,
    /// so turning the setting off takes effect immediately rather than at the
    /// next count change.
    @MainActor
    static func apply(count: Int, enabled: Bool, tile: NSDockTile = NSApplication.shared.dockTile) {
        tile.badgeLabel = enabled ? label(for: count) : nil
    }
}
