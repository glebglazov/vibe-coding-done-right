import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Drives the Diagnostics Unlock gesture the way a version row does: taps in,
/// reveal and countdown out. Each case starts from `lock()` because a Debug
/// build — which is what a test run is — starts unlocked.
@MainActor
@Suite("DiagnosticsUnlock")
struct DiagnosticsUnlockTests {
    private static let tapsToUnlock = 10

    private func lockedUnlock(tapWindow: Duration = .seconds(30)) -> DiagnosticsUnlock {
        let defaults = UserDefaults(suiteName: "DiagnosticsUnlockTests-\(UUID().uuidString)") ?? .standard
        let unlock = DiagnosticsUnlock(defaults: defaults, tapWindow: tapWindow)
        unlock.lock()
        return unlock
    }

    @Test("The tenth tap of a run reveals the section, and no earlier tap does")
    func tenthTapUnlocks() {
        let unlock = lockedUnlock()
        for _ in 1..<Self.tapsToUnlock {
            unlock.registerTap()
            #expect(unlock.isUnlocked == false)
        }
        unlock.registerTap()
        #expect(unlock.isUnlocked)
        #expect(unlock.tapsRemaining == nil)
    }

    @Test("The row stays silent until the third tap, then counts down")
    func countdownStartsAtThirdTap() {
        let unlock = lockedUnlock()
        unlock.registerTap()
        unlock.registerTap()
        #expect(unlock.tapsRemaining == nil)
        unlock.registerTap()
        #expect(unlock.tapsRemaining == 7)
        unlock.registerTap()
        #expect(unlock.tapsRemaining == 6)
    }

    @Test("A run with no tap for the whole tap window starts over")
    func runExpiresWithoutTaps() async throws {
        let tapWindow: Duration = .milliseconds(50)
        let unlock = lockedUnlock(tapWindow: tapWindow)
        for _ in 0..<Self.tapsToUnlock - 1 { unlock.registerTap() }
        #expect(unlock.tapsRemaining == 1)

        try await Task.sleep(for: tapWindow * 2)
        #expect(unlock.tapsRemaining == nil)

        unlock.registerTap()
        #expect(unlock.isUnlocked == false)
    }
}
