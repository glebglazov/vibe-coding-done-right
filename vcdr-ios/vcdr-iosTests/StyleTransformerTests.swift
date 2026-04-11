import Testing
@testable import vcdr_ios

/// Tests for StyleTransformer — pure function text transformation
@Suite("StyleTransformer Tests")
struct StyleTransformerTests {
    
    // MARK: - Casual Style Tests
    
    @Test("Casual style lowercases first letter")
    func casualLowercasesFirstLetter() {
        let rules = StaticStyleRules.casual
        let result = StyleTransformer.transform("Hello world", using: rules)
        #expect(result == "hello world")
    }
    
    @Test("Casual style removes final period")
    func casualRemovesFinalPeriod() {
        let rules = StaticStyleRules.casual
        let result = StyleTransformer.transform("Hello.", using: rules)
        #expect(result == "hello")
    }
    
    @Test("Casual style preserves question marks")
    func casualPreservesQuestionMark() {
        let rules = StaticStyleRules.casual
        let result = StyleTransformer.transform("How are you?", using: rules)
        #expect(result == "how are you?")
    }
    
    @Test("Casual style preserves exclamation points")
    func casualPreservesExclamation() {
        let rules = StaticStyleRules.casual
        let result = StyleTransformer.transform("Great job!", using: rules)
        #expect(result == "great job!")
    }
    
    @Test("Casual style handles multiple sentences")
    func casualMultipleSentences() {
        let rules = StaticStyleRules.casual
        let result = StyleTransformer.transform("Hello. How are you? I'm fine.", using: rules)
        #expect(result == "hello. how are you? i'm fine")
    }
    
    @Test("Casual style handles empty string")
    func casualEmptyString() {
        let rules = StaticStyleRules.casual
        let result = StyleTransformer.transform("", using: rules)
        #expect(result == "")
    }
    
    @Test("Casual style handles whitespace only")
    func casualWhitespaceOnly() {
        let rules = StaticStyleRules.casual
        let result = StyleTransformer.transform("   ", using: rules)
        #expect(result == "   ")
    }
    
    @Test("Casual style preserves internal capitalization")
    func casualPreservesInternalCaps() {
        let rules = StaticStyleRules.casual
        let result = StyleTransformer.transform("Hello Gleb", using: rules)
        #expect(result == "hello Gleb")
    }
    
    @Test("Casual style handles single word")
    func casualSingleWord() {
        let rules = StaticStyleRules.casual
        let result = StyleTransformer.transform("Hello", using: rules)
        #expect(result == "hello")
    }
    
    @Test("Casual style handles trailing whitespace")
    func casualTrailingWhitespace() {
        let rules = StaticStyleRules.casual
        let result = StyleTransformer.transform("Hello.  ", using: rules)
        #expect(result == "hello  ")
    }
    
    // MARK: - Formal Style Tests
    
    @Test("Formal style capitalizes first letter")
    func formalCapitalizesFirstLetter() {
        let rules = StaticStyleRules.formal
        let result = StyleTransformer.transform("hello world", using: rules)
        #expect(result == "Hello world.")
    }
    
    @Test("Formal style adds period if absent")
    func formalAddsPeriod() {
        let rules = StaticStyleRules.formal
        let result = StyleTransformer.transform("Hello", using: rules)
        #expect(result == "Hello.")
    }
    
    @Test("Formal style preserves existing period")
    func formalPreservesPeriod() {
        let rules = StaticStyleRules.formal
        let result = StyleTransformer.transform("Hello.", using: rules)
        #expect(result == "Hello.")
    }
    
    @Test("Formal style preserves question marks")
    func formalPreservesQuestionMark() {
        let rules = StaticStyleRules.formal
        let result = StyleTransformer.transform("how are you?", using: rules)
        #expect(result == "How are you?")
    }
    
    @Test("Formal style preserves exclamation points")
    func formalPreservesExclamation() {
        let rules = StaticStyleRules.formal
        let result = StyleTransformer.transform("great job!", using: rules)
        #expect(result == "Great job!")
    }
    
    @Test("Formal style handles multiple sentences")
    func formalMultipleSentences() {
        let rules = StaticStyleRules.formal
        let result = StyleTransformer.transform("hello. how are you? i'm fine", using: rules)
        #expect(result == "Hello. How are you? I'm fine.")
    }
    
    @Test("Formal style handles empty string")
    func formalEmptyString() {
        let rules = StaticStyleRules.formal
        let result = StyleTransformer.transform("", using: rules)
        #expect(result == "")
    }
    
    @Test("Formal style handles whitespace only")
    func formalWhitespaceOnly() {
        let rules = StaticStyleRules.formal
        let result = StyleTransformer.transform("   ", using: rules)
        #expect(result == "   ")
    }
    
    @Test("Formal style preserves internal capitalization")
    func formalPreservesInternalCaps() {
        let rules = StaticStyleRules.formal
        let result = StyleTransformer.transform("hello Gleb", using: rules)
        #expect(result == "Hello Gleb.")
    }
    
    @Test("Formal style handles single word")
    func formalSingleWord() {
        let rules = StaticStyleRules.formal
        let result = StyleTransformer.transform("hello", using: rules)
        #expect(result == "Hello.")
    }
    
    // MARK: - Edge Cases
    
    @Test("Handles already correct casual text")
    func casualAlreadyCorrect() {
        let rules = StaticStyleRules.casual
        let result = StyleTransformer.transform("hello world", using: rules)
        #expect(result == "hello world")
    }
    
    @Test("Handles already correct formal text")
    func formalAlreadyCorrect() {
        let rules = StaticStyleRules.formal
        let result = StyleTransformer.transform("Hello world.", using: rules)
        #expect(result == "Hello world.")
    }
    
    @Test("Preserves contractions")
    func preservesContractions() {
        let casual = StyleTransformer.transform("Don't worry", using: .casual)
        #expect(casual == "don't worry")
        
        let formal = StyleTransformer.transform("don't worry", using: .formal)
        #expect(formal == "Don't worry.")
    }
    
    @Test("Handles numbers at sentence start")
    func handlesNumbersAtStart() {
        let casual = StyleTransformer.transform("1st place", using: .casual)
        #expect(casual == "1st place")
        
        let formal = StyleTransformer.transform("1st place", using: .formal)
        #expect(formal == "1st place.")
    }
}