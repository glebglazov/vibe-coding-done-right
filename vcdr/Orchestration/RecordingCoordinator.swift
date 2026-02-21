import Foundation
import AppKit
import OSLog

@Observable
final class RecordingCoordinator {
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
    private let recordingIndicator = RecordingIndicatorPanel()
    private let selectionCapturer = SelectionCapturer()
    private var capturedSelection: String?

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
                await self?.onHotkeyDown(fromHotkey: true)
            }
        }
        // Called synchronously from the CGEvent tap callback (no GCD, no Task).
        // This is critical: DispatchQueue.main.async and MainActor Tasks can be
        // delayed by seconds when the executor is stalled, but the CGEvent tap
        // callback always fires promptly on the main run loop.
        hotkeyManager.onKeyUp = { [weak self] in
            self?.stopRecordingAndTranscribe()
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

    private func onHotkeyDown(fromHotkey: Bool = false) async {
        Logger.app.debug("[onHotkeyDown] enter — fromHotkey=\(fromHotkey), state=\(String(describing: self.state))")

        if case .error = state {
            state = .idle
        }

        guard state == .idle else {
            Logger.app.warning("Hotkey pressed but not idle (state: \(String(describing: self.state)))")
            // Buzz the indicator to signal "busy, can't start now"
            if state == .transcribing || state == .executing {
                recordingIndicator.buzz()
            }
            return
        }

        Logger.app.debug("[onHotkeyDown] awaiting transcriptionProvider.isReady")
        guard await transcriptionProvider.isReady else {
            Logger.app.warning("Hotkey pressed but transcription model not loaded yet")
            state = .error("Model still loading...")
            resetAfterDelay()
            return
        }

        previousActiveApp = NSWorkspace.shared.frontmostApplication

        // Capture any highlighted text in the frontmost app before recording starts
        capturedSelection = await selectionCapturer.capture()

        // Snapshot audio output state BEFORE recording starts — AVAudioRecorder
        // can activate the output device, causing false positives in the "is audio
        // playing" check (e.g. when Xcode keeps the audio device active).
        if settings.audioSettings.pauseMediaDuringRecording {
            mediaPlaybackController.snapshotAudioState()
        }

        Logger.app.debug("[onHotkeyDown] awaiting audioRecorder.startRecording()")
        let started = await audioRecorder.startRecording()
        Logger.app.debug("[onHotkeyDown] startRecording returned \(started)")
        if started {
            state = .recording
            recordingIndicator.show()
            if settings.audioSettings.pauseMediaDuringRecording {
                mediaPlaybackController.pauseIfNeeded()
            }
            Logger.app.info("Push-to-talk: recording started")

            // If the hotkey was released while we were awaiting startRecording(),
            // the synchronous onKeyUp callback may have already called
            // stopRecordingAndTranscribe() — but if state was still .idle at that point,
            // the stop was a no-op. Check isHotkeyActive to catch this race condition.
            if fromHotkey && !hotkeyManager.isHotkeyActive {
                Logger.app.debug("[onHotkeyDown] key already released (isHotkeyActive=false), stopping")
                stopRecordingAndTranscribe()
            }
        } else {
            state = .error("Failed to start recording")
            Logger.app.error("Push-to-talk: failed to start recording")
            resetAfterDelay()
        }
    }

    // MARK: - Recording Stop (synchronous for immediate UI feedback)

    /// Stops recording synchronously and kicks off transcription in a background Task.
    /// Called from both the UI button and the hotkey-up event.
    private func stopRecordingAndTranscribe() {
        Logger.app.debug("[stopRecordingAndTranscribe] enter — state=\(String(describing: self.state))")
        mediaPlaybackController.resumeIfNeeded()
        guard state == .recording else {
            Logger.app.debug("[stopRecordingAndTranscribe] state is not .recording, returning early")
            // Only hide the indicator if we're NOT in a processing state —
            // during transcribing/executing the indicator should stay visible
            if state != .transcribing && state != .executing {
                recordingIndicator.hide()
            }
            return
        }

        guard let audioURL = audioRecorder.stopRecording() else {
            state = .error("No audio recorded")
            recordingIndicator.update(phase: .error)
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            resetAfterDelay()
            return
        }

        state = .transcribing
        recordingIndicator.update(phase: .processing)
        Logger.app.info("Push-to-talk: transcribing...")

        Task { @MainActor in await self.processTranscription(audioURL: audioURL) }
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
                capturedSelection = nil
                state = .error("No speech detected")
                recordingIndicator.update(phase: .error)
                dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
                resetAfterDelay()
                return
            }

            let mode = settings.activeMode
            let terminatedText = mode.terminatorTemplateEnabled
                ? Self.applyTerminator(text, terminator: mode.terminatorTemplate)
                : text

            let finalText = (mode.actionType == .bash && mode.systemPromptEnabled && !mode.systemPrompt.isEmpty)
                ? mode.systemPrompt + "\n\n" + terminatedText
                : terminatedText

            // Append captured selection text if the user had text highlighted
            let textWithSelection: String
            if let selection = capturedSelection {
                textWithSelection = finalText + "\n\n" + selection
            } else {
                textWithSelection = finalText
            }
            capturedSelection = nil

            state = .executing
            Logger.app.info("Push-to-talk: executing action")

            let action = makeAction()

            // For paste action, restore focus to the previous app first
            if settings.activeMode.actionType == .paste, let previousApp = previousActiveApp {
                previousApp.activate()
                // Brief delay for the target app to gain focus before simulating Cmd+V
                try await Task.sleep(for: .milliseconds(100))
            }

            let output = try await action.execute(text: textWithSelection)

            // For bash actions, always copy stdout to clipboard for easy re-use.
            // Only simulate Cmd+V paste if the "paste output" option is enabled.
            if mode.actionType == .bash,
               let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(trimmedOutput, forType: .string)
                Logger.app.info("Script output copied to clipboard")

                if mode.pasteScriptOutput {
                    let pasteAction = PasteAction()
                    try await pasteAction.execute(text: trimmedOutput)
                }
            }

            state = .idle
            recordingIndicator.update(phase: .success)
            dismissIndicatorAfterDelay(Self.successIndicatorDuration)
            Logger.app.info("Push-to-talk: complete")
        } catch {
            capturedSelection = nil
            state = .error(error.localizedDescription)
            recordingIndicator.update(phase: .error)
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
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

    /// Appends the mode's terminator to the transcription, separating punctuation
    /// from spacing. If the text already ends with sentence-ending punctuation,
    /// only the spacing portion of the terminator is appended (e.g. `"Hello."` with
    /// terminator `<dot><space>` becomes `"Hello. "`, not `"Hello."`).
    private static func applyTerminator(_ text: String, terminator: String) -> String {
        guard !terminator.isEmpty else { return text }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.last != nil else { return text }

        let resolved = terminator
            .replacingOccurrences(of: "<dot>", with: ".")
            .replacingOccurrences(of: "<space>", with: " ")
            .replacingOccurrences(of: "<newline>", with: "\n")

        // Split resolved terminator into leading punctuation and trailing spacing.
        // If text already ends with punctuation, skip the punctuation part but
        // still append spacing so consecutive dictations are properly separated.
        let punctuationPrefix = String(resolved.prefix(while: { sentenceEndingPunctuation.contains($0) }))
        let spacingSuffix = String(resolved.dropFirst(punctuationPrefix.count))

        if sentenceEndingPunctuation.contains(trimmed.last!) {
            return trimmed + spacingSuffix
        }

        return trimmed + resolved
    }

    // MARK: - Constants

    private static let errorDisplayDuration: Duration = .seconds(3)
    private static let successIndicatorDuration: Duration = .seconds(2)
    private static let errorIndicatorDuration: Duration = .seconds(2)

    private func resetAfterDelay() {
        Task {
            try? await Task.sleep(for: Self.errorDisplayDuration)
            if case .error = state {
                state = .idle
            }
        }
    }

    private func dismissIndicatorAfterDelay(_ duration: Duration) {
        Task {
            try? await Task.sleep(for: duration)
            // Only dismiss if still showing a terminal phase — a new recording
            // may have started and reset the phase to .recording
            let phase = recordingIndicator.currentPhase
            if phase == .success || phase == .error {
                recordingIndicator.hide()
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
