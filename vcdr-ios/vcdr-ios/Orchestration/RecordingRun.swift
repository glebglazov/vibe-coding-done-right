import AVFoundation
import FluidAudio
import Foundation
import OSLog
import UIKit

@MainActor
protocol RecordingAudioCapturing: AnyObject {
    func startCapture(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async -> Bool
    func stopCapture()
}

extension AudioRecorder: RecordingAudioCapturing {}

protocol RecordingStreamingSession: Sendable {
    func start(using transcriptionProvider: any StreamingTranscriptionProvider) async throws
    func streamAudio(_ buffer: AVAudioPCMBuffer) async
    func cancel() async
    func finish() async throws -> String
    func liveTranscriptUpdates() async -> AsyncStream<String>
}

@MainActor
final class RecordingRun {
    typealias Settings = TranscriptProcessor.Settings

    private struct TerminalContext {
        let cleanedLiveTranscript: String
        let backgroundTaskID: UIBackgroundTaskIdentifier
    }

    private let conversationID = UUID()
    private let audioRecorder: any RecordingAudioCapturing
    private let transcriptionProvider: any StreamingTranscriptionProvider
    private let streaming: any RecordingStreamingSession
    private let transcriptProcessor: TranscriptProcessor
    private let completionAdapters: [any RecordingRunCompletionAdapter]
    private let currentSettings: @MainActor () -> Settings
    private let currentCaptures: @MainActor () -> [String]
    private let onLiveTranscript: @MainActor (String) -> Void
    private let onInterimResult: @MainActor (String) -> Void
    private let onTranscribingMessage: @MainActor (String) -> Void

    private var setupTask: Task<Void, Error>?
    private var updateTask: Task<Void, Never>?
    private var terminalState: RecordingRunTerminalState?
    private var latestLiveTranscript = ""

    init(
        audioRecorder: any RecordingAudioCapturing,
        transcriptionProvider: any StreamingTranscriptionProvider,
        streaming: any RecordingStreamingSession = LiveRecordingStreamingSession(),
        transcriptProcessor: TranscriptProcessor,
        completionAdapters: [any RecordingRunCompletionAdapter],
        currentSettings: @escaping @MainActor () -> Settings,
        currentCaptures: @escaping @MainActor () -> [String],
        onLiveTranscript: @escaping @MainActor (String) -> Void,
        onInterimResult: @escaping @MainActor (String) -> Void,
        onTranscribingMessage: @escaping @MainActor (String) -> Void
    ) {
        self.audioRecorder = audioRecorder
        self.transcriptionProvider = transcriptionProvider
        self.streaming = streaming
        self.transcriptProcessor = transcriptProcessor
        self.completionAdapters = completionAdapters
        self.currentSettings = currentSettings
        self.currentCaptures = currentCaptures
        self.onLiveTranscript = onLiveTranscript
        self.onInterimResult = onInterimResult
        self.onTranscribingMessage = onTranscribingMessage
    }

    var isTerminal: Bool { terminalState != nil }

    func start() async -> Bool {
        setupTask = Task.detached { [transcriptionProvider, streaming] in
            try await streaming.start(using: transcriptionProvider)
        }

        latestLiveTranscript = ""
        onLiveTranscript("")
        updateTask = startConsumingUpdates()

        let started = await audioRecorder.startCapture { [streaming] buffer in
            Task { await streaming.streamAudio(buffer) }
        }
        if !started {
            cancelSetup()
            _ = await finish(.processingFailure(
                RecordingRunFailure(message: "Failed to start recording — check microphone permission")
            ))
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
        if let interimText = transcriptProcessor.interimText(for: cleanedLive, settings: interimSettings) {
            onInterimResult(interimText)
        } else {
            let usesAI = interimSettings.promptMode != .verbatim && interimSettings.hasAICapability
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

    /// DEBUG / test-only: polls until this run reaches its terminal resting
    /// state and returns the recorded outcome. Production code never reads it.
    func waitForIdle(timeout: Duration = .seconds(10)) async -> RecordingRunTerminalState? {
        let start = ContinuousClock.now
        while start.duration(to: .now) < timeout {
            if let terminalState {
                return terminalState
            }
            try? await Task.sleep(for: Self.idlePollInterval)
        }
        return nil
    }

    private func finishStreaming(context: TerminalContext) async throws -> RecordingRunTerminalState {
        let rawText = try await streaming.finish()
        let cleanedText = TextPostProcessor.removeFillers(from: rawText)
        Logger.app.info("Streaming transcription complete: \(cleanedText.prefix(50))...")

        guard !cleanedText.isEmpty else {
            return await finish(.emptyResult, backgroundTaskID: context.backgroundTaskID)
        }

        let captures = currentCaptures()
        let output = await transcriptProcessor.processFinalTranscript(
            cleanedText,
            initialSettings: currentSettings(),
            finalSettings: currentSettings,
            captures: captures
        )
        let terminal = RecordingRunTerminalState.success(RecordingRunSuccess(
            conversationID: conversationID,
            transcript: output.transcript,
            processed: output.processed,
            finalText: output.finalText,
            captures: captures,
            historyLabel: output.historyLabel
        ))
        return await finish(terminal, backgroundTaskID: context.backgroundTaskID)
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
            let updates = await streaming.liveTranscriptUpdates()
            var lastUpdateTime: ContinuousClock.Instant = .now
            for await text in updates {
                guard !Task.isCancelled else { break }

                let now = ContinuousClock.now
                guard now - lastUpdateTime >= Self.transcriptUpdateInterval else { continue }
                lastUpdateTime = now

                latestLiveTranscript = text
                onLiveTranscript(text)
            }
        }
    }

    private static let idlePollInterval: Duration = .milliseconds(20)
    private static let transcriptUpdateInterval: Duration = .milliseconds(16)
}
