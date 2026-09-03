import Foundation
import Testing
@testable import vcdr_mac

/// Activation Hotkeys are the one hotkey family edited from several screens
/// (destination list, destination detail), so the session tracks settings rather
/// than trusting each call site to refresh. These tests drive the settings path a
/// user drives and assert the armed set follows — installing the tap itself needs
/// Accessibility, which a test process does not have.
@Suite("CaptureSession — Activation Hotkeys")
struct CaptureSessionDestinationHotkeyTests {

    private static let armTimeout: Duration = .seconds(2)
    private static let armPollInterval: Duration = .milliseconds(20)

    @MainActor
    private func waitForArmed(
        _ session: CaptureSession,
        _ condition: @escaping ([UUID: HotkeyBinding]) -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while start.duration(to: .now) < Self.armTimeout {
            if condition(session.destinationHotkey.armedActivationHotkeys) { return true }
            try? await Task.sleep(for: Self.armPollInterval)
        }
        return false
    }

    @Test("Re-binding a destination's Activation Hotkey arms the new combo without a relaunch")
    @MainActor
    func rebindingArmsNewCombo() async {
        let env = CaptureSessionTestEnvironment()
        defer { env.cleanup() }

        let newBinding = HotkeyBinding(keyCode: KeyCodeMap.slashKeyCode, modifiers: 0x40000)
        let copyID = OutputDestination.builtInCopyID
        guard let index = env.settings.outputDestinations.firstIndex(where: { $0.id == copyID }) else {
            Issue.record("Built-in Copy destination missing from settings")
            return
        }
        env.settings.outputDestinations[index].activationHotkey = newBinding

        #expect(await waitForArmed(env.session) { $0[copyID] == newBinding })
    }

    @Test("Clearing one Activation Hotkey disarms it and leaves the others armed")
    @MainActor
    func clearingDisarmsOnlyThatDestination() async {
        let env = CaptureSessionTestEnvironment()
        defer { env.cleanup() }

        let pasteID = OutputDestination.builtInPasteID
        let copyID = OutputDestination.builtInCopyID
        guard let pasteIndex = env.settings.outputDestinations.firstIndex(where: { $0.id == pasteID }),
              let copyBinding = env.settings.outputDestinations.first(where: { $0.id == copyID })?.activationHotkey
        else {
            Issue.record("Built-in Paste or Copy destination missing from settings")
            return
        }
        env.settings.outputDestinations[pasteIndex].activationHotkey = .unassigned

        #expect(await waitForArmed(env.session) { $0[pasteID] == nil && $0[copyID] == copyBinding })
    }

    @Test("A new destination's Activation Hotkey is armed as soon as it is bound")
    @MainActor
    func addedDestinationIsArmed() async {
        let env = CaptureSessionTestEnvironment()
        defer { env.cleanup() }

        let newID = env.settings.addDestination()
        let newBinding = HotkeyBinding(keyCode: KeyCodeMap.slashKeyCode, modifiers: 0x20000)
        guard let index = env.settings.outputDestinations.firstIndex(where: { $0.id == newID }) else {
            Issue.record("Added destination missing from settings")
            return
        }
        env.settings.outputDestinations[index].activationHotkey = newBinding

        #expect(await waitForArmed(env.session) { $0[newID] == newBinding })
    }

    @Test("Re-binding the cancel hotkey mid-capture leaves cancel live for that run")
    @MainActor
    func cancelStaysLiveAfterRebindDuringCapture() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "Hello cancel")
        )
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })

        env.session.updateCancelRecordingKeyCode(KeyCodeMap.slashKeyCode)
        #expect(env.session.cancelHotkey.isEnabled, "Cancel must stay armed for the capture in flight")

        env.session.cancel()
        #expect(await env.waitForPhase { $0 == .idle })
    }
}
