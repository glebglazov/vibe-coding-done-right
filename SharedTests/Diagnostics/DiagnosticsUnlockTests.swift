import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Drives the Diagnostics Unlock the way the version row and the diagnostics
/// settings section do: taps and switch flips in, reveal, countdown and surface
/// visibility out. Each case starts from `forget()` because a Debug build —
/// which is what a test run is — starts revealed.
@MainActor
@Suite("DiagnosticsUnlock")
struct DiagnosticsUnlockTests {
    private static let tapsToUnlock = 10

    /// One device's defaults, so a second `DiagnosticsUnlock` over the same
    /// store stands in for the next launch.
    private func deviceDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DiagnosticsUnlockTests-\(UUID().uuidString)") ?? .standard
    }

    private func forgottenUnlock(
        defaults: UserDefaults? = nil,
        tapWindow: Duration = .seconds(30)
    ) -> DiagnosticsUnlock {
        let unlock = DiagnosticsUnlock(defaults: defaults ?? deviceDefaults(), tapWindow: tapWindow)
        unlock.forget()
        return unlock
    }

    private func reveal(_ unlock: DiagnosticsUnlock) {
        for _ in 0..<Self.tapsToUnlock { unlock.registerTap() }
    }

    @Test("The tenth tap of a run reveals the surfaces, and no earlier tap does")
    func tenthTapReveals() {
        let unlock = forgottenUnlock()
        for _ in 1..<Self.tapsToUnlock {
            unlock.registerTap()
            #expect(unlock.showsSurfaces == false)
        }
        unlock.registerTap()
        #expect(unlock.isRevealed)
        #expect(unlock.showsSurfaces)
        #expect(unlock.tapsRemaining == nil)
    }

    @Test("The row stays silent until the third tap, then counts down")
    func countdownStartsAtThirdTap() {
        let unlock = forgottenUnlock()
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
        let unlock = forgottenUnlock(tapWindow: tapWindow)
        for _ in 0..<Self.tapsToUnlock - 1 { unlock.registerTap() }
        #expect(unlock.tapsRemaining == 1)

        try await Task.sleep(for: tapWindow * 2)
        #expect(unlock.tapsRemaining == nil)

        unlock.registerTap()
        #expect(unlock.isRevealed == false)
    }

    @Test("The switch hides and shows the surfaces, and the section stays put")
    func switchGovernsSurfacesOnly() {
        let unlock = forgottenUnlock()
        reveal(unlock)

        unlock.isShown = false
        #expect(unlock.showsSurfaces == false)
        #expect(unlock.isRevealed)

        unlock.isShown = true
        #expect(unlock.showsSurfaces)
    }

    @Test("Forgetting the gesture takes the section away and costs ten taps again")
    func forgettingCostsTheGestureAgain() {
        let unlock = forgottenUnlock()
        reveal(unlock)

        unlock.forget()
        #expect(unlock.isRevealed == false)
        #expect(unlock.showsSurfaces == false)

        for _ in 1..<Self.tapsToUnlock { unlock.registerTap() }
        #expect(unlock.isRevealed == false)
        unlock.registerTap()
        #expect(unlock.showsSurfaces)
    }

    @Test("The reveal and the switch both survive the next launch")
    func bothStatesSurviveRelaunch() {
        let defaults = deviceDefaults()
        let unlock = forgottenUnlock(defaults: defaults)
        reveal(unlock)
        unlock.isShown = false

        let relaunched = DiagnosticsUnlock(defaults: defaults)
        #expect(relaunched.isRevealed)
        #expect(relaunched.isShown == false)

        relaunched.forget()
        #expect(DiagnosticsUnlock(defaults: defaults).isRevealed == false)
    }
}
