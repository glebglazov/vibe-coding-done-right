import Foundation

/// How long the mic engine stays "hot" after the last recording before being
/// torn down. While hot, subsequent recordings start instantly because
/// `engine.start()` (100–500ms, or seconds under CoreML load) is avoided.
/// Raw value is seconds so UserDefaults can store it as an Int;
/// `.immediately` (0) and `.never` (-1) are sentinels for the two corner cases.
enum HotSessionTimeout: Int, CaseIterable, Identifiable {
    case fiveMinutes = 300
    case tenMinutes = 600
    case twentyMinutes = 1200
    case thirtyMinutes = 1800
    case oneHour = 3600
    /// Tear the engine down the moment recording stops. Also skips the
    /// auto-hot on launch / foreground, so the mic indicator is only on
    /// during actual recording.
    case immediately = 0
    /// Keep the engine hot as long as the app is foreground. Backgrounding
    /// still tears it down (iOS suspends audio without the background-audio
    /// entitlement).
    case never = -1

    var id: Int { rawValue }

    /// Seconds to wait before tearing down. Meaningful only for the finite
    /// cases; callers must branch on `.immediately` / `.never` first.
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var displayName: String {
        switch self {
        case .fiveMinutes:   "5 minutes"
        case .tenMinutes:    "10 minutes"
        case .twentyMinutes: "20 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour:       "1 hour"
        case .immediately:   "Immediately"
        case .never:         "Never"
        }
    }

    static let defaultValue: HotSessionTimeout = .fiveMinutes

    /// UserDefaults key. App-local: the keyboard extension never runs its own
    /// engine, so no App Group sharing is needed.
    static let storageKey = "hot_session_timeout_seconds"

    /// Notification posted by the Settings UI when the user picks a new value,
    /// so the coordinator can restart the live inactivity timer immediately
    /// instead of waiting for the next reschedule.
    static let didChangeNotification = Notification.Name("hotSessionTimeoutDidChange")

    static func current() -> HotSessionTimeout {
        // Distinguish "unset" from "set to 0" (`.immediately`) —
        // `integer(forKey:)` returns 0 for both, which would silently flip
        // fresh installs into `.immediately`.
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: storageKey) != nil else {
            return .defaultValue
        }
        let raw = defaults.integer(forKey: storageKey)
        return HotSessionTimeout(rawValue: raw) ?? .defaultValue
    }
}
