import Foundation
import Observation

/// The Diagnostics Unlock: the tap gesture on the version row that reveals the
/// diagnostics section, and the memory of that reveal.
///
/// The state is deliberately not an app setting — it says nothing about how the
/// app behaves, only whether the user has asked to see what it recorded — so it
/// lives in `UserDefaults.standard`: per device, never synced to iCloud and
/// never read by the extensions sharing the app group. A Debug build starts
/// unlocked; the gesture is only for builds a user installs.
@MainActor
@Observable
final class DiagnosticsUnlock {
    // MARK: - Constants

    private static let tapsToUnlock = 10
    /// The tap from which the row starts counting down. Earlier taps stay
    /// silent so the row looks inert to anyone who did not come here for it.
    private static let countdownStartsAtTap = 3
    nonisolated private static let defaultTapWindow: Duration = .seconds(2)
    private static let unlockedKey = "diagnostics_unlocked"

    private let defaults: UserDefaults
    /// How long a partial tap run survives without another tap.
    private let tapWindow: Duration
    private var tapsSoFar = 0
    private var expiryTask: Task<Void, Never>?

    /// Whether the diagnostics section is revealed.
    private(set) var isUnlocked: Bool

    /// Taps still needed, once the run is far enough along to say so out loud;
    /// `nil` while the row should say nothing.
    private(set) var tapsRemaining: Int?

    init(defaults: UserDefaults = .standard, tapWindow: Duration = DiagnosticsUnlock.defaultTapWindow) {
        self.defaults = defaults
        self.tapWindow = tapWindow
        #if DEBUG
        isUnlocked = true
        #else
        isUnlocked = defaults.bool(forKey: Self.unlockedKey)
        #endif
    }

    /// Counts one tap on the version row, unlocking on the tenth of a run.
    func registerTap() {
        guard !isUnlocked else { return }
        expiryTask?.cancel()
        tapsSoFar += 1
        guard tapsSoFar < Self.tapsToUnlock else {
            endRun()
            isUnlocked = true
            defaults.set(true, forKey: Self.unlockedKey)
            return
        }
        tapsRemaining = tapsSoFar >= Self.countdownStartsAtTap ? Self.tapsToUnlock - tapsSoFar : nil
        expiryTask = Task { [tapWindow] in
            try? await Task.sleep(for: tapWindow)
            guard !Task.isCancelled else { return }
            endRun()
        }
    }

    /// Hides the diagnostics section again, and forgets the unlock so the next
    /// launch needs the gesture afresh.
    func lock() {
        endRun()
        isUnlocked = false
        defaults.set(false, forKey: Self.unlockedKey)
    }

    private func endRun() {
        expiryTask?.cancel()
        expiryTask = nil
        tapsSoFar = 0
        tapsRemaining = nil
    }
}
