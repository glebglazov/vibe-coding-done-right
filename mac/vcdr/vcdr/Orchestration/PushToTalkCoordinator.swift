import Foundation
import AppKit
import OSLog

@Observable
final class PushToTalkCoordinator {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case executing
        case error(String)
    }

    private(set) var state: State = .idle

    private let settings: AppSettings
    private let transcriptionProvider: ParakeetProvider
    private let audioRecorder: AudioRecorder
    private let hotkeyManager: GlobalHotkeyManager
    private let mediaPlaybackController: MediaPlaybackController

    private var previousActiveApp: NSRunningApplication?
    private var isKeyDown = false
    private let recordingIndicator = RecordingIndicatorPanel()

    init(settings: AppSettings, transcriptionProvider: ParakeetProvider, mediaPlaybackController: MediaPlaybackController) {
        self.settings = settings
        self.transcriptionProvider = transcriptionProvider
        self.mediaPlaybackController = mediaPlaybackController
        self.audioRecorder = AudioRecorder()
        self.hotkeyManager = GlobalHotkeyManager()
    }

    func setupHotkey() {
        let keyCode = CGKeyCode(settings.pushToTalkHotkey.keyCode)
        let modifiers = CGEventFlags(rawValue: settings.pushToTalkHotkey.modifiers)

        // Unassigned hotkey — unregister and bail
        guard settings.pushToTalkHotkey.isAssigned else {
            hotkeyManager.unregister()
            Logger.hotkeys.info("Hotkey unassigned, unregistered")
            return
        }

        hotkeyManager.onKeyDown = { [weak self] in
            Task { @MainActor in
                await self?.onHotkeyDown()
            }
        }
        hotkeyManager.onKeyUp = { [weak self] in
            Task { @MainActor in
                self?.stopRecordingAndTranscribe()
            }
        }

        _ = hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
    }

    func updateHotkey() {
        setupHotkey()
    }

    /// Toggle recording from UI button (fully synchronous for immediate feedback)
    func toggleRecording() {
        switch state {
        case .idle, .error:
            Task { await onHotkeyDown() }
        case .recording:
            stopRecordingAndTranscribe()
        default:
            break
        }
    }

    // MARK: - Recording Start (async — needs mic permission check)

    private func onHotkeyDown() async {
        if case .error = state {
            state = .idle
        }

        guard state == .idle else {
            Logger.app.warning("Hotkey pressed but not idle (state: \(String(describing: self.state)))")
            return
        }

        guard await transcriptionProvider.isReady else {
            Logger.app.warning("Hotkey pressed but transcription model not loaded yet")
            state = .error("Model still loading...")
            resetAfterDelay()
            return
        }

        isKeyDown = true
        previousActiveApp = NSWorkspace.shared.frontmostApplication

        let started = await audioRecorder.startRecording()
        if started {
            state = .recording
            recordingIndicator.show()
            if settings.audioSettings.pauseMediaDuringRecording {
                mediaPlaybackController.pauseIfNeeded()
            }
            Logger.app.info("Push-to-talk: recording started")

            // If key was released while we were starting, immediately stop
            if !isKeyDown {
                Logger.app.info("Key released during setup, stopping immediately")
                stopRecordingAndTranscribe()
            }
        } else {
            isKeyDown = false
            state = .error("Failed to start recording")
            Logger.app.error("Push-to-talk: failed to start recording")
            resetAfterDelay()
        }
    }

    // MARK: - Recording Stop (synchronous for immediate UI feedback)

    /// Stops recording synchronously and kicks off transcription in a background Task.
    /// Called from both the UI button and the hotkey-up event.
    private func stopRecordingAndTranscribe() {
        isKeyDown = false
        recordingIndicator.hide()
        mediaPlaybackController.resumeIfNeeded()
        guard state == .recording else { return }

        guard let audioURL = audioRecorder.stopRecording() else {
            state = .error("No audio recorded")
            resetAfterDelay()
            return
        }

        state = .transcribing
        Logger.app.info("Push-to-talk: transcribing...")

        Task { await processTranscription(audioURL: audioURL) }
    }

    // MARK: - Transcription + Action (async)

    private func processTranscription(audioURL: URL) async {
        do {
            let transcriptionStart = ContinuousClock.now
            let text = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
            let elapsed = transcriptionStart.duration(to: .now)
            Logger.app.info("Transcribed in \(elapsed): \(text)")

            try? FileManager.default.removeItem(at: audioURL)

            guard !text.isEmpty else {
                state = .error("No speech detected")
                resetAfterDelay()
                return
            }

            let mode = settings.activeMode
            let terminatedText = mode.terminatorTemplateEnabled
                ? Self.applyTerminator(text, terminator: mode.terminatorTemplate)
                : text

            state = .executing
            Logger.app.info("Push-to-talk: executing action")

            let action = makeAction()

            // For paste action, restore focus to the previous app first
            if settings.activeMode.actionType == .paste, let previousApp = previousActiveApp {
                previousApp.activate()
                // Brief delay for the target app to gain focus before simulating Cmd+V
                try await Task.sleep(for: .milliseconds(100))
            }

            try await action.execute(text: terminatedText)
            state = .idle
            Logger.app.info("Push-to-talk: complete")
        } catch {
            state = .error(error.localizedDescription)
            Logger.app.error("Push-to-talk failed: \(error)")
            resetAfterDelay()
        }
    }

    private func makeAction() -> any PostTranscriptionAction {
        let mode = settings.activeMode
        switch mode.actionType {
        case .paste:
            return PasteAction()
        case .bash:
            return BashAction(commandTemplate: mode.bashCommand)
        }
    }

    // MARK: - Terminator

    private static let sentenceEndingPunctuation: Set<Character> = [".", "?", "!"]

    /// Appends the mode's terminator to the transcription if it doesn't already
    /// end with sentence-ending punctuation. Converts `<space>` and `<newline>`
    /// tokens to actual characters.
    private static func applyTerminator(_ text: String, terminator: String) -> String {
        guard !terminator.isEmpty else { return text }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = trimmed.last else { return text }

        if sentenceEndingPunctuation.contains(lastChar) {
            return trimmed
        }

        let resolved = terminator
            .replacingOccurrences(of: "<dot>", with: ".")
            .replacingOccurrences(of: "<space>", with: " ")
            .replacingOccurrences(of: "<newline>", with: "\n")

        return trimmed + resolved
    }

    // MARK: - Constants

    private static let errorDisplayDuration: Duration = .seconds(3)

    private func resetAfterDelay() {
        Task {
            try? await Task.sleep(for: Self.errorDisplayDuration)
            if case .error = state {
                state = .idle
            }
        }
    }

    var isHotkeyRegistered: Bool { hotkeyManager.isRegistered }

    var menuBarIcon: String {
        switch state {
        case .idle: "waveform.circle"
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle"
        case .executing: "arrow.right.circle"
        case .error: "exclamationmark.circle"
        }
    }
}
