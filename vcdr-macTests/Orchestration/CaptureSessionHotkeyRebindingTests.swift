import CoreGraphics
import Foundation
import Testing
@testable import vcdr_mac

/// The session re-arms its hotkeys from `settings` rather than trusting each screen
/// to ask for it. These tests drive the settings path a user drives and assert the
/// live claims follow.
///
/// The Activation Hotkeys are only claimed while recording, so their tests re-bind
/// mid-capture — which is also the case that matters, since a user changing a
/// shortcut expects the next key press to obey it without a relaunch.
@Suite("CaptureSession — Hotkey re-binding")
struct CaptureSessionHotkeyRebindingTests {

    /// P, the key the two built-in paste destinations share by default.
    private static let pKeyCode: UInt16 = 35

    @MainActor
    private func recordingEnvironment() async -> CaptureSessionTestEnvironment {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "Hello destination")
        )
        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        return env
    }

    @Test("Re-binding a destination's Activation Hotkey claims the new combo without a relaunch")
    @MainActor
    func rebindingClaimsNewCombo() async {
        let env = await recordingEnvironment()
        defer { env.cleanup() }

        let copyID = OutputDestination.builtInCopyID
        guard let index = env.settings.outputDestinations.firstIndex(where: { $0.id == copyID }),
              let oldBinding = env.settings.outputDestinations.first(where: { $0.id == copyID })?.activationHotkey
        else {
            Issue.record("Built-in Copy destination missing from settings")
            return
        }
        // Shift+C rather than a superset of Option+C: a combination the old binding
        // already expanded to would be claimed either way and prove nothing.
        let newBinding = HotkeyBinding(
            keyCode: KeyCodeMap.cKeyCode,
            modifiers: UInt64(CGEventFlags.maskShift.rawValue)
        )
        env.settings.outputDestinations[index].activationHotkey = newBinding

        #expect(await waitFor { env.hotkeyRegistry.claimedBindings.contains(newBinding) })
        #expect(
            !env.hotkeyRegistry.claimedBindings.contains(oldBinding),
            "The combination the destination no longer answers to must reach the frontmost app"
        )

        env.session.cancel()
        #expect(await env.waitForPhase { $0 == .idle })
    }

    @Test("Clearing one Activation Hotkey releases its combinations and leaves the others claimed")
    @MainActor
    func clearingReleasesOnlyThatDestination() async {
        let env = await recordingEnvironment()
        defer { env.cleanup() }

        let pasteID = OutputDestination.builtInPasteID
        guard let pasteIndex = env.settings.outputDestinations.firstIndex(where: { $0.id == pasteID }),
              let copyBinding = env.settings.outputDestinations
                  .first(where: { $0.id == OutputDestination.builtInCopyID })?.activationHotkey
        else {
            Issue.record("Built-in Paste or Copy destination missing from settings")
            return
        }
        let pasteBinding = env.settings.outputDestinations[pasteIndex].activationHotkey
        env.settings.outputDestinations[pasteIndex].activationHotkey = .unassigned

        #expect(await waitFor { !env.hotkeyRegistry.claimedBindings.contains(pasteBinding) })
        #expect(
            env.hotkeyRegistry.claimedBindings.contains(copyBinding),
            "Paste to Initial App still shares the key, and Copy is untouched"
        )
        #expect(
            env.hotkeyRegistry.claimedBindings.contains { $0.keyCode == Self.pKeyCode },
            "Shift+Option+P belongs to another destination and stays claimed"
        )

        env.session.cancel()
        #expect(await env.waitForPhase { $0 == .idle })
    }

    @Test("A new destination's Activation Hotkey is claimed as soon as it is bound")
    @MainActor
    func addedDestinationIsClaimed() async {
        let env = await recordingEnvironment()
        defer { env.cleanup() }

        let newID = env.settings.addDestination()
        let newBinding = HotkeyBinding(
            keyCode: KeyCodeMap.hKeyCode,
            modifiers: UInt64(CGEventFlags.maskAlternate.rawValue)
        )
        guard let index = env.settings.outputDestinations.firstIndex(where: { $0.id == newID }) else {
            Issue.record("Added destination missing from settings")
            return
        }
        env.settings.outputDestinations[index].activationHotkey = newBinding

        #expect(await waitFor { env.hotkeyRegistry.claimedBindings.contains(newBinding) })

        env.session.cancel()
        #expect(await env.waitForPhase { $0 == .idle })
    }

    @Test("Re-binding the toggle hotkey takes effect for the next key press, without a relaunch")
    @MainActor
    func togglePicksUpNewBinding() async {
        let env = CaptureSessionTestEnvironment()
        defer { env.cleanup() }

        let newBinding = HotkeyBinding(
            keyCode: KeyCodeMap.escapeKeyCode,
            modifiers: UInt64(CGEventFlags.maskControl.rawValue)
        )
        env.settings.hotkeySettings.toggleRecordingHotkey = newBinding
        #expect(await waitFor { env.hotkeyRegistry.claimedBindings == [newBinding] })

        #expect(env.hotkeyRegistry.press(newBinding))
        #expect(await env.waitForPhase { $0 == .recording })

        env.session.cancel()
        #expect(await env.waitForPhase { $0 == .idle })
    }

    @Test("Clearing the toggle shortcut hands the combination back")
    @MainActor
    func clearingToggleReleasesItsClaim() async {
        let env = CaptureSessionTestEnvironment()
        defer { env.cleanup() }

        let cleared = env.settings.toggleRecordingHotkey
        env.settings.hotkeySettings.toggleRecordingHotkey = .unassigned

        #expect(await waitFor { !env.hotkeyRegistry.press(cleared) })
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

        let newBinding = HotkeyBinding(
            keyCode: KeyCodeMap.slashKeyCode,
            modifiers: UInt64(CGEventFlags.maskAlternate.rawValue)
        )
        env.settings.hotkeySettings.cancelRecordingHotkey = newBinding
        #expect(
            await waitFor { env.hotkeyRegistry.claimedBindings.contains(newBinding) },
            "Cancel must stay claimed for the capture in flight"
        )

        #expect(env.hotkeyRegistry.press(newBinding))
        #expect(await env.waitForPhase { $0 == .idle })
    }
}
