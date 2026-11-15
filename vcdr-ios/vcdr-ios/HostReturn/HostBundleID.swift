import Foundation

/// The bundle ID of the app the user was typing in when the keyboard opened
/// VCDR through the Deep-Link Fallback.
nonisolated struct HostBundleID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        rawValue = trimmed
    }

    var description: String { rawValue }

    /// VCDR and its own extensions host the keyboard in place, so they are
    /// never an app to return to.
    func belongs(toApp appBundleID: String) -> Bool {
        let host = rawValue.lowercased()
        let app = appBundleID.lowercased()
        guard !app.isEmpty else { return false }
        return host == app || host.hasPrefix(app + ".")
    }
}

/// One sighting of the host app, stamped with when VCDR saw it.
nonisolated struct HostObservation: Equatable, Sendable {
    let host: HostBundleID
    let observedAt: Date
}
