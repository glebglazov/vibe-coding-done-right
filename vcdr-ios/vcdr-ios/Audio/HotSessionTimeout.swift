import Foundation

/// How long the mic engine stays "hot" after the last recording before being
/// torn down. While hot, subsequent recordings start instantly because
/// `engine.start()` (100–500ms, or seconds under CoreML load) is avoided.
/// Raw value is seconds so UserDefaults can store it as an Int.
enum HotSessionTimeout: Int, CaseIterable, Identifiable {
    case fiveMinutes = 300
    case tenMinutes = 600
    case twentyMinutes = 1200
    case thirtyMinutes = 1800
    case oneHour = 3600

    var id: Int { rawValue }

    var seconds: TimeInterval { TimeInterval(rawValue) }

    var displayName: String {
        switch self {
        case .fiveMinutes:   "5 minutes"
        case .tenMinutes:    "10 minutes"
        case .twentyMinutes: "20 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour:       "1 hour"
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
        let raw = UserDefaults.standard.integer(forKey: storageKey)
        return HotSessionTimeout(rawValue: raw) ?? .defaultValue
    }
}
