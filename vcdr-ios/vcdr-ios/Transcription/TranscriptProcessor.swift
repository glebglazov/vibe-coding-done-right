import Foundation
import OSLog

/// Owns transcript processing policy after speech recognition has produced
/// text: AI input construction, provider execution, deterministic finalization,
/// and the history label that describes those choices.
@MainActor
struct TranscriptProcessor {
    enum AIProcessingStatus: Equatable {
        case idle
        case processing
        case timedOut
        case completed
        case error(String)
    }

    struct Settings: Equatable {
        let promptMode: AIPromptMode
        let textStyle: TextStyle
        let hasAICapability: Bool
    }

    struct Output: Equatable {
        let transcript: String
        let processed: String?
        let finalText: String
        let historyLabel: String?
    }

    private let makeAIProvider: @MainActor (AIPromptMode) -> ProviderCascade
    private let onAIProcessingStatus: @MainActor (AIProcessingStatus) -> Void
    private let onAIInputText: @MainActor (String) -> Void

    init(
        makeAIProvider: @escaping @MainActor (AIPromptMode) -> ProviderCascade,
        onAIProcessingStatus: @escaping @MainActor (AIProcessingStatus) -> Void,
        onAIInputText: @escaping @MainActor (String) -> Void
    ) {
        self.makeAIProvider = makeAIProvider
        self.onAIProcessingStatus = onAIProcessingStatus
        self.onAIInputText = onAIInputText
    }

    func interimText(for cleanedLiveTranscript: String, settings: Settings) -> String? {
        guard !usesAI(settings), !cleanedLiveTranscript.isEmpty else { return nil }
        return Self.finalize(cleanedLiveTranscript, settings: settings)
    }

    func processFinalTranscript(
        _ cleanedText: String,
        initialSettings: Settings,
        finalSettings: @MainActor () -> Settings,
        captures: [String]
    ) async -> Output {
        let shouldUseAI = usesAI(initialSettings)
        let processedText: String
        if shouldUseAI {
            processedText = await processWithAI(
                localText: cleanedText,
                mode: initialSettings.promptMode,
                captures: captures
            )
        } else {
            processedText = cleanedText
        }

        let resolvedSettings = finalSettings()
        return Output(
            transcript: cleanedText,
            processed: shouldUseAI ? processedText : nil,
            finalText: Self.finalize(processedText, settings: resolvedSettings),
            historyLabel: Self.historyLabel(settings: resolvedSettings)
        )
    }

    func processWithAI(localText: String, settings: Settings, captures: [String]) async -> String {
        await processWithAI(localText: localText, mode: settings.promptMode, captures: captures)
    }

    static func finalize(_ text: String, settings: Settings) -> String {
        TranscriptFinalizer.finalize(text, mode: settings.promptMode, style: settings.textStyle)
    }

    static func historyLabel(settings: Settings) -> String? {
        guard settings.promptMode != .verbatim else { return nil }
        let mode = settings.promptMode.rawValue.capitalized
        return settings.promptMode.appliesStyles
            ? "\(mode) · \(settings.textStyle.rawValue.capitalized)"
            : mode
    }

    static func buildAIInput(_ localText: String, mode: AIPromptMode, captures: [String]) -> String {
        var wrapped = "<dictation>\(localText)</dictation>"
        guard mode == .assistant else { return wrapped }
        for (index, capture) in captures.enumerated() where !capture.isEmpty {
            wrapped += "\n\n<capture id=\"\(index + 1)\">\(capture)</capture>"
        }
        return wrapped
    }

    private func usesAI(_ settings: Settings) -> Bool {
        settings.promptMode != .verbatim && settings.hasAICapability
    }

    private func processWithAI(localText: String, mode: AIPromptMode, captures: [String]) async -> String {
        onAIInputText(localText)
        onAIProcessingStatus(.processing)

        let systemPrompt = BuiltInPrompts.prompt(for: mode)
        let input = Self.buildAIInput(localText, mode: mode, captures: captures)
        let provider = makeAIProvider(mode)

        Logger.ai.info("AI input [mode=\(mode.rawValue), provider=\(provider.displayName)]: \(input)")
        Logger.ai.debug("AI system prompt: \(systemPrompt.prefix(100))...")
        if mode == .assistant {
            for (index, capture) in captures.enumerated() where !capture.isEmpty {
                Logger.ai.info("Capture \(index + 1) included in AI input (\(capture.count) chars)")
            }
        }

        let startTime = ContinuousClock.now
        do {
            let result = try await provider.process(text: input, systemPrompt: systemPrompt)
            onAIProcessingStatus(.completed)
            Logger.ai.info("AI output [\(ContinuousClock.now - startTime)]: \(result)")
            return result
        } catch is ProviderCascade.AITimedOut {
            onAIProcessingStatus(.timedOut)
            Logger.app.warning("AI processing timed out after \(ContinuousClock.now - startTime)")
            return localText
        } catch {
            onAIProcessingStatus(.error(error.localizedDescription))
            Logger.app.error("AI processing failed: \(error)")
            return localText
        }
    }
}
