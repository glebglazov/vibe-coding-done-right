import Foundation
import Testing
@testable import vcdr_ios

/// The live view a Whisper drives, judged by the one thing a person watching
/// the screen would notice: text that has appeared and settled does not get
/// rewritten underneath them, the way Parakeet's sliding window never rewrites
/// its own (`docs/adr/0022`).
@Suite("Whisper's live view settles text")
struct ChunkedRedecodingTests {

    /// One recording, decoded three times as it grows, then finished — the
    /// whole path a live view takes. Each decode re-reads the audio after the
    /// settled point, so it is free to word the tail differently; the assertion
    /// is that what has already settled survives every one of them, and that
    /// the transcript delivered at the end is the text that was on screen.
    @Test("a growing recording settles text once and never rewrites it")
    func settledTextSurvivesLaterDecodes() {
        var live = ChunkedRedecoding()

        let firstPass = live.absorb([
            DecodedSegment(text: "The quick", endSeconds: 1),
            DecodedSegment(text: "brown fax", endSeconds: 2),
            DecodedSegment(text: "jumped", endSeconds: 3)
        ])
        #expect(firstPass.settled == "The quick")
        #expect(firstPass.text == "The quick brown fax jumped")

        // The next decode starts where the settled text ended, and rewords the
        // tail it is allowed to reword.
        #expect(live.settledThroughSeconds == 1)
        let secondPass = live.absorb([
            DecodedSegment(text: "brown fox", endSeconds: 2),
            DecodedSegment(text: "jumped over", endSeconds: 3),
            DecodedSegment(text: "the lazy", endSeconds: 4),
            DecodedSegment(text: "dog", endSeconds: 5)
        ])
        #expect(secondPass.settled == "The quick brown fox jumped over")
        #expect(secondPass.text.hasPrefix(firstPass.settled))
        #expect(live.settledThroughSeconds == 3)

        // Stopping decodes what is left with nothing held back, because no
        // wider window can follow it.
        let transcript = live.transcript(endingWith: [
            DecodedSegment(text: "the lazy", endSeconds: 4),
            DecodedSegment(text: "dog.", endSeconds: 5)
        ])
        #expect(transcript == "The quick brown fox jumped over the lazy dog.")
    }

    @Test("a decode short enough to be all tail settles nothing")
    func shortDecodeSettlesNothing() {
        var live = ChunkedRedecoding()

        let onlyTail = live.absorb([
            DecodedSegment(text: "Hello", endSeconds: 1),
            DecodedSegment(text: "there", endSeconds: 2)
        ])

        #expect(onlyTail.settled.isEmpty)
        #expect(onlyTail.text == "Hello there")
        #expect(live.settledThroughSeconds == 0)
    }

    /// A pause leaves the model with nothing new past the settled point, and it
    /// answers with the same segments as last time. Confirming them again would
    /// print the words twice.
    @Test("a decode that reaches no further settles nothing twice")
    func repeatedDecodeDoesNotDuplicate() {
        var live = ChunkedRedecoding()
        let segments = [
            DecodedSegment(text: "One", endSeconds: 1),
            DecodedSegment(text: "two", endSeconds: 2),
            DecodedSegment(text: "three", endSeconds: 3)
        ]

        _ = live.absorb(segments)
        let again = live.absorb(segments)

        #expect(again.settled == "One")
        #expect(again.text == "One two three")
    }
}
