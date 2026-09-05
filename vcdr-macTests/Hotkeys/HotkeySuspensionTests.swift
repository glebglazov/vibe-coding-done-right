import CoreGraphics
import Foundation
import Testing
@testable import vcdr_mac

/// While the user records a new shortcut, VCDR must claim nothing at all — a
/// claim has no pass-through, so the recorder can only read a combination the
/// app has bound if the app has let go of it. These drive that through a real
/// `CaptureSession`, so what is released and restored is whatever the owners
/// happened to hold rather than a list the test wrote down.
@Suite("Hotkey suspension")
struct HotkeySuspensionTests {

    @MainActor
    private func recordingEnvironment() async -> CaptureSessionTestEnvironment {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "Hello suspension")
        )
        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        return env
    }

    @Test("A Suspension hands every combination back and returns exactly those on release")
    @MainActor
    func suspensionReleasesAndRestoresEveryClaim() async {
        let env = await recordingEnvironment()
        defer { env.cleanup() }

        let claimedBeforehand = env.hotkeyRegistry.claimedBindings
        #expect(claimedBeforehand.contains(env.settings.toggleRecordingHotkey))
        #expect(claimedBeforehand.contains(env.settings.cancelRecordingHotkey))

        let suspension = env.suspendableRegistry.suspend()
        #expect(env.hotkeyRegistry.claimedBindings.isEmpty)
        #expect(!env.hotkeyRegistry.press(env.settings.toggleRecordingHotkey))

        suspension.release()
        #expect(env.hotkeyRegistry.claimedBindings == claimedBeforehand)

        // The capture that was in flight throughout is still cancellable by key.
        #expect(env.hotkeyRegistry.press(env.settings.cancelRecordingHotkey))
        #expect(await env.waitForPhase { $0 == .idle })
    }

    @Test("The combinations come back only when the last Suspension is released")
    @MainActor
    func suspensionsNest() async {
        let env = await recordingEnvironment()
        defer { env.cleanup() }

        let outer = env.suspendableRegistry.suspend()
        let inner = env.suspendableRegistry.suspend()

        inner.release()
        #expect(env.hotkeyRegistry.claimedBindings.isEmpty, "The outer Suspension still stands")

        outer.release()
        #expect(env.hotkeyRegistry.claimedBindings.contains(env.settings.cancelRecordingHotkey))

        env.session.cancel()
        #expect(await env.waitForPhase { $0 == .idle })
    }

    @Test("A shortcut re-bound during a Suspension comes back as its new combination")
    @MainActor
    func aShortcutReboundWhileSuspendedIsArmedOnRelease() async {
        let env = await recordingEnvironment()
        defer { env.cleanup() }

        let suspension = env.suspendableRegistry.suspend()

        // What the recorder itself does: write the captured combination to
        // settings, then let go of the Suspension.
        let rebound = HotkeyBinding(
            keyCode: KeyCodeMap.cKeyCode,
            modifiers: UInt64(CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue)
        )
        let replaced = env.settings.toggleRecordingHotkey
        env.settings.hotkeySettings.toggleRecordingHotkey = rebound
        #expect(env.hotkeyRegistry.claimedBindings.isEmpty, "Nothing may be claimed mid-recorder")

        suspension.release()
        #expect(await waitFor { env.hotkeyRegistry.claimedBindings.contains(rebound) })
        #expect(!env.hotkeyRegistry.claimedBindings.contains(replaced))

        env.session.cancel()
        #expect(await env.waitForPhase { $0 == .idle })
    }
}
