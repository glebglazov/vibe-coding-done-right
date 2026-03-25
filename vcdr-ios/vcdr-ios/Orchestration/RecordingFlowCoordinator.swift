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

    // MARK: - Constants
    private static let initPollInterval: Duration = .milliseconds(200)
    /// Delay after posting Darwin notification before suspending,
    /// to ensure the notification is delivered to the keyboard extension
    private static let suspendDelay: Duration = .milliseconds(300)

    var isRecording: Bool { audioRecorder.isRecording }
    var audioLevels: [Float] { audioRecorder.audioLevels }

    func initializeModel() async {
        state = .initializing
        initProgress = "Downloading model..."

        // Poll init phase for UI updates
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

            // If a deep link arrived while model was loading, start recording now
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

    /// Called when a deep link arrives. If the model isn't ready yet, queues the request.
    func handleRecordDeepLink() async {
        switch state {
        case .idle, .initializing:
            pendingRecordRequest = true
            Logger.app.info("Record request queued — model still initializing")
        case .ready:
            await startRecording()
        case .recording:
            // Already recording, ignore duplicate deep link
            break
        case .transcribing:
            // Busy transcribing, ignore
            break
        case .complete, .error:
            await startRecording()
        }
    }

    func startRecording() async {
        guard await transcriptionProvider.isReady else {
            state = .error("Model not ready")
            return
        }

        let started = await audioRecorder.startRecording()
        if started {
            state = .recording
        } else {
            state = .error("Failed to start recording — check microphone permission")
        }
    }

    func stopAndTranscribe() async {
        guard let audioURL = audioRecorder.stopRecording() else {
            state = .error("No recording to process")
            return
        }

        state = .transcribing

        do {
            let text = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
            try? FileManager.default.removeItem(at: audioURL)

            // Write result to App Group for keyboard extension
            SharedConstants.sharedDefaults.set(text, forKey: SharedConstants.transcriptionResultKey)

            // Signal keyboard extension via Darwin notification
            DarwinNotificationCenter.post(SharedConstants.darwinNotificationName)

            state = .complete(text)
            Logger.app.info("Transcription complete: \(text.prefix(50))...")

            // Small delay to ensure the notification is delivered, then suspend
            try? await Task.sleep(for: Self.suspendDelay)
            suspendApp()
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            state = .error("Transcription failed: \(error.localizedDescription)")
            Logger.app.error("Transcription failed: \(error)")
        }
    }

    func reset() {
        state = .ready
    }

    /// Clear any stale transcription results left from a previous session.
    /// Prevents ghost insertions when the keyboard extension reads old data.
    func cleanupStaleResults() {
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.transcriptionResultKey)
    }

    // MARK: - Private

    /// Move the app to the background so the user returns to their previous app.
    /// The system "Back to [App]" banner is the supported mechanism for this.
    /// The suspend selector is undocumented but widely used and not rejected by App Review.
    private func suspendApp() {
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
    }
}
