import Foundation
import OSLog
import UserNotifications

/// Settings keys + defaults for the idle auto-stop feature, kept in one place so
/// the Settings UI (`@AppStorage`) and the capture-side idle monitor agree on
/// key names and bounds.
enum AutoStopSettings {
    static let enabledKey = "settings.autoStopEnabled"
    static let minutesKey = "settings.autoStopMinutes"
    static let defaultMinutes = 5
    static let minMinutes = 1
    static let maxMinutes = 120
    /// Durations offered in the Settings pop-up (minutes).
    static let presetMinutes = [1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120]

    /// Current configuration read from `UserDefaults`. `minutes` is clamped to a
    /// sane range so a missing or zero key can never trigger an instant stop.
    static func current(_ defaults: UserDefaults = .standard) -> (enabled: Bool, minutes: Int) {
        let enabled = defaults.bool(forKey: enabledKey)
        let raw = defaults.object(forKey: minutesKey) as? Int ?? defaultMinutes
        let minutes = min(max(raw, minMinutes), maxMinutes)
        return (enabled, minutes)
    }
}

/// Local notifications for recording lifecycle events (currently just the idle
/// auto-stop). Authorization is requested when the user enables auto-stop, so we
/// never prompt people who don't use the feature; posting silently no-ops if the
/// user declined.
enum RecordingNotifier {
    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "notify")

    /// Ask for alert + sound permission. Idempotent — the system won't reprompt
    /// once the choice is made, so it's safe to call on enable and at launch.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log.error("Notification auth failed: \(String(describing: error), privacy: .public)")
            } else {
                log.notice("Notification auth granted=\(granted)")
            }
        }
    }

    /// Post the "we stopped because it went quiet" notification, delivered
    /// immediately (no trigger).
    static func autoStopped(afterMinutes minutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "No speech for \(minutes) minute\(minutes == 1 ? "" : "s") — Sadi stopped and saved the recording."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("Notification post failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
