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

    let audioRecorder = AudioRecorder()
    private let transcriptionProvider = ParakeetProvider()

    /// When true, recording starts automatically once the model is ready
    private var pendingRecordRequest = false

    // MARK: - Constants
    private static let initPollInterval: Duration = .milliseconds(200)

    var isRecording: Bool { audioRecorder.isRecording }
    var audioLevels: [Float] { audioRecorder.audioLevels }

    // MARK: - Background Command Listener

    /// Sets up the Darwin notification observer for commands from the keyboard extension.
    /// Must be called once at app startup.
    func setupBackgroundCommandListener() {
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
        guard let rawCommand = SharedConstants.sharedDefaults.string(forKey: SharedConstants.commandKey),
              let command = RecordingCommand(rawValue: rawCommand) else { return }

        // Clear the command so it's not re-processed
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.commandKey)

        Logger.app.info("Received command from keyboard: \(rawCommand)")

        switch command {
        case .startRecording:
            await startRecording()
        case .stopRecording:
            await stopAndTranscribe()
        }
    }

    // MARK: - Activate + Bounce Back

    /// Called from vcdr-ios://activate deep link.
    /// Activates the audio session (requires foreground), then opens the originating
    /// app's URL to bounce the user back. The audio session persists in the background.
    func activateAndBounceBack(sourceApp: String?) async {
        // Initialize model if not ready (first launch)
        let isReady = await transcriptionProvider.isReady
        if !isReady {
            await initializeModel()
        }

        do {
            try audioRecorder.activateSession()
            SharedConstants.sharedDefaults.set(true, forKey: SharedConstants.audioSessionActiveKey)
            writeState(.idle)
            Logger.app.info("Audio session activated, ready for background recording")
        } catch {
            Logger.app.error("Failed to activate audio session: \(error)")
            return
        }

        // Process any pending command that the keyboard sent alongside the deep link.
        // The Darwin notification may have arrived before the session was active,
        // so we handle it here after activation to avoid a race condition.
        await handleCommand()

        // Look up the originating app's URL scheme and bounce back
        if let bundleID = sourceApp,
           let scheme = AppURLSchemes.urlScheme(forBundleID: bundleID),
           let url = URL(string: scheme) {
            Logger.app.info("Bouncing back to \(bundleID) via \(scheme)")
            await UIApplication.shared.open(url)
        } else {
            Logger.app.info("Unknown source app (\(sourceApp ?? "nil")) — user must tap Back manually")
        }
    }

    // MARK: - Model Initialization

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
                await startRecording()
            }
        } catch {
            pollTask.cancel()
            state = .error("Model initialization failed: \(error.localizedDescription)")
            Logger.app.error("Model init failed: \(error)")
        }
    }

    // MARK: - Recording

    /// Called when a deep link arrives (legacy vcdr-ios://record path).
    func handleRecordDeepLink() async {
        switch state {
        case .idle, .initializing:
            pendingRecordRequest = true
            Logger.app.info("Record request queued — model still initializing")
        case .ready:
            await startRecording()
        case .recording:
            break
        case .transcribing:
            break
        case .complete, .error:
            await startRecording()
        }
    }

    func startRecording() async {
        guard await transcriptionProvider.isReady else {
            state = .error("Model not ready")
            writeState(.idle)
            return
        }

        let started = await audioRecorder.startRecording()
        if started {
            state = .recording
            writeState(.recording)
        } else {
            state = .error("Failed to start recording — check microphone permission")
            writeState(.idle)
        }
    }

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

            // Write result to App Group for keyboard extension
            SharedConstants.sharedDefaults.set(text, forKey: SharedConstants.transcriptionResultKey)

            // Signal keyboard extension via Darwin notification
            DarwinNotificationCenter.post(SharedConstants.transcriptionNotificationName)

            state = .complete(text)
            writeState(.idle)
            Logger.app.info("Transcription complete: \(text.prefix(50))...")
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
    }

    // MARK: - State Broadcast

    private func writeState(_ recordingState: RecordingState) {
        SharedConstants.sharedDefaults.set(recordingState.rawValue, forKey: SharedConstants.stateKey)
        DarwinNotificationCenter.post(SharedConstants.stateNotificationName)
    }
}
