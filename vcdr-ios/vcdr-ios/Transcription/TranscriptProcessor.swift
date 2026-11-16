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

    private let makeAIProvider: @MainActor () -> ProviderCascade
    private let onAIProcessingStatus: @MainActor (AIProcessingStatus) -> Void
    private let onAIInputText: @MainActor (String) -> Void

    init(
        makeAIProvider: @escaping @MainActor () -> ProviderCascade,
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
        spellingHints: SpellingHints
    ) async -> Output {
        let shouldUseAI = usesAI(initialSettings)
        let processedText: String
        if shouldUseAI {
            processedText = await processWithAI(
                localText: cleanedText,
                mode: initialSettings.promptMode,
                spellingHints: spellingHints
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

    func processWithAI(
        localText: String,
        settings: Settings,
        spellingHints: SpellingHints
    ) async -> String {
        await processWithAI(
            localText: localText,
            mode: settings.promptMode,
            spellingHints: spellingHints
        )
    }

    static func finalize(_ text: String, settings: Settings) -> String {
        TranscriptFinalizer.finalize(text, style: settings.textStyle)
    }

    static func historyLabel(settings: Settings) -> String? {
        guard settings.promptMode != .verbatim else { return nil }
        return outputChoiceLabel(mode: settings.promptMode, style: settings.textStyle)
    }

    /// "AI · Casual" or "AI off · Casual". History stores the label as text,
    /// so entries made with older labels keep them.
    static func outputChoiceLabel(mode: AIPromptMode, style: TextStyle) -> String {
        let modeName = switch mode {
        case .dictation: "AI"
        case .verbatim: "AI off"
        }
        return "\(modeName) · \(style.rawValue.capitalized)"
    }

    static func buildAIInput(_ localText: String) -> String {
        "<dictation>\(localText)</dictation>"
    }

    private func usesAI(_ settings: Settings) -> Bool {
        settings.promptMode != .verbatim && settings.hasAICapability
    }

    private func processWithAI(
        localText: String,
        mode: AIPromptMode,
        spellingHints: SpellingHints
    ) async -> String {
        onAIInputText(localText)
        onAIProcessingStatus(.processing)

        let systemPrompt = spellingHints.appended(to: BuiltInPrompts.prompt(for: mode), detail: mode.hintDetail)
        let input = Self.buildAIInput(localText)
        let provider = makeAIProvider()

        Logger.ai.info("AI input [mode=\(mode.rawValue), provider=\(provider.displayName)]: \(input)")
        Logger.ai.debug("AI system prompt: \(systemPrompt.prefix(100))...")

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
