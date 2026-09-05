import Foundation
import Testing
@testable import vcdr_mac

/// Cancel's claim is a function of the capture phase: held while there is a
/// capture to cancel, gone the instant there is not. A claim has no
/// pass-through, so "gone" is what lets an ordinary combination like Shift+Tab
/// reach the frontmost app while VCDR sits idle — these press the combination
/// through the registry and read the answer from whether anything claimed it.
@Suite("CaptureSession — Cancel hotkey")
struct CaptureSessionCancelHotkeyTests {

    @Test("Pressing the bound cancel combination during a capture cancels it")
    @MainActor
    func cancelPressDuringCaptureCancelsIt() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "Hello cancel")
        )
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })

        #expect(env.hotkeyRegistry.press(env.settings.cancelRecordingHotkey))
        #expect(await env.waitForPhase { $0 == .idle })

        let outcome = await env.session.waitForNextIdle(timeout: .seconds(2))
        #expect(outcome?.kind == .cancelled)
    }

    @Test("An idle session claims nothing, so the cancel combination reaches the frontmost app")
    @MainActor
    func idleSessionLeavesTheCombinationAlone() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "Hello cancel")
        )
        defer { env.cleanup() }

        let cancel = env.settings.cancelRecordingHotkey
        #expect(!env.hotkeyRegistry.press(cancel), "Nothing to cancel at launch")

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        env.session.toggle()
        #expect(await env.waitForRest())

        #expect(!env.hotkeyRegistry.press(cancel), "Nothing to cancel once the capture finished")
    }

    @Test("A recording that fails to start hands the cancel combination back")
    @MainActor
    func audioStartFailureReleasesTheClaim() async {
        let env = CaptureSessionTestEnvironment()
        defer { env.cleanup() }
        env.audioRecorder.testStartFailure = .unknown

        env.session.toggle()
        #expect(await env.waitForPhase { phase in
            if case .error = phase { return true }
            return false
        })

        #expect(!env.hotkeyRegistry.press(env.settings.cancelRecordingHotkey))
    }

    @Test("A stop that finds no audio recorded hands the cancel combination back")
    @MainActor
    func noAudioRecordedReleasesTheClaim() async {
        let env = CaptureSessionTestEnvironment()
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })

        // Take the recording out from under the session, the way a recorder that
        // captured nothing would leave it.
        _ = env.audioRecorder.stopRecording()

        env.session.toggle()
        #expect(await env.waitForPhase { phase in
            if case .error = phase { return true }
            return false
        })

        #expect(!env.hotkeyRegistry.press(env.settings.cancelRecordingHotkey))
    }

    @Test("A capture in flight keeps cancel live across the mode switcher stepping in")
    @MainActor
    func suspensionReleasesAndRestoresTheClaim() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "Hello cancel")
        )
        defer { env.cleanup() }

        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })

        let cancel = env.settings.cancelRecordingHotkey
        let token = env.session.suspendForModeSwitcher()
        #expect(!env.hotkeyRegistry.press(cancel), "The switcher's own Escape must reach it")

        token.release()
        #expect(await waitFor { env.hotkeyRegistry.claimedBindings.contains(cancel) })

        #expect(env.hotkeyRegistry.press(cancel))
        #expect(await env.waitForPhase { $0 == .idle })
    }
}
