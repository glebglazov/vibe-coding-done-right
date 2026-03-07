import Foundation
import Testing
@testable import vcdr

@Suite("FillerWordRemover")
struct FillerWordRemoverTests {

    @Test("Removes mid-sentence comma-wrapped filler")
    func midSentenceCommaWrapped() {
        #expect(FillerWordRemover.remove(from: "I was, um, going") == "I was going")
    }

    @Test("Removes filler at sentence start")
    func sentenceStart() {
        #expect(FillerWordRemover.remove(from: "Um, I think so") == "I think so")
    }

    @Test("Removes filler at sentence end before period")
    func sentenceEnd() {
        #expect(FillerWordRemover.remove(from: "I think, um.") == "I think.")
    }

    @Test("Removes filler without commas")
    func noCommas() {
        #expect(FillerWordRemover.remove(from: "I was um going") == "I was going")
    }

    @Test("Removes multiple fillers in one sentence")
    func multipleFillers() {
        #expect(FillerWordRemover.remove(from: "So, um, I was, uh, thinking") == "So I was thinking")
    }

    @Test("Removes different filler words")
    func differentFillers() {
        #expect(FillerWordRemover.remove(from: "Hmm, that's interesting") == "That's interesting")
    }

    @Test("Handles repeated characters like ummm, hmmm")
    func repeatedChars() {
        #expect(FillerWordRemover.remove(from: "Ummm, yeah") == "Yeah")
    }

    @Test("Passes through text without fillers unchanged")
    func noFillers() {
        #expect(FillerWordRemover.remove(from: "Hello world") == "Hello world")
    }

    @Test("Removes fillers case-insensitively")
    func caseInsensitive() {
        #expect(FillerWordRemover.remove(from: "UM, hello") == "Hello")
    }

    @Test("Does not match filler as substring of another word")
    func substringNoMatch() {
        #expect(FillerWordRemover.remove(from: "umbrella") == "Umbrella")
    }

    @Test("Capitalizes after removal at sentence boundary")
    func capitalizationAtSentenceBoundary() {
        #expect(FillerWordRemover.remove(from: "OK. Um, that works.") == "OK. That works.")
    }

    @Test("Handles er filler word")
    func erFiller() {
        #expect(FillerWordRemover.remove(from: "I was, er, thinking") == "I was thinking")
    }

    @Test("Handles mhm filler word")
    func mhmFiller() {
        #expect(FillerWordRemover.remove(from: "Mhm, sure") == "Sure")
    }

    @Test("Handles ah filler word")
    func ahFiller() {
        #expect(FillerWordRemover.remove(from: "Ah, I see") == "I see")
    }

    @Test("Returns empty string for filler-only input")
    func fillerOnly() {
        #expect(FillerWordRemover.remove(from: "Um") == "")
    }

    @Test("Handles mm and mmm filler words")
    func mmFiller() {
        #expect(FillerWordRemover.remove(from: "Mm, I think so") == "I think so")
        #expect(FillerWordRemover.remove(from: "Mmm, that's good") == "That's good")
    }
}
