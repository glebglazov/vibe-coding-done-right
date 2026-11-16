import Foundation
import OSLog

/// A Recording Run the user discarded during Capturing, with what History
/// needs to keep its words.
struct DiscardedRun {
    let run: RecordingRun
    let choice: RecordedOutputChoice
}

enum DiscardedRunOutcome: Equatable, Sendable {
    /// History holds a Discarded Conversation with this id.
    case saved(UUID)
    /// No audio, no speech, or the transcription failed.
    case nothingSaved
}

/// Gives a discarded run its ending off the active-run slot: the verbatim
/// transcript goes to History, and the next run never waits for it (ADR-0010).
@MainActor
protocol DiscardedRunFinalizer: AnyObject {
    /// The decode of the last discarded run, if one has begun. A new run's
    /// transcription setup waits for it, so two decodes never run at once.
    var decodeInFlight: Task<Void, Never>? { get }

    /// Begins at once and returns at once. `report` runs when History holds
    /// the words, or when it is known that nothing will be saved.
    func finalize(_ discarded: DiscardedRun, report: @escaping @MainActor (DiscardedRunOutcome) -> Void)
}

@MainActor
final class HistoryDiscardedRunFinalizer: DiscardedRunFinalizer {
    private static let taskName = "Discarded run"

    private let history: any HistoryStore
    private let backgroundTasks: any BackgroundTaskRunner
    /// Kept after it ends: a wait on a finished task returns at once.
    private(set) var decodeInFlight: Task<Void, Never>?

    init(history: any HistoryStore, backgroundTasks: any BackgroundTaskRunner) {
        self.history = history
        self.backgroundTasks = backgroundTasks
    }

    func finalize(_ discarded: DiscardedRun, report: @escaping @MainActor (DiscardedRunOutcome) -> Void) {
        // A keyboard run's app is in the background, and with capture ended
        // iOS could suspend it before the decode completes.
        decodeInFlight = Task {
            let outcome = await backgroundTasks.run(named: Self.taskName) {
                await self.save(discarded)
            }
            report(outcome)
        }
    }

    private func save(_ discarded: DiscardedRun) async -> DiscardedRunOutcome {
        let text = await discarded.run.finishDiscarded()
        guard !text.isEmpty else {
            Logger.recording.info("Discarded run had no words: nothing saved")
            return .nothingSaved
        }
        let id = discarded.run.conversationID
        history.recordDiscarded(
            conversationID: id,
            inputSegments: [InputSegment(text: text)],
            choice: discarded.choice
        )
        Logger.recording.info("Discarded run saved to History (\(text.count) chars)")
        return .saved(id)
    }
}
