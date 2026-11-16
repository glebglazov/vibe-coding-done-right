import Foundation
import OSLog

/// A recording the user discarded with ⇧⎋, as it leaves the Capture Session:
/// its audio, and everything the save to History needs. Built at the moment of
/// the Discard, so a Mode switched afterwards changes nothing about it.
struct DiscardedCapture: Sendable {
    let conversationID: UUID
    let audioURL: URL
    let provider: any TranscriptionProvider
    let transcriptionSettings: TranscriptionModelSettings
    let spellingHints: SpellingHints
    let choice: RecordedOutputChoice
}

enum DiscardOutcome: Equatable, Sendable {
    case saved(conversationID: UUID)
    case nothingSaved
}

/// Turns a discarded recording into a Discarded Conversation, out of the
/// Capture Session's way: the session is idle before this starts.
@MainActor
protocol DiscardedCaptureFinalizer: AnyObject {
    /// Starts to transcribe the audio verbatim and, when it holds speech, to
    /// save it to History. Deletes the audio file in every case.
    func finalize(_ capture: DiscardedCapture) -> Task<DiscardOutcome, Never>
}

@MainActor
final class VerbatimDiscardedCaptureFinalizer: DiscardedCaptureFinalizer {

    private let history: any HistoryStore
    private let decodeTurnstile: DecodeTurnstile
    private let modelReadinessPollingInterval: Duration
    private var inFlight: [UUID: Task<DiscardOutcome, Never>] = [:]

    init(
        history: any HistoryStore,
        decodeTurnstile: DecodeTurnstile,
        modelReadinessPollingInterval: Duration
    ) {
        self.history = history
        self.decodeTurnstile = decodeTurnstile
        self.modelReadinessPollingInterval = modelReadinessPollingInterval
    }

    func finalize(_ capture: DiscardedCapture) -> Task<DiscardOutcome, Never> {
        let id = UUID()
        let task = Task { @MainActor [weak self, history, decodeTurnstile, modelReadinessPollingInterval] in
            let outcome = await Self.finalize(
                capture,
                history: history,
                decodeTurnstile: decodeTurnstile,
                modelReadinessPollingInterval: modelReadinessPollingInterval
            )
            self?.inFlight[id] = nil
            return outcome
        }
        inFlight[id] = task
        return task
    }

    /// Returns once every discarded recording started so far is saved or
    /// dropped.
    func awaitFinalizations() async {
        for task in Array(inFlight.values) {
            _ = await task.value
        }
    }

    private static func finalize(
        _ capture: DiscardedCapture,
        history: any HistoryStore,
        decodeTurnstile: DecodeTurnstile,
        modelReadinessPollingInterval: Duration
    ) async -> DiscardOutcome {
        defer { try? FileManager.default.removeItem(at: capture.audioURL) }

        let text: String
        do {
            try await capture.provider.waitUntilReady(pollingEvery: modelReadinessPollingInterval)
            text = try await decodeTurnstile.takingTurn {
                try await capture.provider.transcribe(
                    audioFileURL: capture.audioURL,
                    settings: capture.transcriptionSettings,
                    spellingHints: capture.spellingHints
                )
            }
        } catch {
            Logger.app.error("Discarded recording not transcribed: \(error)")
            return .nothingSaved
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Logger.app.info("Discarded recording had no speech; nothing saved")
            return .nothingSaved
        }

        history.recordDiscarded(
            conversationID: capture.conversationID,
            inputSegments: [InputSegment(text: text)],
            choice: capture.choice
        )
        Logger.app.info("Discarded recording saved to History")
        return .saved(conversationID: capture.conversationID)
    }
}
