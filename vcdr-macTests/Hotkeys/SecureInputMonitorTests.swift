import Testing
@testable import vcdr_mac

@MainActor
struct SecureInputMonitorTests {

    /// A held-then-released Secure Input flag is the whole reason this type exists:
    /// the hotkey taps stay installed and silent throughout, so the monitor is the
    /// only thing that can tell the user their hotkeys are dead and who to blame.
    @Test func reportsTheHolderWhileSecureInputIsHeldAndForgetsItOnRelease() {
        var isHeld = false
        let monitor = SecureInputMonitor(
            readIsActive: { isHeld },
            readHolderName: { "1Password" }
        )

        monitor.sample()
        #expect(monitor.isActive == false)
        #expect(monitor.holderName == nil)

        isHeld = true
        monitor.sample()
        #expect(monitor.isActive)
        #expect(monitor.holderName == "1Password")

        isHeld = false
        monitor.sample()
        #expect(monitor.isActive == false)
        #expect(monitor.holderName == nil)
    }
}
