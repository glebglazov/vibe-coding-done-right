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
        
        // Formal style
        #expect(Style.formal.name == "Formal")
        #expect(Style.formal.isBuiltIn == true)
        #expect(Style.formal.isDefault == false)
        #expect(Style.formal.staticRules.capitalizeSentences == true)
        #expect(Style.formal.staticRules.endingPunctuation == .addIfAbsent)
    }
    
    @Test("Style round-trips through Codable")
    func codableRoundTrip() throws {
        let original = Style(
            id: UUID(),
            name: "Test",
            isBuiltIn: false,
            isDefault: false,
            staticRules: StaticStyleRules(capitalizeSentences: true, endingPunctuation: .preserve),
            dynamicPrompt: "Make it fancy",
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
        #expect(result == "hello")
    }
    
    @Test("Single capitalized word with casual rules: lowercase, remove dot")
    func singleWordCasualCapitalized() {
        let result = StyleTransformer.transform("Hello", using: .casual)
        #expect(result == "hello")
    }
    
    @Test("Single word with casual rules removes final period")
    func singleWordCasualRemovesPeriod() {
        let result = StyleTransformer.transform("Hello.", using: .casual)
        #expect(result == "hello")
    }
    
    @Test("Single word with casual rules preserves question mark")
    func singleWordCasualPreservesQuestion() {
        let result = StyleTransformer.transform("Hello?", using: .casual)
        #expect(result == "hello?")
    }
    
    @Test("Single word with casual rules preserves exclamation")
    func singleWordCasualPreservesExclamation() {
        let result = StyleTransformer.transform("Hello!", using: .casual)
        #expect(result == "hello!")
    }
    
    @Test("Single lowercase word with formal rules: capitalize, add dot")
    func singleWordFormalLowercase() {
        let result = StyleTransformer.transform("hello", using: .formal)
        #expect(result == "Hello.")
    }
    
    @Test("Single capitalized word with formal rules: keep caps, add dot")
    func singleWordFormalCapitalized() {
        let result = StyleTransformer.transform("Hello", using: .formal)
        #expect(result == "Hello.")
    }
    
    @Test("Single word with formal rules preserves existing period")
    func singleWordFormalPreservesPeriod() {
        let result = StyleTransformer.transform("Hello.", using: .formal)
        #expect(result == "Hello.")
    }
    
    @Test("Single word with formal rules preserves question mark")
    func singleWordFormalPreservesQuestion() {
        let result = StyleTransformer.transform("Hello?", using: .formal)
        #expect(result == "Hello?")
    }
}

// MARK: - Multi-Sentence Tests

@Suite("StyleTransformer - Multiple Sentences")
struct StyleTransformerMultiSentenceTests {
    
    @Test("Multiple sentences with casual rules: lowercase each, remove final dot")
    func multiSentenceCasual() {
        let result = StyleTransformer.transform("Hello world. This is a test. How are you?", using: .casual)
        #expect(result == "hello world. this is a test. how are you?")
    }
    
    @Test("Multiple sentences with formal rules: capitalize each, add final dot")
    func multiSentenceFormal() {
        let result = StyleTransformer.transform("hello world. this is a test. how are you", using: .formal)
        #expect(result == "Hello world. This is a test. How are you.")
    }
    
    @Test("Sentence boundary detection with question marks")
    func sentenceBoundaryQuestion() {
        let result = StyleTransformer.transform("How are you? I am fine", using: .formal)
        #expect(result == "How are you? I am fine.")
    }
    
    @Test("Sentence boundary detection with exclamation marks")
    func sentenceBoundaryExclamation() {
        let result = StyleTransformer.transform("hello world! this is great", using: .formal)
        #expect(result == "Hello world! This is great.")
    }
    
    @Test("Mixed punctuation boundaries")
    func mixedPunctuationBoundaries() {
        let result = StyleTransformer.transform("What? Really! No way", using: .formal)
        #expect(result == "What? Really! No way.")
    }
}

// MARK: - Proper Noun Preservation Tests

@Suite("StyleTransformer - Proper Noun Preservation")
struct StyleTransformerProperNounTests {
    
    @Test("Proper nouns mid-sentence are preserved in casual style")
    func properNounsPreservedCasual() {
        let result = StyleTransformer.transform("Hello Gleb, how are you?", using: .casual)
        #expect(result == "hello Gleb, how are you?")
    }
    
    @Test("Proper nouns mid-sentence are preserved in formal style")
    func properNounsPreservedFormal() {
        let result = StyleTransformer.transform("hello Gleb, how are you", using: .formal)
        #expect(result == "Hello Gleb, how are you.")
    }
    
    @Test("Internal capitalization preserved across sentences")
    func internalCapsAcrossSentences() {
        let result = StyleTransformer.transform("I met John. He said Hello to Sarah.", using: .casual)
        #expect(result == "i met John. he said Hello to Sarah")
    }
    
    @Test("Acronyms and mixed case preserved")
    func acronymsPreserved() {
        let result = StyleTransformer.transform("The NASA project at IBM is cool", using: .casual)
        #expect(result == "the NASA project at IBM is cool")
    }
}

// MARK: - Ending Punctuation Tests

@Suite("StyleTransformer - Ending Punctuation Rules")
struct StyleTransformerEndingPunctuationTests {
    
    // Casual: removeFinalDot
    
    @Test("Casual removes only final period, preserves internal")
    func casualRemovesOnlyFinalPeriod() {
        let result = StyleTransformer.transform("Hello. World.", using: .casual)
        #expect(result == "hello. world")
    }
    
    @Test("Casual preserves question mark at end")
    func casualPreservesQuestionAtEnd() {
        let result = StyleTransformer.transform("How are you?", using: .casual)
        #expect(result == "how are you?")
    }
    
    @Test("Casual preserves exclamation at end")
    func casualPreservesExclamationAtEnd() {
        let result = StyleTransformer.transform("Hello world!", using: .casual)
        #expect(result == "hello world!")
    }
    
    @Test("Casual removes period, keeps question mark after")
    func casualHandlesPeriodBeforeQuestion() {
        let result = StyleTransformer.transform("Wait. How are you?", using: .casual)
        #expect(result == "wait. how are you?")
    }
    
    // Formal: addIfAbsent
    
    @Test("Formal adds period if no ending punctuation")
    func formalAddsPeriod() {
        let result = StyleTransformer.transform("Hello world", using: .formal)
        #expect(result == "Hello world.")
    }
    
    @Test("Formal does not add period if already present")
    func formalPreservesExistingPeriod() {
        let result = StyleTransformer.transform("Hello world.", using: .formal)
        #expect(result == "Hello world.")
    }
    
    @Test("Formal does not add period if question mark present")
    func formalPreservesQuestion() {
        let result = StyleTransformer.transform("Hello world?", using: .formal)
        #expect(result == "Hello world?")
    }
    
    @Test("Formal does not add period if exclamation present")
    func formalPreservesExclamation() {
        let result = StyleTransformer.transform("Hello world!", using: .formal)
        #expect(result == "Hello world!")
    }
    
    // Preserve: no changes
    
    @Test("Preserve rule leaves text unchanged")
    func preserveRule() {
        let rules = StaticStyleRules(capitalizeSentences: true, endingPunctuation: .preserve)
        let result = StyleTransformer.transform("hello world", using: rules)
        #expect(result == "Hello world")
    }
    
    @Test("Preserve rule with existing period")
    func preserveRuleWithPeriod() {
        let rules = StaticStyleRules(capitalizeSentences: false, endingPunctuation: .preserve)
        let result = StyleTransformer.transform("Hello world.", using: rules)
        #expect(result == "hello world.")
    }
}

// MARK: - Edge Cases

@Suite("StyleTransformer - Edge Cases")
struct StyleTransformerEdgeCaseTests {
    
    @Test("Text with trailing whitespace preserves it")
    func trailingWhitespacePreserved() {
        let result = StyleTransformer.transform("Hello world   ", using: .formal)
        #expect(result == "Hello world.   ")
    }
    
    @Test("Text with internal multiple spaces preserved")
    func internalMultipleSpaces() {
        let result = StyleTransformer.transform("Hello   world", using: .formal)
        #expect(result == "Hello   world.")
    }
    
    @Test("Text with newlines as sentence separators")
    func newlinesAsSeparators() {
        // Newlines don't count as sentence boundaries without punctuation
        let result = StyleTransformer.transform("Hello\nWorld", using: .formal)
        #expect(result == "Hello\nWorld.")
    }
    
    @Test("All caps input with casual style")
    func allCapsCasual() {
        let result = StyleTransformer.transform("HELLO WORLD", using: .casual)
        #expect(result == "hELLO WORLD")
    }
    
    @Test("All caps input with formal style")
    func allCapsFormal() {
        let result = StyleTransformer.transform("HELLO WORLD", using: .formal)
        #expect(result == "HELLO WORLD.")
    }
    
    @Test("Single letter input")
    func singleLetter() {
        let resultCasual = StyleTransformer.transform("A", using: .casual)
        #expect(resultCasual == "a")
        
        let resultFormal = StyleTransformer.transform("a", using: .formal)
        #expect(resultFormal == "A.")
    }
    
    @Test("Numbers in text")
    func numbersInText() {
        let result = StyleTransformer.transform("I have 42 apples. 7 are red", using: .formal)
        #expect(result == "I have 42 apples. 7 are red.")
    }
    
    @Test("Punctuation other than sentence endings")
    func otherPunctuation() {
        let result = StyleTransformer.transform("Hello, world; it's me: Gleb", using: .casual)
        #expect(result == "hello, world; it's me: Gleb")
    }
    
    @Test("Multiple spaces after period")
    func multipleSpacesAfterPeriod() {
        let result = StyleTransformer.transform("Hello.  World", using: .formal)
        #expect(result == "Hello.  World.")
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
        #expect(result == "Héllo wörld.")
    }
    
    @Test("Emoji in text")
    func emojiInText() {
        let result = StyleTransformer.transform("hello world 🎉", using: .formal)
        #expect(result == "Hello world 🎉.")
    }
}

// MARK: - Real-World Examples

@Suite("StyleTransformer - Real-World Examples")
struct StyleTransformerRealWorldTests {
    
    @Test("Casual terminal command style")
    func casualTerminalStyle() {
        let input = "List all files in the current directory. Show hidden ones too."
        let result = StyleTransformer.transform(input, using: .casual)
        #expect(result == "list all files in the current directory. show hidden ones too")
    }
    
    @Test("Formal email style")
    func formalEmailStyle() {
        let input = "dear team, please review the attached document. let me know if you have questions"
        let result = StyleTransformer.transform(input, using: .formal)
        #expect(result == "Dear team, please review the attached document. Let me know if you have questions.")
    }
    
    @Test("Mixed casual conversation")
    func mixedCasualConversation() {
        let input = "Hey Gleb! How's it going? Just wanted to check in."
        let result = StyleTransformer.transform(input, using: .casual)
        #expect(result == "hey Gleb! how's it going? just wanted to check in")
    }
    
    @Test("Code-related text (Casual)")
    func codeRelatedCasual() {
        let input = "Run npm install. Then check the README."
        let result = StyleTransformer.transform(input, using: .casual)
        #expect(result == "run npm install. then check the README")
    }
}
