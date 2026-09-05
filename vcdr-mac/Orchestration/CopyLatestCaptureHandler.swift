import AppKit
import OSLog

@MainActor
final class CopyLatestCaptureHandler {
    private let settings: AppSettings
    private let transcriptionHistory: any HistoryStore
    private let recordingIndicator: RecordingIndicatorPanel
    private let hotkeyRegistry: any HotkeyRegistry

    private var hotkeyClaim: HotkeyClaim?
    private var isHotkeySuppressed = false

    init(
        settings: AppSettings,
        hotkeyRegistry: any HotkeyRegistry,
        transcriptionHistory: any HistoryStore,
        recordingIndicator: RecordingIndicatorPanel
    ) {
        self.settings = settings
        self.hotkeyRegistry = hotkeyRegistry
        self.transcriptionHistory = transcriptionHistory
        self.recordingIndicator = recordingIndicator
        observeHotkeySettings()
        // Claiming a combination needs no Accessibility grant, so the shortcut is
        // live from launch rather than from whenever the grant arrives.
        setupHotkey()
    }

    /// Releases first and claims after, unconditionally: the window server refuses
    /// a second registration of a combination that is still claimed, so re-arming
    /// the same shortcut only works in that order.
    func setupHotkey() {
        hotkeyClaim?.release()
        hotkeyClaim = nil

        let binding = settings.copyLatestCaptureHotkey
        guard binding.isAssigned, !isHotkeySuppressed else { return }

        hotkeyClaim = hotkeyRegistry.claim(binding) { [weak self] in
            self?.copyLatestCapture()
        }
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

    // MARK: - Settings tracking

    /// Re-arms this handler's claim from `settings`, so a re-bound Copy Latest
    /// Capture shortcut applies at once. See `CaptureSession.observeHotkeySettings()`.
    private func observeHotkeySettings() {
        withObservationTracking {
            _ = settings.hotkeySettings
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.setupHotkey()
                self.observeHotkeySettings()
            }
        }
    }

    /// Drops or restores this claim while the user records a new shortcut in the
    /// UI, so the key press reaches the shortcut recorder.
    func setHotkeySuppressed(_ suppressed: Bool) {
        guard suppressed != isHotkeySuppressed else { return }
        isHotkeySuppressed = suppressed
        setupHotkey()
    }
}
