import Foundation
import OSLog

/// AI processing + retry: builds the `TranscriptProcessor` used by a recording
/// run and replays the AI chain for the Done-page retry action.
extension RecordingFlowCoordinator {

    func makeTranscriptProcessor() -> TranscriptProcessor {
        TranscriptProcessor(
            makeAIProvider: { AIProviderFactory.make() },
            onAIProcessingStatus: { [weak self] status in
                self?.aiProcessingStatus = AIProcessingStatus(status)
                if status == .processing {
                    self?.transcribingMessage = "Enhancing with AI..."
                }
            },
            onAIInputText: { [weak self] text in
                self?.aiInputText = text
            }
        )
    }

    /// Retries the AI processing request with the previously sent text.
    /// Replays the full chain: primary provider (with retries) + AFM fallback.
    func retryAIProcessing() {
        guard !aiInputText.isEmpty else { return }
        aiRetryTask?.cancel()
        aiRetryTask = Task {
            // Cross-process staleness guard — pick up any keyboard-side flip
            // before retry dispatch and again before finalization.
            resyncSettingsFromSharedDefaults()
            let initialSettings = TranscriptProcessor.Settings(
                promptMode: selectedPromptMode,
                textStyle: currentTextStyle,
                hasAICapability: AIProcessingSettings.hasAICapability
            )
            let aiResult = await makeTranscriptProcessor().processWithAI(
                localText: aiInputText,
                settings: initialSettings,
                spellingHints: SpellingHints(substitutionStore.substitutions)
            )
            guard !Task.isCancelled else { return }
            // Pick up any style change the user made during the retry, then finalize.
            resyncSettingsFromSharedDefaults()
            let finalSettings = TranscriptProcessor.Settings(
                promptMode: selectedPromptMode,
                textStyle: currentTextStyle,
                hasAICapability: AIProcessingSettings.hasAICapability
            )
            state = .complete(TranscriptProcessor.finalize(aiResult, settings: finalSettings))
        }
    }
}

private extension RecordingFlowCoordinator.AIProcessingStatus {
    init(_ status: TranscriptProcessor.AIProcessingStatus) {
        switch status {
        case .idle: self = .idle
        case .processing: self = .processing
        case .timedOut: self = .timedOut
        case .completed: self = .completed
        case .error(let message): self = .error(message)
        }
    }
}
