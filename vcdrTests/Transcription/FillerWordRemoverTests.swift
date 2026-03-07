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

    @Test("Collapses double period when filler is its own sentence")
    func fillerAsSeparateSentence() {
        #expect(FillerWordRemover.remove(from: "I think so. Um.") == "I think so.")
        #expect(FillerWordRemover.remove(from: "I think so. Mm.") == "I think so.")
        #expect(FillerWordRemover.remove(from: "I think so. Er.") == "I think so.")
        #expect(FillerWordRemover.remove(from: "I think so. Ah.") == "I think so.")
    }

    @Test("Handles filler sentence between two sentences")
    func fillerBetweenSentences() {
        #expect(FillerWordRemover.remove(from: "First. Um. Second.") == "First. Second.")
    }

    @Test("Returns empty string for filler-only input with period")
    func fillerOnlyWithPeriod() {
        #expect(FillerWordRemover.remove(from: "Um.") == "")
    }

    @Test("Preserves sentence boundary when comma-wrapped filler precedes uppercase")
    func sentenceBoundaryPreservation() {
        #expect(FillerWordRemover.remove(from: "What, um, Yeah") == "What. Yeah")
        #expect(FillerWordRemover.remove(from: "So, uh, That works") == "So. That works")
        #expect(FillerWordRemover.remove(from: "OK, hmm, Let me think") == "OK. Let me think")
    }

    @Test("Does not add period when comma-wrapped filler precedes lowercase")
    func noSentenceBoundaryForLowercase() {
        #expect(FillerWordRemover.remove(from: "I was, um, going") == "I was going")
        #expect(FillerWordRemover.remove(from: "So, uh, yeah that works") == "So yeah that works")
    }

    // MARK: - Russian Fillers

    @Test("Removes Russian эм filler")
    func russianEmFiller() {
        #expect(FillerWordRemover.remove(from: "Я думаю, эм, что да") == "Я думаю что да")
    }

    @Test("Removes Russian э filler")
    func russianEFiller() {
        #expect(FillerWordRemover.remove(from: "Э, подожди") == "Подожди")
    }

    @Test("Does not match э inside Russian words")
    func russianSubstringNoMatch() {
        #expect(FillerWordRemover.remove(from: "Это хорошо") == "Это хорошо")
    }

    @Test("Handles repeated Russian fillers")
    func russianRepeatedFillers() {
        #expect(FillerWordRemover.remove(from: "Ээм, ладно") == "Ладно")
    }

    @Test("Preserves sentence boundary for Russian comma-wrapped filler before uppercase")
    func russianSentenceBoundary() {
        #expect(FillerWordRemover.remove(from: "Ладно, эм, Давай попробуем") == "Ладно. Давай попробуем")
    }
}
