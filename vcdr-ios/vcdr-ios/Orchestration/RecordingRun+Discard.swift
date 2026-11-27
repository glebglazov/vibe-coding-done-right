import Foundation
import OSLog

/// Discard (ADR-0010): the run ends at once, and its words are decoded later
/// for History, off the active-run slot.
extension RecordingRun {
    /// The user's Discard during Capturing: the run ends as cancelled at
    /// once, and its streaming session keeps the words for
    /// `finishDiscarded()`.
    func discard() async {
        guard case .capturing = phase else { return }
        await finish(.cancellation)
    }

    /// Returns the verbatim transcript of a run ended by `discard()`: the raw
    /// text of the streaming session, with no Substitutions, no filler
    /// removal and no AI. Empty when nothing was said or the transcription
    /// failed.
    ///
    /// No completion adapter and no callback hears of this decode: the run
    /// already ended, and by now a later run can own the wire and the screen.
    func finishDiscarded() async -> String {
        do {
            try await setupTask?.value
            let text = try await streaming.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            Logger.recording.info("Discarded run decoded (\(text.count) chars)")
            return text
        } catch {
            await streaming.cancel()
            Logger.recording.error("Discarded run was not transcribed: \(error)")
            return ""
        }
    }
}
