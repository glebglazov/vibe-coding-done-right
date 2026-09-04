import Foundation
import Observation

/// The Diagnostics Unlock: the tap gesture on the version row that reveals the
/// diagnostics settings section, and the two memories that gesture leaves —
/// that it happened at all, and whether the diagnostics surfaces are on screen
/// right now.
///
/// Neither state is an app setting — they say nothing about how the app
/// behaves, only whether the user has asked to see what it recorded — so both
/// live in `UserDefaults.standard`: per device, never synced to iCloud and
/// never read by the extensions sharing the app group.
///
/// Neither state reaches what the app records. The persistent log fills in
/// every build and in every state, so a bug noticed during a normal day is
/// still readable hours later.
@MainActor
@Observable
final class DiagnosticsUnlock {
    // MARK: - Constants

    private static let tapsToUnlock = 10
    /// The tap from which the row starts counting down. Earlier taps stay
    /// silent so the row looks inert to anyone who did not come here for it.
    private static let countdownStartsAtTap = 3
    nonisolated private static let defaultTapWindow: Duration = .seconds(2)
    private static let revealedKey = "diagnostics_unlocked"
    private static let shownKey = "diagnostics_shown"
    /// What a device that has never answered either question starts at: a
    /// Debug build is revealed, because the gesture is only for builds a user
    /// installs, and either build shows the surfaces once revealed.
    #if DEBUG
    private static let revealedByDefault = true
    #else
    private static let revealedByDefault = false
    #endif
    private static let shownByDefault = true

    private let defaults: UserDefaults
    /// How long a partial tap run survives without another tap.
    private let tapWindow: Duration
    private var tapsSoFar = 0
    private var expiryTask: Task<Void, Never>?

    /// Whether the gesture has been done, and so whether the diagnostics
    /// settings section exists at all. Only the gesture sets it.
    private(set) var isRevealed: Bool

    /// Whether the diagnostics surfaces are on screen. The user flips this
    /// freely from the settings section, which stays put either way.
    var isShown: Bool {
        didSet { defaults.set(isShown, forKey: Self.shownKey) }
    }

    /// Whether the diagnostics surfaces belong on screen: the gesture has been
    /// done, and the user has not switched them off since.
    var showsSurfaces: Bool { isRevealed && isShown }

    /// Taps still needed, once the run is far enough along to say so out loud;
    /// `nil` while the row should say nothing.
    private(set) var tapsRemaining: Int?

    init(defaults: UserDefaults = .standard, tapWindow: Duration = DiagnosticsUnlock.defaultTapWindow) {
        self.defaults = defaults
        self.tapWindow = tapWindow
        isShown = defaults.object(forKey: Self.shownKey) as? Bool ?? Self.shownByDefault
        isRevealed = defaults.object(forKey: Self.revealedKey) as? Bool ?? Self.revealedByDefault
    }

    /// Counts one tap on the version row, revealing on the tenth of a run.
    func registerTap() {
        guard !isRevealed else { return }
        expiryTask?.cancel()
        tapsSoFar += 1
        guard tapsSoFar < Self.tapsToUnlock else {
            endRun()
            reveal()
            return
        }
        tapsRemaining = tapsSoFar >= Self.countdownStartsAtTap ? Self.tapsToUnlock - tapsSoFar : nil
        expiryTask = Task { [tapWindow] in
            try? await Task.sleep(for: tapWindow)
            guard !Task.isCancelled else { return }
            endRun()
        }
    }

    /// Forgets the gesture: the settings section goes away with the surfaces,
    /// and the next reveal needs the ten taps afresh.
    func forget() {
        endRun()
        isRevealed = false
        defaults.set(false, forKey: Self.revealedKey)
        isShown = Self.shownByDefault
    }

    private func reveal() {
        isRevealed = true
        defaults.set(true, forKey: Self.revealedKey)
        isShown = true
    }

    private func endRun() {
        expiryTask?.cancel()
        expiryTask = nil
        tapsSoFar = 0
        tapsRemaining = nil
    }
}
