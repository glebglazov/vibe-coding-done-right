import AppKit
import OSLog

@MainActor
final class CopyLatestCaptureHandler {
    private let settings: AppSettings
    private let transcriptionHistory: TranscriptionHistory
    private let recordingIndicator: RecordingIndicatorPanel
    private let hotkeyManager = GlobalHotkeyManager()

    init(
        settings: AppSettings,
        transcriptionHistory: TranscriptionHistory,
        recordingIndicator: RecordingIndicatorPanel
    ) {
        self.settings = settings
        self.transcriptionHistory = transcriptionHistory
        self.recordingIndicator = recordingIndicator
    }

    func setupHotkey() {
        let binding = settings.copyLatestCaptureHotkey
        guard binding.isAssigned else {
            hotkeyManager.unregister()
            Logger.hotkeys.info("Copy latest capture hotkey unassigned, unregistered")
            return
        }

        hotkeyManager.onKeyDown = { [weak self] in
            self?.copyLatestCapture()
        }
        hotkeyManager.onKeyUp = nil

        let keyCode = CGKeyCode(binding.keyCode)
        let modifiers = CGEventFlags(rawValue: binding.modifiers)
        _ = hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
    }

    func updateHotkey() {
        setupHotkey()
    }

    private func copyLatestCapture() {
        guard let record = transcriptionHistory.latestRecord else {
            recordingIndicator.showCopyError("No captures yet")
            Logger.actions.info("Copy latest: no captures available")
            return
        }

        // Use processedText if available, fall back to fullCapture for old records
        let textToCopy = record.processedText ?? record.fullCapture
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)

        recordingIndicator.showCopied()
        Logger.actions.info("Copied latest capture to clipboard")
    }
}
