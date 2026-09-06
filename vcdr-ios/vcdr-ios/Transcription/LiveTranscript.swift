import Foundation

/// What the live view shows at one moment, in the two parts every family's live
/// path resolves to: text that has settled and will not change again, and a
/// volatile tail the next update may rewrite.
///
/// One shape for both families is the point. Parakeet's sliding window reports
/// these two directly; Whisper's chunked re-decoding is made to produce them
/// (`docs/adr/0022`), so a person watching the screen sees text settle the same
/// way whichever model is running.
nonisolated struct LiveTranscript: Equatable, Sendable {
    var settled: String = ""
    var volatile: String = ""

    /// The whole line as the view renders it. Settled and volatile are one
    /// sentence being spoken, not two fields, so they read as one.
    var text: String {
        let joined = settled.isEmpty ? volatile : (volatile.isEmpty ? settled : "\(settled) \(volatile)")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One stretch of decoded speech and the point in the recording it ends at —
/// all a live view needs from a decode, named here so the reconciliation below
/// can be reasoned about without a transcription backend in the room.
nonisolated struct DecodedSegment: Equatable, Sendable {
    let text: String
    let endSeconds: Float
}

/// Whisper reaches a live view by decoding the recording so far from scratch,
/// again, every second or so — so any word it has emitted can still change, and
/// showing every decode raw would make text flicker and rewrite itself as a
/// person speaks. Parakeet's window never does that, and the two must not look
/// like different apps.
///
/// So a decode's trailing segments are held back as the volatile tail, and only
/// what lies behind them settles. The next decode is then clipped to start
/// where the settled text ends, which is what makes settling final: the audio
/// that produced it is no longer in the window that could rewrite it, and it is
/// also work the next decode no longer repeats. Recorded as `docs/adr/0022`.
nonisolated struct ChunkedRedecoding {

    /// How many trailing segments stay volatile. Two: the last segment is still
    /// being spoken, and the one before it is what a wider window most often
    /// re-punctuates or re-splits. This is also what WhisperKit's own streaming
    /// reference holds back.
    static let volatileSegmentCount = 2

    /// Where the settled text ends, and so where the next decode starts.
    private(set) var settledThroughSeconds: Float = 0

    private var settled: [String] = []

    /// Folds one decode into the live view, returning what to show now.
    ///
    /// `segments` are what the model returned for the audio after
    /// `settledThroughSeconds`, so everything it settles here is new text
    /// rather than a rewording of text already shown.
    mutating func absorb(_ segments: [DecodedSegment]) -> LiveTranscript {
        let settling = segments.prefix(max(0, segments.count - Self.volatileSegmentCount))
        // A decode that reached no further than the last one settled nothing:
        // confirming it again would print the same words twice.
        if let last = settling.last, last.endSeconds > settledThroughSeconds {
            settledThroughSeconds = last.endSeconds
            settled.append(contentsOf: settling.map(\.text))
        }
        return LiveTranscript(
            settled: Self.joined(settled),
            volatile: Self.joined(segments.suffix(Self.volatileSegmentCount).map(\.text))
        )
    }

    /// The whole transcript, with `tail` as the last decode of the audio past
    /// `settledThroughSeconds`. What is delivered is what the person watched
    /// settle plus the end of the sentence they just finished — the live view
    /// and the transcript are one thing, not two answers to the same recording.
    func transcript(endingWith tail: [DecodedSegment]) -> String {
        Self.joined(settled + tail.map(\.text))
    }

    private static func joined(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
