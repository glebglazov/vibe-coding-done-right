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

    private var previousActiveApp: NSRunningApplication?
    private var isKeyDown = false
    private let recordingIndicator = RecordingIndicatorPanel()

    init(settings: AppSettings, transcriptionProvider: ParakeetProvider) {
        self.settings = settings
        self.transcriptionProvider = transcriptionProvider
        self.audioRecorder = AudioRecorder()
        self.hotkeyManager = GlobalHotkeyManager()
    }

    func setupHotkey() {
        let keyCode = CGKeyCode(settings.hotkeyKeyCode)
        let modifiers = CGEventFlags(rawValue: settings.hotkeyModifiers)

        hotkeyManager.onKeyDown = { [weak self] in
            Task { @MainActor in
                await self?.onHotkeyDown()
            }
        }
        hotkeyManager.onKeyUp = { [weak self] in
            Task { @MainActor in
                await self?.onHotkeyUp()
            }
        }

        _ = hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
    }

    func updateHotkey() {
        setupHotkey()
    }

    private func onHotkeyDown() async {
        // Allow retrying from error state immediately
        if case .error = state {
            state = .idle
        }

        guard state == .idle else {
            Logger.app.warning("Hotkey pressed but not idle (state: \(String(describing: self.state)))")
            return
        }

        isKeyDown = true
        previousActiveApp = NSWorkspace.shared.frontmostApplication

        let started = await audioRecorder.startRecording()
        if started {
            state = .recording
            recordingIndicator.show()
            Logger.app.info("Push-to-talk: recording started")

            // If key was released while we were starting, immediately stop
            if !isKeyDown {
                Logger.app.info("Key released during setup, stopping immediately")
                await onHotkeyUp()
            }
        } else {
            isKeyDown = false
            state = .error("Failed to start recording")
            Logger.app.error("Push-to-talk: failed to start recording")
            resetAfterDelay()
        }
    }

    private func onHotkeyUp() async {
        isKeyDown = false
        recordingIndicator.hide()
        guard state == .recording else { return }

        guard let audioURL = audioRecorder.stopRecording() else {
            state = .error("No audio recorded")
            resetAfterDelay()
            return
        }

        state = .transcribing
        Logger.app.info("Push-to-talk: transcribing...")

        do {
            let transcriptionStart = ContinuousClock.now
            let text = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
            let elapsed = transcriptionStart.duration(to: .now)
            Logger.app.info("Transcribed in \(elapsed): \(text)")

            // Clean up audio file
            try? FileManager.default.removeItem(at: audioURL)

            guard !text.isEmpty else {
                state = .error("No speech detected")
                resetAfterDelay()
                return
            }

            state = .executing
            Logger.app.info("Push-to-talk: executing action")

            let action = makeAction()

            // For paste action, restore focus to the previous app first
            if settings.actionType == .paste, let previousApp = previousActiveApp {
                previousApp.activate()
                try await Task.sleep(for: .milliseconds(100))
            }

            try await action.execute(text: text)
            state = .idle
            Logger.app.info("Push-to-talk: complete")
        } catch {
            state = .error(error.localizedDescription)
            Logger.app.error("Push-to-talk failed: \(error)")
            resetAfterDelay()
        }
    }

    private func makeAction() -> any PostTranscriptionAction {
        switch settings.actionType {
        case .paste:
            PasteAction()
        case .bash:
            BashAction(commandTemplate: settings.bashCommand)
        }
    }

    private func resetAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(3))
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
