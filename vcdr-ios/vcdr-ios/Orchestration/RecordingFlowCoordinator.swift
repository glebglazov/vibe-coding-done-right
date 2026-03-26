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

    func setupBackgroundCommandListener() {
        Logger.app.info("[Coordinator] Setting up background command listener")
        DarwinNotificationCenter.observe(
            SharedConstants.commandNotificationName,
            localName: .darwinCommand
        )
        NotificationCenter.default.addObserver(
            forName: .darwinCommand,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Logger.app.info("[Coordinator] Darwin command notification received")
            guard let self else {
                Logger.app.warning("[Coordinator] Self is nil in command handler")
                return
            }
            Task { @MainActor in
                await self.handleCommand()
            }
        }
    }

    private func handleCommand() async {
        let rawCommand = SharedConstants.sharedDefaults.string(forKey: SharedConstants.commandKey)
        Logger.app.info("[Coordinator] handleCommand — rawCommand=\(rawCommand ?? "nil")")

        guard let rawCommand,
              let command = RecordingCommand(rawValue: rawCommand) else {
            Logger.app.warning("[Coordinator] handleCommand — no valid command found, skipping")
            return
        }

        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.commandKey)
        Logger.app.info("[Coordinator] Processing command: \(rawCommand), current state: \(String(describing: self.state))")

        switch command {
        case .startRecording:
            await startRecording()
        case .stopRecording:
            await stopAndTranscribe()
        }
    }

    // MARK: - Activate + Bounce Back

    func activateAndBounceBack(sourceApp: String?) async {
        Logger.app.info("[Coordinator] activateAndBounceBack — sourceApp=\(sourceApp ?? "nil"), current state=\(String(describing: self.state))")

        // Initialize model if not ready (first launch)
        let isReady = await transcriptionProvider.isReady
        Logger.app.info("[Coordinator] Model isReady=\(isReady)")
        if !isReady {
            Logger.app.info("[Coordinator] Model not ready, initializing...")
            await initializeModel()
        }

        do {
            try audioRecorder.activateSession()
            SharedConstants.sharedDefaults.set(true, forKey: SharedConstants.audioSessionActiveKey)
            writeState(.idle)
            Logger.app.info("[Coordinator] Audio session activated successfully")
        } catch {
            Logger.app.error("[Coordinator] Failed to activate audio session: \(error)")
            return
        }

        // Process any pending command that the keyboard sent alongside the deep link.
        Logger.app.info("[Coordinator] Checking for pending command after session activation...")
        await handleCommand()

        // Look up the originating app's URL scheme and bounce back
        if let bundleID = sourceApp,
           let scheme = AppURLSchemes.urlScheme(forBundleID: bundleID),
           let url = URL(string: scheme) {
            Logger.app.info("[Coordinator] Bouncing back to \(bundleID) via \(scheme)")
            await UIApplication.shared.open(url)
        } else {
            // User taps the iOS "Back to [App]" link in the top-left status bar
            Logger.app.info("[Coordinator] No known URL scheme for sourceApp=\(sourceApp ?? "nil") — user taps Back to return")
        }
    }

    // MARK: - Model Initialization

    func initializeModel() async {
        Logger.app.info("[Coordinator] initializeModel starting")
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
            Logger.app.info("[Coordinator] Model initialized successfully")

            if pendingRecordRequest {
                pendingRecordRequest = false
                Logger.app.info("[Coordinator] Processing pending record request")
                await startRecording()
            }
        } catch {
            pollTask.cancel()
            state = .error("Model initialization failed: \(error.localizedDescription)")
            Logger.app.error("[Coordinator] Model init failed: \(error)")
        }
    }

    // MARK: - Recording

    func handleRecordDeepLink() async {
        Logger.app.info("[Coordinator] handleRecordDeepLink — state=\(String(describing: self.state))")
        switch state {
        case .idle, .initializing:
            pendingRecordRequest = true
            Logger.app.info("[Coordinator] Record request queued — model still initializing")
        case .ready:
            await startRecording()
        case .recording:
            Logger.app.info("[Coordinator] Already recording, ignoring")
            break
        case .transcribing:
            Logger.app.info("[Coordinator] Busy transcribing, ignoring")
            break
        case .complete, .error:
            await startRecording()
        }
    }

    func startRecording() async {
        Logger.app.info("[Coordinator] startRecording — sessionActive=\(self.audioRecorder.isSessionActive)")

        let modelReady = await transcriptionProvider.isReady
        Logger.app.info("[Coordinator] startRecording — modelReady=\(modelReady)")
        guard modelReady else {
            state = .error("Model not ready")
            writeState(.idle)
            Logger.app.error("[Coordinator] startRecording failed — model not ready")
            return
        }

        Logger.app.info("[Coordinator] Calling audioRecorder.startRecording()...")
        let started = await audioRecorder.startRecording()
        Logger.app.info("[Coordinator] audioRecorder.startRecording() returned \(started)")

        if started {
            state = .recording
            writeState(.recording)
            Logger.app.info("[Coordinator] Recording started successfully")
        } else {
            state = .error("Failed to start recording — check microphone permission")
            writeState(.idle)
            Logger.app.error("[Coordinator] Recording failed to start")
        }
    }

    func stopAndTranscribe() async {
        Logger.app.info("[Coordinator] stopAndTranscribe")
        guard let audioURL = audioRecorder.stopRecording() else {
            state = .error("No recording to process")
            writeState(.idle)
            Logger.app.error("[Coordinator] stopRecording returned nil")
            return
        }

        state = .transcribing
        writeState(.transcribing)
        Logger.app.info("[Coordinator] Transcribing \(audioURL.lastPathComponent)...")

        do {
            let rawText = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
            try? FileManager.default.removeItem(at: audioURL)

            let text = TextPostProcessor.process(rawText)
            Logger.app.info("[Coordinator] Transcription result: \(text.prefix(80))...")

            SharedConstants.sharedDefaults.set(text, forKey: SharedConstants.transcriptionResultKey)
            DarwinNotificationCenter.post(SharedConstants.transcriptionNotificationName)

            state = .complete(text)
            writeState(.idle)
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            state = .error("Transcription failed: \(error.localizedDescription)")
            writeState(.idle)
            Logger.app.error("[Coordinator] Transcription failed: \(error)")
        }
    }

    func reset() {
        state = .ready
        writeState(.idle)
    }

    func cleanupStaleResults() {
        Logger.app.info("[Coordinator] Cleaning up stale results")
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.transcriptionResultKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.commandKey)
    }

    // MARK: - State Broadcast

    private func writeState(_ recordingState: RecordingState) {
        Logger.app.info("[Coordinator] writeState(\(recordingState.rawValue))")
        SharedConstants.sharedDefaults.set(recordingState.rawValue, forKey: SharedConstants.stateKey)
        DarwinNotificationCenter.post(SharedConstants.stateNotificationName)
    }
}
