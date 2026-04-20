import AppKit
import OSLog

@MainActor
final class CopyLatestCaptureHandler {
    private let settings: AppSettings
    private let transcriptionHistory: any HistoryStore
    private let recordingIndicator: RecordingIndicatorPanel
    private let hotkeyManager = GlobalHotkeyManager()

    init(
        settings: AppSettings,
        transcriptionHistory: any HistoryStore,
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

    private func copyLatestCapture() {
        guard let conversation = transcriptionHistory.latestConversation else {
            recordingIndicator.showCopyError("No captures yet")
            Logger.actions.info("Copy latest: no captures available")
            return
        }

        let textToCopy = conversation.copyableText
        ClipboardHelper.writeString(textToCopy)

        recordingIndicator.showCopied()
        Logger.actions.info("Copied latest capture to clipboard")
    }

    // MARK: - Settings + Re-registration

    func updateCopyLatestCaptureKeyCode(_ code: UInt16) {
        settings.copyLatestCaptureHotkey.keyCode = code
        setupHotkey()
    }

    func updateCopyLatestCaptureModifiers(_ mods: UInt64) {
        settings.copyLatestCaptureHotkey.modifiers = mods
        setupHotkey()
    }

    /// Used while the user is recording a new shortcut in the UI so this hotkey
    /// passes through unconsumed.
    func setHotkeySuppressed(_ suppressed: Bool) {
        hotkeyManager.isSuppressed = suppressed
    }
}
