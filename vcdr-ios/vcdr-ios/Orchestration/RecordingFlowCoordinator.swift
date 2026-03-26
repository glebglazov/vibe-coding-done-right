import Foundation
import OSLog
import UIKit

@MainActor
@Observable
final class RecordingFlowCoordinator {
    enum State: Equatable {
        case idle
        case initializing
        case ready
        case recording
        case transcribing
        case complete(String)
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var initProgress: String = ""

    private let audioRecorder = AudioRecorder()
    private let transcriptionProvider = ParakeetProvider()

    /// When true, recording starts automatically once the model is ready
    private var pendingRecordRequest = false

    /// When true, the current recording was started via deep link and should auto-return to host app
    private var launchedViaDeepLink = false

    // MARK: - Constants
    private static let initPollInterval: Duration = .milliseconds(200)
    /// Delay before bouncing back to host app — allows audio session to fully activate
    private static let bounceBackDelay: Duration = .milliseconds(300)
    /// Delay after posting transcription result before returning to host app
    private static let returnToHostDelay: Duration = .milliseconds(500)

    var isRecording: Bool { audioRecorder.isRecording }
    var audioLevels: [Float] { audioRecorder.audioLevels }

    func initializeModel() async {
        state = .initializing
        initProgress = "Downloading model..."

        let pollTask = Task {
            while !Task.isCancelled {
                let phase = await transcriptionProvider.initPhase
                switch phase {
                case .notStarted: initProgress = "Preparing..."
                case .downloading: initProgress = "Downloading model..."
                case .compiling: initProgress = "Compiling model..."
                case .ready: return
                }
                try? await Task.sleep(for: Self.initPollInterval)
            }
        }

        do {
            try await transcriptionProvider.initialize()
            pollTask.cancel()
            state = .ready
            initProgress = "Ready"
            Logger.app.info("Parakeet model initialized")

            if pendingRecordRequest {
                pendingRecordRequest = false
                await startRecordingAndBounceBack()
            }
        } catch {
            pollTask.cancel()
            state = .error("Model initialization failed: \(error.localizedDescription)")
            Logger.app.error("Model init failed: \(error)")
        }
    }

    /// Called when a deep link arrives. Starts recording and bounces back to host app.
    func handleRecordDeepLink() async {
        switch state {
        case .idle, .initializing:
            pendingRecordRequest = true
            Logger.app.info("Record request queued — model still initializing")
        case .ready, .complete, .error:
            await startRecordingAndBounceBack()
        case .recording, .transcribing:
            // Already busy, ignore
            break
        }
    }

    /// Starts recording in the foreground (manual use from the app UI).
    func startRecording() async {
        guard await transcriptionProvider.isReady else {
            state = .error("Model not ready")
            return
        }

        launchedViaDeepLink = false
        let started = await audioRecorder.startRecording()
        if started {
            state = .recording
            writeState(.recording)
        } else {
            state = .error("Failed to start recording — check microphone permission")
        }
    }

    /// Starts recording and immediately bounces back to the host app.
    /// Recording continues in the background via UIBackgroundModes:audio.
    /// Sets the audioSessionActive flag so subsequent recordings skip the flash.
    private func startRecordingAndBounceBack() async {
        guard await transcriptionProvider.isReady else {
            state = .error("Model not ready")
            return
        }

        launchedViaDeepLink = true
        let started = await audioRecorder.startRecording()
        if started {
            state = .recording
            writeState(.recording)

            // Mark audio session as active — keyboard will send commands instead of deep-linking
            SharedConstants.sharedDefaults.set(true, forKey: SharedConstants.audioSessionActiveKey)

            // Brief delay to ensure audio session is fully active before backgrounding
            try? await Task.sleep(for: Self.bounceBackDelay)

            await returnToHostApp()
        } else {
            state = .error("Failed to start recording — check microphone permission")
        }
    }

    /// Stops recording and transcribes. Called from background via command listener.
    func stopAndTranscribe() async {
        guard let audioURL = audioRecorder.stopRecording() else {
            state = .error("No recording to process")
            writeState(.idle)
            return
        }

        state = .transcribing
        writeState(.transcribing)

        do {
            let rawText = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
            try? FileManager.default.removeItem(at: audioURL)

            let text = TextPostProcessor.process(rawText)

            // Only send result to keyboard extension when recording was initiated via deep link
            if launchedViaDeepLink {
                SharedConstants.sharedDefaults.set(text, forKey: SharedConstants.transcriptionResultKey)
                DarwinNotificationCenter.post(SharedConstants.transcriptionNotificationName)
            }

            state = .complete(text)
            writeState(.idle)
            Logger.app.info("Transcription complete: \(text.prefix(50))...")

            // Only auto-return when recording was initiated via deep link from keyboard
            if launchedViaDeepLink {
                try? await Task.sleep(for: Self.returnToHostDelay)
                await returnToHostApp()
            }
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            state = .error("Transcription failed: \(error.localizedDescription)")
            writeState(.idle)
            Logger.app.error("Transcription failed: \(error)")
        }
    }

    func reset() {
        state = .ready
        writeState(.idle)
    }

    func cleanupStaleResults() {
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.transcriptionResultKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.commandKey)
        // Audio session doesn't survive app kill — clear the flag so keyboard knows
        // to deep-link (flash) on next recording to re-activate it
        SharedConstants.sharedDefaults.set(false, forKey: SharedConstants.audioSessionActiveKey)
        writeState(.idle)
    }

    // MARK: - Background Command Listener

    /// Listens for commands from the keyboard extension via Darwin notifications.
    func setupCommandListener() {
        DarwinNotificationCenter.observe(
            SharedConstants.commandNotificationName,
            localName: .darwinCommand
        )
        NotificationCenter.default.addObserver(
            forName: .darwinCommand,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.handleCommand()
            }
        }
    }

    private func handleCommand() async {
        guard let rawCommand = SharedConstants.sharedDefaults.string(
            forKey: SharedConstants.commandKey),
              let command = RecordingCommand(rawValue: rawCommand)
        else { return }

        // Clear command so it's not re-processed
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.commandKey)

        switch command {
        case .startRecording:
            Logger.app.info("Received start command from keyboard (session already active)")
            await startRecording()
        case .stopRecording:
            Logger.app.info("Received stop command from keyboard")
            await stopAndTranscribe()
        }
    }

    // MARK: - State Publishing

    /// Writes recording state to App Group so the keyboard extension can read it.
    private func writeState(_ recordingState: RecordingState) {
        SharedConstants.sharedDefaults.set(recordingState.rawValue, forKey: SharedConstants.stateKey)
        DarwinNotificationCenter.post(SharedConstants.stateNotificationName)
    }

    // MARK: - Host App Return

    /// Returns to the host app using the URL scheme looked up from the bundle ID
    /// that the keyboard extension wrote to App Group.
    private func returnToHostApp() async {
        guard let hostBundleID = SharedConstants.sharedDefaults.string(
            forKey: SharedConstants.hostBundleIDKey)
        else {
            Logger.app.info("No host bundle ID — user must return manually")
            return
        }

        guard let url = AppURLSchemes.url(forBundleID: hostBundleID) else {
            Logger.app.info("No URL scheme mapping for \(hostBundleID)")
            return
        }

        Logger.app.info("Returning to \(hostBundleID) via \(url.absoluteString)")
        await UIApplication.shared.open(url)
    }
}
