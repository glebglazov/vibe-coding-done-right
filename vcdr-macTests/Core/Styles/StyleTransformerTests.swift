import Foundation
import Testing
@testable import vcdr_mac

// MARK: - Style Model Tests

@Suite("Style Models")
struct StyleModelTests {

    @Test("Style has stable UUIDs for built-in styles")
    func stableUUIDs() {
        // Casual ID should be stable
        let casualID1 = Style.casualID
        let casualID2 = Style.casual.id
        #expect(casualID1 == casualID2)
        #expect(casualID1.uuidString == "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")

        // Messaging ID should be stable
        let messagingID1 = Style.messagingID
        let messagingID2 = Style.messaging.id
        #expect(messagingID1 == messagingID2)
        #expect(messagingID1.uuidString == "C3D4E5F6-A7B8-4C9D-AE1F-2A3B4C5D6E7F")

        // Formal ID should be stable
        let formalID1 = Style.formalID
        let formalID2 = Style.formal.id
        #expect(formalID1 == formalID2)
        #expect(formalID1.uuidString == "B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E")
    }

    @Test("Built-in styles have correct properties")
    func builtInStylesProperties() {
        // Casual style
        #expect(Style.casual.name == "Casual")
        #expect(Style.casual.isBuiltIn == true)
        #expect(Style.casual.isDefault == true)
        #expect(Style.casual.staticRules.capitalizeSentences == false)
        #expect(Style.casual.staticRules.endingPunctuation == .removeFinalDot)

        // Messaging style
        #expect(Style.messaging.name == "Messaging")
        #expect(Style.messaging.isBuiltIn == true)
        #expect(Style.messaging.isDefault == false)
        #expect(Style.messaging.staticRules.capitalizeSentences == true)
        #expect(Style.messaging.staticRules.endingPunctuation == .removeFinalDot)

        // Formal style
        #expect(Style.formal.name == "Formal")
        #expect(Style.formal.isBuiltIn == true)
        #expect(Style.formal.isDefault == false)
        #expect(Style.formal.staticRules.capitalizeSentences == true)
        #expect(Style.formal.staticRules.endingPunctuation == .addIfAbsent)
    }

    @Test("Built-in styles are ordered: casual, messaging, formal")
    func builtInOrdering() {
        #expect(Style.builtIn.count == 3)
        #expect(Style.builtIn[0].id == Style.casualID)
        #expect(Style.builtIn[1].id == Style.messagingID)
        #expect(Style.builtIn[2].id == Style.formalID)
    }

    @Test("Style round-trips through Codable")
    func codableRoundTrip() throws {
        let original = Style(
            id: UUID(),
            name: "Test",
            isBuiltIn: false,
            isDefault: false,
            staticRules: StaticStyleRules(capitalizeSentences: true, endingPunctuation: .preserve),
            associatedAppBundleIDs: ["com.test.app"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Style.self, from: data)

        #expect(decoded == original)
    }

    @Test("StaticStyleRules round-trips through Codable")
    func staticRulesCodable() throws {
        let original = StaticStyleRules(capitalizeSentences: false, endingPunctuation: .removeFinalDot)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StaticStyleRules.self, from: data)

        #expect(decoded == original)
    }

    @Test("PunctuationRule is Equatable")
    func punctuationRuleEquality() {
        #expect(PunctuationRule.addIfAbsent == PunctuationRule.addIfAbsent)
        #expect(PunctuationRule.removeFinalDot == PunctuationRule.removeFinalDot)
        #expect(PunctuationRule.preserve == PunctuationRule.preserve)
        #expect(PunctuationRule.addIfAbsent != PunctuationRule.removeFinalDot)
    }
}

// MARK: - Empty String Tests

@Suite("StyleTransformer - Empty Input")
struct StyleTransformerEmptyTests {

    @Test("Empty string returns empty string for casual rules")
    func emptyStringCasual() {
        let result = StyleTransformer.transform("", using: .casual)
        #expect(result == "")
    }

    @Test("Empty string returns empty string for formal rules")
    func emptyStringFormal() {
        let result = StyleTransformer.transform("", using: .formal)
        #expect(result == "")
    }

    @Test("Whitespace-only string returns unchanged for casual rules")
    func whitespaceOnlyCasual() {
        let result = StyleTransformer.transform("   ", using: .casual)
        #expect(result == "   ")
    }

    @Test("Whitespace-only string returns unchanged for formal rules")
    func whitespaceOnlyFormal() {
        let result = StyleTransformer.transform("   ", using: .formal)
        #expect(result == "   ")
    }

    @Test("Newline-only string returns unchanged")
    func newlineOnly() {
        let result = StyleTransformer.transform("\n\n", using: .formal)
        #expect(result == "\n\n")
    }
}

// MARK: - Single Word Tests

@Suite("StyleTransformer - Single Word")
struct StyleTransformerSingleWordTests {

    @Test("Single lowercase word with casual rules: lowercase, remove dot")
    func singleWordCasualLowercase() {
        let result = StyleTransformer.transform("hello", using: .casual)
        #expect(result == "hello ")
    }

    @Test("Single capitalized word with casual rules: lowercase, remove dot")
    func singleWordCasualCapitalized() {
        let result = StyleTransformer.transform("Hello", using: .casual)
        #expect(result == "hello ")
    }

    @Test("Single word with casual rules removes final period")
    func singleWordCasualRemovesPeriod() {
        let result = StyleTransformer.transform("Hello.", using: .casual)
        #expect(result == "hello ")
    }

    @Test("Single word with casual rules preserves question mark")
    func singleWordCasualPreservesQuestion() {
        let result = StyleTransformer.transform("Hello?", using: .casual)
        #expect(result == "hello? ")
    }

    @Test("Single word with casual rules preserves exclamation")
    func singleWordCasualPreservesExclamation() {
        let result = StyleTransformer.transform("Hello!", using: .casual)
        #expect(result == "hello! ")
    }

    @Test("Single lowercase word with formal rules: capitalize, add dot")
    func singleWordFormalLowercase() {
        let result = StyleTransformer.transform("hello", using: .formal)
        #expect(result == "Hello. ")
    }

    @Test("Single capitalized word with formal rules: keep caps, add dot")
    func singleWordFormalCapitalized() {
        let result = StyleTransformer.transform("Hello", using: .formal)
        #expect(result == "Hello. ")
    }

    @Test("Single word with formal rules preserves existing period")
    func singleWordFormalPreservesPeriod() {
        let result = StyleTransformer.transform("Hello.", using: .formal)
        #expect(result == "Hello. ")
    }

    @Test("Single word with formal rules preserves question mark")
    func singleWordFormalPreservesQuestion() {
        let result = StyleTransformer.transform("Hello?", using: .formal)
        #expect(result == "Hello? ")
    }
}

// MARK: - Multi-Sentence Tests

@Suite("StyleTransformer - Multiple Sentences")
struct StyleTransformerMultiSentenceTests {

    @Test("Multiple sentences with casual rules: lowercase each, remove final dot")
    func multiSentenceCasual() {
        let result = StyleTransformer.transform("Hello world. This is a test. How are you?", using: .casual)
        #expect(result == "hello world. this is a test. how are you? ")
    }

    @Test("Multiple sentences with formal rules: capitalize each, add final dot")
    func multiSentenceFormal() {
        let result = StyleTransformer.transform("hello world. this is a test. how are you", using: .formal)
        #expect(result == "Hello world. This is a test. How are you. ")
    }

    @Test("Sentence boundary detection with question marks")
    func sentenceBoundaryQuestion() {
        let result = StyleTransformer.transform("How are you? I am fine", using: .formal)
        #expect(result == "How are you? I am fine. ")
    }

    @Test("Sentence boundary detection with exclamation marks")
    func sentenceBoundaryExclamation() {
        let result = StyleTransformer.transform("hello world! this is great", using: .formal)
        #expect(result == "Hello world! This is great. ")
    }

    @Test("Mixed punctuation boundaries")
    func mixedPunctuationBoundaries() {
        let result = StyleTransformer.transform("What? Really! No way", using: .formal)
        #expect(result == "What? Really! No way. ")
    }
}

// MARK: - Proper Noun Preservation Tests

@Suite("StyleTransformer - Proper Noun Preservation")
struct StyleTransformerProperNounTests {

    @Test("Proper nouns mid-sentence are preserved in casual style")
    func properNounsPreservedCasual() {
        let result = StyleTransformer.transform("Hello Gleb, how are you?", using: .casual)
        #expect(result == "hello Gleb, how are you? ")
    }

    @Test("Proper nouns mid-sentence are preserved in formal style")
    func properNounsPreservedFormal() {
        let result = StyleTransformer.transform("hello Gleb, how are you", using: .formal)
        #expect(result == "Hello Gleb, how are you. ")
    }

    @Test("Internal capitalization preserved across sentences")
    func internalCapsAcrossSentences() {
        let result = StyleTransformer.transform("I met John. He said Hello to Sarah.", using: .casual)
        #expect(result == "i met John. he said Hello to Sarah ")
    }

    @Test("Acronyms and mixed case preserved")
    func acronymsPreserved() {
        let result = StyleTransformer.transform("The NASA project at IBM is cool", using: .casual)
        #expect(result == "the NASA project at IBM is cool ")
    }
}

// MARK: - Ending Punctuation Tests

@Suite("StyleTransformer - Ending Punctuation Rules")
struct StyleTransformerEndingPunctuationTests {

    // Casual: removeFinalDot

    @Test("Casual removes only final period, preserves internal")
    func casualRemovesOnlyFinalPeriod() {
        let result = StyleTransformer.transform("Hello. World.", using: .casual)
        #expect(result == "hello. world ")
    }

    @Test("Casual preserves question mark at end")
    func casualPreservesQuestionAtEnd() {
        let result = StyleTransformer.transform("How are you?", using: .casual)
        #expect(result == "how are you? ")
    }

    @Test("Casual preserves exclamation at end")
    func casualPreservesExclamationAtEnd() {
        let result = StyleTransformer.transform("Hello world!", using: .casual)
        #expect(result == "hello world! ")
    }

    @Test("Casual removes period, keeps question mark after")
    func casualHandlesPeriodBeforeQuestion() {
        let result = StyleTransformer.transform("Wait. How are you?", using: .casual)
        #expect(result == "wait. how are you? ")
    }

    // Formal: addIfAbsent

    @Test("Formal adds period if no ending punctuation")
    func formalAddsPeriod() {
        let result = StyleTransformer.transform("Hello world", using: .formal)
        #expect(result == "Hello world. ")
    }

    @Test("Formal does not add period if already present")
    func formalPreservesExistingPeriod() {
        let result = StyleTransformer.transform("Hello world.", using: .formal)
        #expect(result == "Hello world. ")
    }

    @Test("Formal does not add period if question mark present")
    func formalPreservesQuestion() {
        let result = StyleTransformer.transform("Hello world?", using: .formal)
        #expect(result == "Hello world? ")
    }

    @Test("Formal does not add period if exclamation present")
    func formalPreservesExclamation() {
        let result = StyleTransformer.transform("Hello world!", using: .formal)
        #expect(result == "Hello world! ")
    }

    // Messaging: capitalizeSentences + removeFinalDot

    @Test("Messaging capitalizes and strips final period")
    func messagingCapitalizesAndStripsDot() {
        let result = StyleTransformer.transform("hello world.", using: .messaging)
        #expect(result == "Hello world ")
    }

    @Test("Messaging does not add a period when absent")
    func messagingDoesNotAddPeriod() {
        let result = StyleTransformer.transform("hello world", using: .messaging)
        #expect(result == "Hello world ")
    }

    @Test("Messaging preserves question mark")
    func messagingPreservesQuestion() {
        let result = StyleTransformer.transform("how are you?", using: .messaging)
        #expect(result == "How are you? ")
    }

    @Test("Messaging preserves exclamation")
    func messagingPreservesExclamation() {
        let result = StyleTransformer.transform("great job!", using: .messaging)
        #expect(result == "Great job! ")
    }

    @Test("Messaging capitalizes across sentences, drops trailing dot")
    func messagingMultipleSentences() {
        let result = StyleTransformer.transform("hello world. how are you? i am fine.", using: .messaging)
        #expect(result == "Hello world. How are you? I am fine ")
    }

    // Preserve: no changes

    @Test("Preserve rule leaves text unchanged")
    func preserveRule() {
        let rules = StaticStyleRules(capitalizeSentences: true, endingPunctuation: .preserve)
        let result = StyleTransformer.transform("hello world", using: rules)
        #expect(result == "Hello world ")
    }

    @Test("Preserve rule with existing period")
    func preserveRuleWithPeriod() {
        let rules = StaticStyleRules(capitalizeSentences: false, endingPunctuation: .preserve)
        let result = StyleTransformer.transform("Hello world.", using: rules)
        #expect(result == "hello world. ")
    }
}

// MARK: - Edge Cases

@Suite("StyleTransformer - Edge Cases")
struct StyleTransformerEdgeCaseTests {

    @Test("Text with trailing whitespace — trailing space replaces original")
    func trailingWhitespaceReplaced() {
        let result = StyleTransformer.transform("Hello world   ", using: .formal)
        #expect(result == "Hello world. ")
    }

    @Test("Text with internal multiple spaces preserved")
    func internalMultipleSpaces() {
        let result = StyleTransformer.transform("Hello   world", using: .formal)
        #expect(result == "Hello   world. ")
    }

    @Test("Text with newlines as sentence separators")
    func newlinesAsSeparators() {
        // Newlines don't count as sentence boundaries without punctuation
        let result = StyleTransformer.transform("Hello\nWorld", using: .formal)
        #expect(result == "Hello\nWorld. ")
    }

    @Test("All caps input with casual style")
    func allCapsCasual() {
        let result = StyleTransformer.transform("HELLO WORLD", using: .casual)
        #expect(result == "hELLO WORLD ")
    }

    @Test("All caps input with formal style")
    func allCapsFormal() {
        let result = StyleTransformer.transform("HELLO WORLD", using: .formal)
        #expect(result == "HELLO WORLD. ")
    }

    @Test("Single letter input")
    func singleLetter() {
        let resultCasual = StyleTransformer.transform("A", using: .casual)
        #expect(resultCasual == "a ")

        let resultFormal = StyleTransformer.transform("a", using: .formal)
        #expect(resultFormal == "A. ")
    }

    @Test("Numbers in text")
    func numbersInText() {
        let result = StyleTransformer.transform("I have 42 apples. 7 are red", using: .formal)
        #expect(result == "I have 42 apples. 7 are red. ")
    }

    @Test("Punctuation other than sentence endings")
    func otherPunctuation() {
        let result = StyleTransformer.transform("Hello, world; it's me: Gleb", using: .casual)
        #expect(result == "hello, world; it's me: Gleb ")
    }

    @Test("Multiple spaces after period")
    func multipleSpacesAfterPeriod() {
        let result = StyleTransformer.transform("Hello.  World", using: .formal)
        #expect(result == "Hello.  World. ")
    }

    @Test("Empty string with preserve rule")
    func emptyWithPreserveRule() {
        let rules = StaticStyleRules(capitalizeSentences: true, endingPunctuation: .preserve)
        let result = StyleTransformer.transform("", using: rules)
        #expect(result == "")
    }

    @Test("Unicode text")
    func unicodeText() {
        let result = StyleTransformer.transform("héllo wörld", using: .formal)
        #expect(result == "Héllo wörld. ")
    }

    @Test("Emoji in text")
    func emojiInText() {
        let result = StyleTransformer.transform("hello world 🎉", using: .formal)
        #expect(result == "Hello world 🎉. ")
    }
}

// MARK: - Real-World Examples

@Suite("StyleTransformer - Real-World Examples")
struct StyleTransformerRealWorldTests {

    @Test("Casual terminal command style")
    func casualTerminalStyle() {
        let input = "List all files in the current directory. Show hidden ones too."
        let result = StyleTransformer.transform(input, using: .casual)
        #expect(result == "list all files in the current directory. show hidden ones too ")
    }

    @Test("Formal email style")
    func formalEmailStyle() {
        let input = "dear team, please review the attached document. let me know if you have questions"
        let result = StyleTransformer.transform(input, using: .formal)
        #expect(result == "Dear team, please review the attached document. Let me know if you have questions. ")
    }

    @Test("Mixed casual conversation")
    func mixedCasualConversation() {
        let input = "Hey Gleb! How's it going? Just wanted to check in."
        let result = StyleTransformer.transform(input, using: .casual)
        #expect(result == "hey Gleb! how's it going? just wanted to check in ")
    }

    @Test("Code-related text (Casual)")
    func codeRelatedCasual() {
        let input = "Run npm install. Then check the README."
        let result = StyleTransformer.transform(input, using: .casual)
        #expect(result == "run npm install. then check the README ")
    }
}

// MARK: - Context-Aware Capitalization Tests

@Suite("StyleTransformer - Context-Aware Capitalization")
struct StyleTransformerContextAwareTests {

    // MARK: - Formal Mode with Context

    @Test("Formal: Capitalize after period")
    func formalCapitalizeAfterPeriod() {
        let context = CursorContext(beforeText: "hello.", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("how are you", using: .formal, cursorContext: context)
        // Capitalizes and adds space since context ends with terminator
        #expect(result == " How are you. ")
    }

    @Test("Formal: Capitalize after period with space")
    func formalCapitalizeAfterPeriodWithSpace() {
        let context = CursorContext(beforeText: "hello. ", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("how are you", using: .formal, cursorContext: context)
        // Context already has space - no additional separator needed
        #expect(result == "How are you. ")
    }

    @Test("Formal: Capitalize after exclamation (adds space)")
    func formalCapitalizeAfterExclamation() {
        let context = CursorContext(beforeText: "wow!", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("that was great", using: .formal, cursorContext: context)
        // Adds space since context ends with terminator
        #expect(result == " That was great. ")
    }

    @Test("Formal: Capitalize after question mark (adds space)")
    func formalCapitalizeAfterQuestion() {
        let context = CursorContext(beforeText: "really?", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("yes indeed", using: .formal, cursorContext: context)
        // Adds space since context ends with terminator
        #expect(result == " Yes indeed. ")
    }

    @Test("Formal: Capitalize in empty field")
    func formalCapitalizeInEmptyField() {
        let context = CursorContext(beforeText: "", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("how are you", using: .formal, cursorContext: context)
        #expect(result == "How are you. ")
    }

    @Test("Formal: Don't capitalize after comma (adds separator)")
    func formalDontCapitalizeAfterComma() {
        let context = CursorContext(beforeText: "hello,", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("How are you", using: .formal, cursorContext: context)
        // First char left untouched, ". " separator added since comma is not terminator/whitespace
        #expect(result == ". How are you. ")
    }

    @Test("Formal: Don't capitalize after comma with lowercase input (adds separator)")
    func formalDontCapitalizeAfterCommaLowercaseInput() {
        let context = CursorContext(beforeText: "hello,", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("how are you", using: .formal, cursorContext: context)
        // First char left untouched (lowercase stays lowercase), ". " separator added
        #expect(result == ". how are you. ")
    }

    @Test("Formal: Don't capitalize after word with trailing space")
    func formalDontCapitalizeAfterWordWithSpace() {
        let context = CursorContext(beforeText: "hello ", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("world", using: .formal, cursorContext: context)
        // First char left untouched (lowercase stays lowercase)
        #expect(result == "world. ")
    }

    @Test("Formal: Don't capitalize after plain word (adds separator)")
    func formalDontCapitalizeAfterPlainWord() {
        let context = CursorContext(beforeText: "hello", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("world", using: .formal, cursorContext: context)
        // First char left untouched, adds ". " separator since context doesn't end with whitespace
        #expect(result == ". world. ")
    }

    @Test("Formal: Adds space only after terminator")
    func formalAddsSpaceOnlyAfterTerminator() {
        let context = CursorContext(beforeText: "hello.", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("world", using: .formal, cursorContext: context)
        // Context ends with terminator - just add space, not another period
        #expect(result == " World. ")
    }

    // MARK: - Casual Mode with Context

    @Test("Casual: Lowercase after period (adds space)")
    func casualLowercaseAfterPeriod() {
        let context = CursorContext(beforeText: "hello.", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("How are you", using: .casual, cursorContext: context)
        // Lowercases first char, adds space since context ends with terminator
        #expect(result == " how are you ")
    }

    @Test("Casual: Lowercase in empty field")
    func casualLowercaseInEmptyField() {
        let context = CursorContext(beforeText: "", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("How are you", using: .casual, cursorContext: context)
        #expect(result == "how are you ")
    }

    @Test("Casual: Lowercase mid-sentence (adds separator)")
    func casualLowercaseMidSentence() {
        let context = CursorContext(beforeText: "hello,", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("How are you", using: .casual, cursorContext: context)
        // Casual mode always lowercases first character, ". " separator added for comma context
        #expect(result == ". how are you ")
    }

    @Test("Casual: Lowercase after word without terminator (adds separator)")
    func casualAddsSeparatorWhenNoTerminator() {
        let context = CursorContext(beforeText: "hello", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("How are you", using: .casual, cursorContext: context)
        // Casual mode adds ". " separator when context doesn't end with whitespace or terminator
        #expect(result == ". how are you ")
    }

    @Test("Casual: Adds space only after terminator")
    func casualAddsSpaceOnlyAfterTerminator() {
        let context = CursorContext(beforeText: "hello.", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("How are you", using: .casual, cursorContext: context)
        // Context ends with terminator - just add space, not another period
        #expect(result == " how are you ")
    }

    @Test("Casual: No separator when context ends with space")
    func casualNoSeparatorWhenContextHasSpace() {
        let context = CursorContext(beforeText: "hello ", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("How are you", using: .casual, cursorContext: context)
        // Context already ends with space - no separator needed
        #expect(result == "how are you ")
    }

    // MARK: - Nil Context Tests (Current Behavior)

    @Test("Nil context: Formal current behavior")
    func nilContextFormal() {
        let result = StyleTransformer.transform("hello world", using: .formal, cursorContext: nil)
        #expect(result == "Hello world. ")
    }

    @Test("Nil context: Casual current behavior")
    func nilContextCasual() {
        let result = StyleTransformer.transform("Hello World", using: .casual, cursorContext: nil)
        #expect(result == "hello World ")
    }

    @Test("Nil context: Formal single word")
    func nilContextFormalSingleWord() {
        let result = StyleTransformer.transform("hello", using: .formal, cursorContext: nil)
        #expect(result == "Hello. ")
    }

    @Test("Nil context: Casual single word")
    func nilContextCasualSingleWord() {
        let result = StyleTransformer.transform("Hello", using: .casual, cursorContext: nil)
        #expect(result == "hello ")
    }

    // MARK: - Edge Cases

    @Test("Context with Unicode first character - Formal")
    func unicodeFirstCharacterFormal() {
        let context = CursorContext(beforeText: "hello.", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("über", using: .formal, cursorContext: context)
        #expect(result == " Über. ")
    }

    @Test("Context with Unicode first character - Casual")
    func unicodeFirstCharacterCasual() {
        let context = CursorContext(beforeText: "hello.", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("Über", using: .casual, cursorContext: context)
        #expect(result == " über ")
    }

    @Test("Context with Unicode first character mid-sentence - leave untouched (adds separator)")
    func unicodeFirstCharacterMidSentence() {
        let context = CursorContext(beforeText: "hello,", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("über cool", using: .formal, cursorContext: context)
        // First char left untouched, ". " separator added for comma context
        #expect(result == ". über cool. ")
    }

    @Test("Context with emoji at end after terminator - emoji is whitespace? No, it's content")
    func emojiAtEndNotWhitespace() {
        // This test documents that emoji is treated as content, not whitespace
        // So "hello!🎉" would NOT match the terminator pattern because there's no whitespace
        // and the emoji is non-whitespace content after the !
        let context = CursorContext(beforeText: "hello!🎉", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("how are you", using: .formal, cursorContext: context)
        // No whitespace between ! and emoji, so not a sentence boundary — adds ". " separator
        #expect(result == ". how are you. ")
    }

    @Test("Context with emoji in beforeText - terminator before emoji leaves untouched")
    func emojiInBeforeTextTerminatorBefore() {
        let context = CursorContext(beforeText: "hello! 🎉", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("how are you", using: .formal, cursorContext: context)
        // Ends with "! 🎉" - the emoji is non-whitespace content after the terminator,
        // so the cursor is NOT at a sentence boundary. Adds ". " separator.
        #expect(result == ". how are you. ")
    }

    @Test("Context with multiple terminators")
    func multipleTerminators() {
        let context = CursorContext(beforeText: "really?!", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("yes indeed", using: .formal, cursorContext: context)
        // Ends with ! which matches terminator pattern — adds space separator
        #expect(result == " Yes indeed. ")
    }

    @Test("Context with whitespace-only beforeText")
    func whitespaceOnlyBeforeText() {
        let context = CursorContext(beforeText: "   ", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("hello world", using: .formal, cursorContext: context)
        #expect(result == "Hello world. ")
    }

    @Test("Context with newlines in beforeText")
    func newlinesInBeforeText() {
        let context = CursorContext(beforeText: "hello.\n\n", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("world", using: .formal, cursorContext: context)
        // Ends with period followed by whitespace (including newlines)
        #expect(result == "World. ")
    }

    @Test("Context with trailing whitespace in beforeText - period")
    func trailingWhitespaceAfterPeriod() {
        let context = CursorContext(beforeText: "hello.   ", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("world", using: .formal, cursorContext: context)
        #expect(result == "World. ")
    }

    @Test("Context with trailing whitespace in beforeText - question")
    func trailingWhitespaceAfterQuestion() {
        let context = CursorContext(beforeText: "hello?  ", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("world", using: .formal, cursorContext: context)
        #expect(result == "World. ")
    }

    @Test("Context with beforeText nil in CursorContext")
    func beforeTextNilInContext() {
        let context = CursorContext(beforeText: nil, afterText: "after", sourceBundleID: nil)
        let result = StyleTransformer.transform("hello world", using: .formal, cursorContext: context)
        // When beforeText is nil, treat as boundary (apply style rule)
        #expect(result == "Hello world. ")
    }

    @Test("Internal sentence boundaries still work with context")
    func internalBoundariesWithContext() {
        let context = CursorContext(beforeText: "hello.", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("how are you. i am fine", using: .formal, cursorContext: context)
        // Leading edge capitalized (after period), internal boundary also capitalized
        #expect(result == " How are you. I am fine. ")
    }

    @Test("Internal sentence boundaries with casual style")
    func internalBoundariesWithCasual() {
        let context = CursorContext(beforeText: "hello.", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("How are you. I am fine", using: .casual, cursorContext: context)
        // Leading edge lowercased (after period), internal boundary also lowercased
        #expect(result == " how are you. i am fine ")
    }

    @Test("Mid-sentence context leaves first char untouched but internal boundaries still work")
    func midSentenceInternalBoundaries() {
        let context = CursorContext(beforeText: "hello,", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("How are you. I am fine", using: .casual, cursorContext: context)
        // Casual always lowercases, ". " separator added for comma context, internal boundary lowercased
        #expect(result == ". how are you. i am fine ")
    }

    @Test("Colon in beforeText - leave untouched (adds separator)")
    func colonInBeforeText() {
        let context = CursorContext(beforeText: "hello:", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("how are you", using: .formal, cursorContext: context)
        // Colon is not a sentence terminator, first char left untouched, ". " separator added
        #expect(result == ". how are you. ")
    }

    @Test("Semicolon in beforeText - leave untouched (adds separator)")
    func semicolonInBeforeText() {
        let context = CursorContext(beforeText: "hello;", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("how are you", using: .formal, cursorContext: context)
        // Semicolon is not a sentence terminator, first char left untouched, ". " separator added
        #expect(result == ". how are you. ")
    }

    @Test("Closing parenthesis in beforeText - leave untouched (adds separator)")
    func closingParenInBeforeText() {
        let context = CursorContext(beforeText: "hello)", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("how are you", using: .formal, cursorContext: context)
        // Parenthesis is not a sentence terminator, first char left untouched, ". " separator added
        #expect(result == ". how are you. ")
    }

    @Test("Quote in beforeText - leave untouched (adds separator)")
    func quoteInBeforeText() {
        let context = CursorContext(beforeText: "hello\"", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("how are you", using: .formal, cursorContext: context)
        // Quote is not a sentence terminator, first char left untouched, ". " separator added
        #expect(result == ". how are you. ")
    }

    @Test("Capitalize after period with tab whitespace")
    func capitalizeAfterPeriodWithTab() {
        let context = CursorContext(beforeText: "hello.\t", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("world", using: .formal, cursorContext: context)
        #expect(result == "World. ")
    }

    @Test("Complex emoji in beforeText - not at boundary due to emoji content")
    func complexEmojiInBeforeText() {
        let context = CursorContext(beforeText: "hello! 👨‍👩‍👧‍👦", afterText: nil, sourceBundleID: nil)
        let result = StyleTransformer.transform("world", using: .formal, cursorContext: context)
        // The emoji is content between the terminator and cursor, so NOT at sentence boundary.
        // First char should be left untouched. ". " separator added.
        #expect(result == ". world. ")
    }
}
