import Foundation
import OSLog

extension RecordingCoordinator {

    // MARK: - Constants

    static let errorIndicatorDuration: Duration = .seconds(10)

    // MARK: - Transcription Processing

    func processTranscription(audioURL: URL) async {
        do {
            let transcriptionStart = ContinuousClock.now
            let rawText = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
            try Task.checkCancellation()
            let elapsed = transcriptionStart.duration(to: .now)
            Logger.app.info("Transcribed in \(elapsed): \(rawText)")

            let cleanedText = settings.removeFillerWords ? FillerWordRemover.remove(from: rawText) : rawText
            let text = settings.terminatorTemplateEnabled
                ? Mode.applyTerminator(cleanedText, terminator: settings.terminatorTemplate)
                : cleanedText

            try? FileManager.default.removeItem(at: audioURL)

            var run = recordingRun ?? RecordingRunState()
            if let captureTask = run.captureTask {
                if let captured = await captureTask.value {
                    run.captures.insert(captured, at: 0)
                }
                run.captureTask = nil
                Logger.recording.info("Captures: \(run.captures.count) items")
            }
            let hadDestinationOverride: Bool
            if let pending = pendingDestinationOverride {
                pendingDestinationOverride = nil
                hadDestinationOverride = true
                run.destinationOverrideID = pending
            } else {
                hadDestinationOverride = false
            }

            recordingRun = nil

            guard !text.isEmpty else {
                cancelHotkeyManager.isEnabled = false
                delegate?.recordingCoordinatorDidFailTranscription()
                processingTask = nil
                state = .idle
                return
            }

            let result = RecordingResult(
                text: text,
                captures: run.captures,
                previousActiveApp: run.previousActiveApp,
                destinationOverrideID: run.destinationOverrideID,
                hadDestinationOverride: hadDestinationOverride
            )

            cancelHotkeyManager.isEnabled = false
            processingTask = nil
            state = .idle
            delegate?.recordingCoordinatorDidCompleteRecording(result: result)
            Logger.app.info("Pipeline: result emitted to handler")

        } catch is CancellationError {
            processingTask = nil
            Logger.app.info("Processing task cancelled")
        } catch {
            cancelHotkeyManager.isEnabled = false
            processingTask = nil
            recordingRun = nil
            state = .error(error.localizedDescription)
            delegate?.recordingCoordinatorDidFailRecording(message: error.localizedDescription)
            Logger.app.error("Pipeline failed: \(error)")
            resetAfterDelay()
        }
    }

    // MARK: - Helpers

    func resetAfterDelay() {
        Task {
            try? await Task.sleep(for: Self.errorIndicatorDuration)
            if case .error = state {
                state = .idle
            }
        }
    }

}
