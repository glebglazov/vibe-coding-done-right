import Foundation
import OSLog

extension CaptureSession {

    /// ⇧⎋ while recording. The session is idle when this returns, so the toggle
    /// starts a new run at once. The recording goes to the finalizer, which
    /// saves its verbatim words to History; the pill says so when it knows.
    func discardRecording() {
        guard case .recording = status.phase else { return }

        let runState = run
        let audioURL = audio.stopRecording()
        let mode = settings.activeMode
        let effective = effectiveTranscription

        preparationNarrationTask?.cancel()
        preparationNarrationTask = nil
        recordingStartInstant = nil
        setStatus(.idle)
        Task { await media.resumeIfNeeded() }
        endRun()
        overrides.clearAll()
        immediateActionTask?.cancel()
        immediateActionTask = nil
        panel.dismiss()
        emit(.discarded, finalText: nil, destinationID: nil, historyConversationID: nil)
        Logger.app.info("Recording discarded")

        guard let audioURL, let runState else {
            indicator.showDiscarded(savedToHistory: false)
            return
        }

        let capture = DiscardedCapture(
            conversationID: runState.conversationID,
            audioURL: audioURL,
            provider: resolveTranscription(effective.model),
            transcriptionSettings: effective.settings,
            spellingHints: SpellingHints(substitutionStore.substitutions),
            choice: recordedOutputChoice(for: mode)
        )
        let finalization = discardedCaptures.finalize(capture)
        Task { @MainActor [weak self] in
            let outcome = await finalization.value
            self?.announce(outcome)
        }
    }

    /// The Mode and Style this run would have used, so a later "Process with
    /// AI" can use them too.
    func recordedOutputChoice(for mode: Mode) -> RecordedOutputChoice {
        let style = styleProvider()
        return RecordedOutputChoice(
            platform: .mac,
            modeID: mode.id.uuidString,
            styleID: style.id.uuidString,
            displayLabel: "\(mode.name) · \(style.name)"
        )
    }

    /// A run started since the Discard owns the pill, so the outcome of the
    /// old one is not shown over it.
    private func announce(_ outcome: DiscardOutcome) {
        guard case .idle = status.phase else { return }
        switch outcome {
        case .saved: indicator.showDiscarded(savedToHistory: true)
        case .nothingSaved: indicator.showDiscarded(savedToHistory: false)
        }
    }
}
