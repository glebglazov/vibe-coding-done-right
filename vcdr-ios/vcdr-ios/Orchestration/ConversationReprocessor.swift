import Foundation
import OSLog

/// The Text Style a Discarded Conversation is processed with. Processing
/// always runs with AI on.
struct ReprocessChoice: Equatable {
    let style: TextStyle

    var label: String {
        TranscriptProcessor.outputChoiceLabel(mode: .dictation, style: style)
    }
}

/// "Process with AI" for a Discarded Conversation (ADR-0010). The result goes
/// to History only. Views observe which entries are at work and which failed.
@MainActor
protocol ConversationReprocessor: AnyObject, Observable {
    /// The choice an entry is processed with now. Nil when it is not at work.
    func choiceInProgress(for conversationID: UUID) -> ReprocessChoice?
    /// Why the last attempt failed. Nil after a new attempt starts.
    func failure(for conversationID: UUID) -> String?
    /// The Recorded Output Choice, where this device can use it.
    func defaultChoice(for conversation: Conversation) -> ReprocessChoice
    func process(_ conversation: Conversation, with choice: ReprocessChoice)
}

@MainActor
@Observable
final class AIConversationReprocessor: ConversationReprocessor {
    private static let taskName = "Process with AI"
    static let noAIMessage = "AI is not set up. Add a provider in Settings."
    static let timedOutMessage = "AI did not answer in time. Try again."

    private let history: any HistoryStore
    private let backgroundTasks: any BackgroundTaskRunner
    private let substitutions: @MainActor () -> [Substitution]
    private let currentStyle: @MainActor () -> TextStyle
    private let hasAICapability: @MainActor () -> Bool
    private let makeAIProvider: @MainActor () -> ProviderCascade

    private var processing: [UUID: ReprocessChoice] = [:]
    private var failures: [UUID: String] = [:]

    init(
        history: any HistoryStore,
        backgroundTasks: any BackgroundTaskRunner,
        substitutions: @escaping @MainActor () -> [Substitution],
        currentStyle: @escaping @MainActor () -> TextStyle = { SettingOverrides.effectiveTextStyle() },
        hasAICapability: @escaping @MainActor () -> Bool = { AIProcessingSettings.hasAICapability },
        makeAIProvider: @escaping @MainActor () -> ProviderCascade = { AIProviderFactory.make() }
    ) {
        self.history = history
        self.backgroundTasks = backgroundTasks
        self.substitutions = substitutions
        self.currentStyle = currentStyle
        self.hasAICapability = hasAICapability
        self.makeAIProvider = makeAIProvider
    }

    func choiceInProgress(for conversationID: UUID) -> ReprocessChoice? {
        processing[conversationID]
    }

    func failure(for conversationID: UUID) -> String? {
        failures[conversationID]
    }

    /// A choice the Mac recorded has ids this device cannot read, so the
    /// current iOS style stands in.
    func defaultChoice(for conversation: Conversation) -> ReprocessChoice {
        guard case .discarded(let recorded) = conversation.status, let style = recorded.iosStyle else {
            return ReprocessChoice(style: currentStyle())
        }
        return ReprocessChoice(style: style)
    }

    func process(_ conversation: Conversation, with choice: ReprocessChoice) {
        let id = conversation.id
        guard conversation.status.isDiscarded, processing[id] == nil else { return }
        processing[id] = choice
        failures[id] = nil
        Task {
            let result = await backgroundTasks.run(named: Self.taskName) {
                await self.output(for: conversation, choice: choice)
            }
            switch result {
            case .success(let output):
                history.resolveDiscarded(conversationID: id, output: output.finalText, label: output.historyLabel)
            case .failure(let failure):
                Logger.ai.error("Process with AI failed: \(failure.message)")
                failures[id] = failure.message
            }
            processing[id] = nil
        }
    }

    /// The pipeline a stop runs after transcription: Substitutions, filler
    /// removal, AI, then Transcript Finalization. The text of an AI call that
    /// failed is not a result here, so the entry stays discarded.
    private func output(
        for conversation: Conversation,
        choice: ReprocessChoice
    ) async -> Result<TranscriptProcessor.Output, ReprocessFailure> {
        guard hasAICapability() else { return .failure(ReprocessFailure(message: Self.noAIMessage)) }

        let dictionary = substitutions()
        let verbatim = conversation.inputSegments.filter { $0.capture == nil }.map(\.text).joined(separator: "\n")
        let cleaned = TextPostProcessor.removeFillers(
            from: SubstitutionMatcher(substitutions: dictionary).apply(to: verbatim)
        )

        let ai = AIStatusBox()
        let processor = TranscriptProcessor(
            makeAIProvider: makeAIProvider,
            onAIProcessingStatus: { ai.status = $0 },
            onAIInputText: { _ in }
        )
        let settings = TranscriptProcessor.Settings(
            promptMode: .dictation,
            textStyle: choice.style,
            hasAICapability: true
        )
        let output = await processor.processFinalTranscript(
            cleaned,
            initialSettings: settings,
            finalSettings: { settings },
            spellingHints: SpellingHints(dictionary)
        )
        switch ai.status {
        case .completed: return .success(output)
        case .timedOut: return .failure(ReprocessFailure(message: Self.timedOutMessage))
        case .error(let message): return .failure(ReprocessFailure(message: message))
        case .idle, .processing: return .failure(ReprocessFailure(message: Self.noAIMessage))
        }
    }
}

@MainActor
private final class AIStatusBox {
    var status = TranscriptProcessor.AIProcessingStatus.idle
}

private struct ReprocessFailure: Error {
    let message: String
}
