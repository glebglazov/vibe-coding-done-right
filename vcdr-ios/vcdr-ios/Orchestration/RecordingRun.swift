import FluidAudio
import Foundation
import OSLog
import UIKit

@MainActor
final class RecordingRun {
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

    private struct TerminalContext {
        let cleanedLiveTranscript: String
        let backgroundTaskID: UIBackgroundTaskIdentifier
    }

    private let conversationID = UUID()
    private let audioRecorder: AudioRecorder
    private let transcriptionProvider: any StreamingTranscriptionProvider
    private let completionAdapters: [any RecordingRunCompletionAdapter]
    private let makeAIProvider: @MainActor (AIPromptMode) -> FallbackProvider
    private let currentSettings: @MainActor () -> Settings
    private let currentCaptures: @MainActor () -> [String]
    private let onLiveTranscript: @MainActor (String) -> Void
    private let onInterimResult: @MainActor (String) -> Void
    private let onTranscribingMessage: @MainActor (String) -> Void
    private let onAIProcessingStatus: @MainActor (AIProcessingStatus) -> Void
    private let onAIInputText: @MainActor (String) -> Void

    private let streaming = StreamingAsrManager(config: .streaming)
    private var setupTask: Task<Void, Error>?
    private var updateTask: Task<Void, Never>?
    private var terminalState: RecordingRunTerminalState?
    private var aiInputText = ""
    private var latestLiveTranscript = ""

    init(
        audioRecorder: AudioRecorder,
        transcriptionProvider: any StreamingTranscriptionProvider,
        completionAdapters: [any RecordingRunCompletionAdapter],
        makeAIProvider: @escaping @MainActor (AIPromptMode) -> FallbackProvider,
        currentSettings: @escaping @MainActor () -> Settings,
        currentCaptures: @escaping @MainActor () -> [String],
        onLiveTranscript: @escaping @MainActor (String) -> Void,
        onInterimResult: @escaping @MainActor (String) -> Void,
        onTranscribingMessage: @escaping @MainActor (String) -> Void,
        onAIProcessingStatus: @escaping @MainActor (AIProcessingStatus) -> Void,
        onAIInputText: @escaping @MainActor (String) -> Void
    ) {
        self.audioRecorder = audioRecorder
        self.transcriptionProvider = transcriptionProvider
        self.completionAdapters = completionAdapters
        self.makeAIProvider = makeAIProvider
        self.currentSettings = currentSettings
        self.currentCaptures = currentCaptures
        self.onLiveTranscript = onLiveTranscript
        self.onInterimResult = onInterimResult
        self.onTranscribingMessage = onTranscribingMessage
        self.onAIProcessingStatus = onAIProcessingStatus
        self.onAIInputText = onAIInputText
    }

    var isTerminal: Bool { terminalState != nil }

    func start() async -> Bool {
        setupTask = Task.detached { [transcriptionProvider, streaming] in
            try await transcriptionProvider.initialize()
            guard let models = await transcriptionProvider.loadedModels else {
                throw TranscriptionError.providerUnavailable
            }
            try await streaming.start(models: models, source: .microphone)
        }

        latestLiveTranscript = ""
        onLiveTranscript("")
        updateTask = startConsumingUpdates()

        let started = await audioRecorder.startCapture { [streaming] buffer in
            Task { await streaming.streamAudio(buffer) }
        }
        if !started {
            cancelSetup()
            terminalState = .processingFailure(
                RecordingRunFailure(message: "Failed to start recording — check microphone permission")
            )
        }
        return started
    }

    func stop(deliversToKeyboard: Bool) async -> RecordingRunTerminalState {
        guard terminalState == nil else {
            return terminalState ?? .cancellation
        }

        audioRecorder.stopCapture()
        updateTask?.cancel()

        let waitStart = ContinuousClock.now
        onTranscribingMessage("Loading model — your recording is safe")
        let elapsedTicker = makeElapsedTicker(waitStart: waitStart)

        do {
            try await setupTask?.value
        } catch {
            elapsedTicker.cancel()
            await streaming.cancel()
            return await finish(.processingFailure(
                RecordingRunFailure(message: "Transcription unavailable: \(error.localizedDescription)")
            ))
        }
        elapsedTicker.cancel()
        onTranscribingMessage("")

        let cleanedLive = TextPostProcessor.removeFillers(from: latestLiveTranscript)
        onLiveTranscript("")

        let interimSettings = currentSettings()
        let usesAI = interimSettings.promptMode != .verbatim && interimSettings.hasAICapability
        if !usesAI && !cleanedLive.isEmpty {
            onInterimResult(TranscriptFinalizer.finalize(
                cleanedLive,
                mode: interimSettings.promptMode,
                style: interimSettings.textStyle
            ))
        } else {
            onTranscribingMessage(usesAI ? "Enhancing with AI..." : "")
        }

        let backgroundTaskID = deliversToKeyboard
            ? UIApplication.shared.beginBackgroundTask()
            : .invalid
        let context = TerminalContext(
            cleanedLiveTranscript: cleanedLive,
            backgroundTaskID: backgroundTaskID
        )

        do {
            return try await finishStreaming(context: context)
        } catch {
            let terminal = RecordingRunTerminalState.processingFailure(
                RecordingRunFailure(message: "Transcription failed: \(error.localizedDescription)")
            )
            return await finish(terminal, backgroundTaskID: backgroundTaskID)
        }
    }

    func cancel() async -> RecordingRunTerminalState {
        audioRecorder.stopCapture()
        cancelSetup()
        await streaming.cancel()
        return await finish(.cancellation)
    }

    private func finishStreaming(context: TerminalContext) async throws -> RecordingRunTerminalState {
        let rawText = try await streaming.finish()
        let cleanedText = TextPostProcessor.removeFillers(from: rawText)
        Logger.app.info("Streaming transcription complete: \(cleanedText.prefix(50))...")

        guard !cleanedText.isEmpty else {
            return await finish(.emptyResult, backgroundTaskID: context.backgroundTaskID)
        }

        let settings = currentSettings()
        let useAI = settings.promptMode != .verbatim && settings.hasAICapability
        let processedText: String
        if useAI {
            processedText = await processWithAI(localText: cleanedText, mode: settings.promptMode)
        } else {
            processedText = cleanedText
        }

        let finalSettings = currentSettings()
        let resultText = TranscriptFinalizer.finalize(
            processedText,
            mode: finalSettings.promptMode,
            style: finalSettings.textStyle
        )
        let terminal = RecordingRunTerminalState.success(RecordingRunSuccess(
            conversationID: conversationID,
            transcript: cleanedText,
            processed: useAI ? processedText : nil,
            finalText: resultText,
            captures: currentCaptures(),
            historyLabel: historyLabel(settings: finalSettings)
        ))
        return await finish(terminal, backgroundTaskID: context.backgroundTaskID)
    }

    private func processWithAI(localText: String, mode: AIPromptMode) async -> String {
        aiInputText = localText
        onAIInputText(localText)
        onAIProcessingStatus(.processing)

        let systemPrompt = BuiltInPrompts.prompt(for: mode)
        let input = buildAIInput(localText, mode: mode)
        let provider = makeAIProvider(mode)

        Logger.ai.info("AI input [mode=\(mode.rawValue), provider=\(provider.displayName)]: \(input)")
        Logger.ai.debug("AI system prompt: \(systemPrompt.prefix(100))...")

        let startTime = ContinuousClock.now
        do {
            let result = try await provider.process(text: input, systemPrompt: systemPrompt)
            onAIProcessingStatus(.completed)
            Logger.ai.info("AI output [\(ContinuousClock.now - startTime)]: \(result)")
            return result
        } catch is FallbackProvider.AITimedOut {
            onAIProcessingStatus(.timedOut)
            Logger.app.warning("AI processing timed out after \(ContinuousClock.now - startTime)")
            return localText
        } catch {
            onAIProcessingStatus(.error(error.localizedDescription))
            Logger.app.error("AI processing failed: \(error)")
            return localText
        }
    }

    private func buildAIInput(_ localText: String, mode: AIPromptMode) -> String {
        var wrapped = "<dictation>\(localText)</dictation>"
        guard mode == .assistant else { return wrapped }
        for (index, capture) in currentCaptures().enumerated() where !capture.isEmpty {
            wrapped += "\n\n<capture id=\"\(index + 1)\">\(capture)</capture>"
            Logger.ai.info("Capture \(index + 1) included in AI input (\(capture.count) chars)")
        }
        return wrapped
    }

    private func finish(
        _ terminal: RecordingRunTerminalState,
        backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    ) async -> RecordingRunTerminalState {
        terminalState = terminal
        onTranscribingMessage("")
        for adapter in completionAdapters {
            await adapter.complete(terminal)
        }
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
        }
        return terminal
    }

    private func cancelSetup() {
        updateTask?.cancel()
        setupTask?.cancel()
    }

    private func makeElapsedTicker(waitStart: ContinuousClock.Instant) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let elapsed = Int((ContinuousClock.now - waitStart).components.seconds)
                self.onTranscribingMessage("Loading model · \(elapsed)s — your recording is safe")
            }
        }
    }

    private func startConsumingUpdates() -> Task<Void, Never> {
        Task {
            let updates = await streaming.transcriptionUpdates
            var lastUpdateTime: ContinuousClock.Instant = .now
            for await _ in updates {
                guard !Task.isCancelled else { break }

                let now = ContinuousClock.now
                guard now - lastUpdateTime >= Self.transcriptUpdateInterval else { continue }
                lastUpdateTime = now

                let confirmed = await streaming.confirmedTranscript
                let volatile = await streaming.volatileTranscript
                let full = confirmed.isEmpty ? volatile : "\(confirmed) \(volatile)"
                let text = full.trimmingCharacters(in: .whitespaces)
                latestLiveTranscript = text
                onLiveTranscript(text)
            }
        }
    }

    private func historyLabel(settings: Settings) -> String? {
        guard settings.promptMode != .verbatim else { return nil }
        let mode = settings.promptMode.rawValue.capitalized
        return settings.promptMode.appliesStyles
            ? "\(mode) · \(settings.textStyle.rawValue.capitalized)"
            : mode
    }

    private static let transcriptUpdateInterval: Duration = .milliseconds(16)
}
