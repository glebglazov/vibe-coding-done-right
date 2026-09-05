import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import vcdr_mac

/// Copy Latest Capture is one shortcut driving one action, so these press the
/// combination through the injected `HotkeyRegistry` and assert what lands on the
/// pasteboard. The shortcut ships unassigned, so every test binds it first.
@Suite("CopyLatestCaptureHandler — Hotkey")
@MainActor
struct CopyLatestCaptureHandlerTests {

    private struct Environment {
        let handler: CopyLatestCaptureHandler
        let settings: AppSettings
        let registry: FakeHotkeyRegistry
        let history: FileHistoryStore
    }

    private static let binding = HotkeyBinding(
        keyCode: KeyCodeMap.escapeKeyCode,
        modifiers: UInt64(CGEventFlags.maskControl.rawValue)
    )

    private func makeEnvironment(latestCapture: String?) -> Environment {
        let settings = AppSettings(userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!)
        settings.hotkeySettings.copyLatestCaptureHotkey = Self.binding

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-test-\(UUID().uuidString)")
        let history = FileHistoryStore(snapshot: FileHistoryStore.loadSnapshot(storageRoot: storageRoot))
        if let latestCapture {
            history.record(
                conversationID: UUID(),
                inputSegments: [InputSegment(text: latestCapture)],
                output: latestCapture,
                label: nil
            )
        }

        let overrides = SessionOverrides()
        let registry = FakeHotkeyRegistry()
        let handler = CopyLatestCaptureHandler(
            settings: settings,
            hotkeyRegistry: registry,
            transcriptionHistory: history,
            recordingIndicator: RecordingIndicatorPanel(
                settings: settings,
                overrides: overrides,
                audioRecorder: AudioRecorder()
            )
        )
        return Environment(handler: handler, settings: settings, registry: registry, history: history)
    }

    @Test("Pressing the bound combination copies the latest capture")
    func pressCopiesTheLatestCapture() async {
        let env = makeEnvironment(latestCapture: "the latest capture")
        #expect(await waitFor { env.registry.claimedBindings == [Self.binding] })

        NSPasteboard.general.clearContents()
        #expect(env.registry.press(Self.binding))
        #expect(NSPasteboard.general.string(forType: .string) == "the latest capture")
    }

    @Test("Re-binding the shortcut takes effect for the next key press")
    func rebindingAppliesWithoutRelaunch() async {
        let env = makeEnvironment(latestCapture: "the latest capture")
        let newBinding = HotkeyBinding(
            keyCode: KeyCodeMap.escapeKeyCode,
            modifiers: UInt64(CGEventFlags.maskCommand.rawValue)
        )
        env.settings.hotkeySettings.copyLatestCaptureHotkey = newBinding
        #expect(await waitFor { env.registry.claimedBindings == [newBinding] })

        NSPasteboard.general.clearContents()
        #expect(env.registry.press(newBinding))
        #expect(NSPasteboard.general.string(forType: .string) == "the latest capture")
    }

    @Test("Clearing the shortcut hands the combination back")
    func clearingReleasesTheClaim() async {
        let env = makeEnvironment(latestCapture: "the latest capture")
        #expect(await waitFor { env.registry.claimedBindings == [Self.binding] })

        env.settings.hotkeySettings.copyLatestCaptureHotkey = .unassigned

        #expect(await waitFor { env.registry.claimedBindings.isEmpty })
        #expect(!env.registry.press(Self.binding))
    }
}
