import Foundation

/// How long the mic engine stays "hot" after the last recording before being
/// torn down. While hot, subsequent recordings start instantly because
/// `engine.start()` (100–500ms, or seconds under CoreML load) is avoided.
/// Raw value is seconds so UserDefaults can store it as an Int;
/// `.never` (0) and `.always` (-1) are sentinels for the two corner cases.
enum HotSessionTimeout: Int, CaseIterable, Identifiable {
    case fiveMinutes = 300
    case tenMinutes = 600
    case twentyMinutes = 1200
    case thirtyMinutes = 1800
    case oneHour = 3600
    /// Don't keep the mic hot at all: tear the engine down the moment
    /// recording stops, and skip the auto-hot on launch / foreground. The
    /// mic indicator is only on during an actual recording.
    case never = 0
    /// Keep the engine hot for the whole app lifetime. Backgrounding does
    /// not tear it down — UIBackgroundModes=audio keeps the session alive
    /// so the keyboard extension can drive recording without relaunching.
    case always = -1

    var id: Int { rawValue }

    /// Seconds to wait before tearing down. Meaningful only for the finite
    /// cases; callers must branch on `.never` / `.always` first.
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var displayName: String {
        switch self {
        case .fiveMinutes:   "5 minutes"
        case .tenMinutes:    "10 minutes"
        case .twentyMinutes: "20 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour:       "1 hour"
        case .never:         "Never"
        case .always:        "Always"
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
        // Distinguish "unset" from "set to 0" (`.never`) —
        // `integer(forKey:)` returns 0 for both, which would silently flip
        // fresh installs into `.never` when the user expected the 5-minute default.
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: storageKey) != nil else {
            return .defaultValue
        }
        let raw = defaults.integer(forKey: storageKey)
        return HotSessionTimeout(rawValue: raw) ?? .defaultValue
    }
}
