import Foundation
import Testing
@testable import vcdr_mac

/// The toggle hotkey drives the whole capture cycle, and it does so through the
/// injected `HotkeyRegistry` — so these press the key the way the system would,
/// rather than calling `toggle()` behind its back.
@Suite("CaptureSession — Toggle hotkey")
struct CaptureSessionToggleHotkeyTests {

    private static let testRecordingDuration: Duration = .milliseconds(100)

    @Test("Pressing the bound toggle combination starts a capture, and pressing it again finishes it")
    @MainActor
    func togglePressStartsAndStopsACapture() async {
        let env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "Hello hotkey")
        )
        defer { env.cleanup() }

        let toggle = env.settings.toggleRecordingHotkey
        #expect(env.hotkeyRegistry.press(toggle))
        #expect(await env.waitForPhase { $0 == .recording })
        try? await Task.sleep(for: Self.testRecordingDuration)

        #expect(env.hotkeyRegistry.press(toggle))
        #expect(await env.waitForRest())

        let outcome = await env.session.waitForNextIdle(timeout: .seconds(2))
        #expect(outcome?.kind == .executed)
        #expect(outcome?.finalText == "hello hotkey ")
    }
}
