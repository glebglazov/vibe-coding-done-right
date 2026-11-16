import Foundation
import Observation
import OSLog

/// "Process with AI" for a Discarded Conversation: runs its verbatim words
/// through a Mode's pipeline and makes it a normal entry. Nothing is pasted;
/// the result goes to History only.
@MainActor
protocol ConversationReprocessor: AnyObject, Observable {
    /// The Discarded Conversations being processed now.
    var processingIDs: Set<UUID> { get }

    /// Why the last attempt for a conversation failed. The entry stays
    /// discarded, so the user can try again.
    var failures: [UUID: String] { get }

    /// Processes with `mode`, or with the Mode recorded at the Discard when
    /// `mode` is nil. Does nothing for a normal entry or one already running.
    func process(_ conversation: Conversation, with mode: Mode?) async
}

@Observable
@MainActor
final class PipelineConversationReprocessor: ConversationReprocessor {

    private(set) var processingIDs: Set<UUID> = []
    private(set) var failures: [UUID: String] = [:]

    @ObservationIgnored private let history: any HistoryStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let substitutionStore: any SubstitutionStore
    @ObservationIgnored private let aiPort: any AIProcessingPort
    @ObservationIgnored private let styleWithID: @Sendable (UUID) async -> Style?
    @ObservationIgnored private let currentStyle: @MainActor () -> Style

    init(
        history: any HistoryStore,
        settings: AppSettings,
        substitutionStore: any SubstitutionStore,
        aiPort: any AIProcessingPort,
        styleWithID: @escaping @Sendable (UUID) async -> Style?,
        currentStyle: @escaping @MainActor () -> Style
    ) {
        self.history = history
        self.settings = settings
        self.substitutionStore = substitutionStore
        self.aiPort = aiPort
        self.styleWithID = styleWithID
        self.currentStyle = currentStyle
    }

    func process(_ conversation: Conversation, with chosenMode: Mode?) async {
        guard case .discarded(let choice) = conversation.status,
              !processingIDs.contains(conversation.id)
        else { return }

        processingIDs.insert(conversation.id)
        failures[conversation.id] = nil
        defer { processingIDs.remove(conversation.id) }

        let mode = chosenMode ?? recordedMode(for: choice) ?? settings.activeMode
        let style = await recordedStyle(for: choice) ?? currentStyle()
        do {
            let output = try await run(conversation.inputSegments, mode: mode, style: style, conversationID: conversation.id)
            history.resolveDiscarded(conversationID: conversation.id, output: output, label: mode.name)
            Logger.app.info("Discarded conversation processed with \(mode.name)")
        } catch {
            failures[conversation.id] = error.localizedDescription
            Logger.app.error("Discarded conversation not processed: \(error)")
        }
    }

    // MARK: - Pipeline

    private func run(
        _ segments: [InputSegment],
        mode: Mode,
        style: Style,
        conversationID: UUID
    ) async throws -> String {
        let context = SubmissionPipeline.Context(
            text: segments.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n"),
            mode: mode,
            substitutions: substitutionStore.substitutions,
            conversationID: conversationID,
            parameterValues: Self.defaultParameterValues(for: mode),
            variableEnvironment: settings.variableEnvironment,
            aiAPIKey: settings.storedAPIKey(for: mode.aiProvider),
            destination: settings.outputDestination(for: mode.defaultOutputDestinationID),
            targetAppPID: nil,
            saveResultToClipboard: false,
            removeFillerWords: settings.removeFillerWords,
            style: style
        )
        let result = try await SubmissionPipeline.process(context: context, aiPort: aiPort)
        if let fallback = result.aiProcessingFallback {
            throw ReprocessingError.aiFailed(fallback.errorMessage)
        }
        if result.processedText == TextProcessingPipeline.Constants.noInstructionSentinel {
            throw ReprocessingError.noInstruction
        }
        return result.processedText
    }

    // MARK: - Recorded choice

    /// A choice recorded on iOS names an iOS mode, which the Mac cannot read.
    private func recordedMode(for choice: RecordedOutputChoice) -> Mode? {
        guard choice.platform == .mac else { return nil }
        return settings.modes.first { $0.id.uuidString == choice.modeID }
    }

    private func recordedStyle(for choice: RecordedOutputChoice) async -> Style? {
        guard choice.platform == .mac,
              let styleID = choice.styleID.flatMap(UUID.init(uuidString:))
        else { return nil }
        return await styleWithID(styleID)
    }

    /// No Capture Session is running for this, so no override applies: every
    /// parameter takes its first option, as a fresh session would.
    private static func defaultParameterValues(for mode: Mode) -> [String: String] {
        var values: [String: String] = [:]
        for parameter in mode.parameters where !parameter.environmentVariableSuffix.isEmpty {
            values[parameter.environmentVariableSuffix] = parameter.options.first?.value ?? ""
        }
        return values
    }
}

enum ReprocessingError: LocalizedError {
    case aiFailed(String)
    case noInstruction

    var errorDescription: String? {
        switch self {
        case .aiFailed(let message): message
        case .noInstruction: "No instruction detected"
        }
    }
}
