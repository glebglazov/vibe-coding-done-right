import Testing
@testable import vcdr_ios

@MainActor
@Suite("TranscriptProcessor")
struct TranscriptProcessorTests {
    @Test("AI input wraps the dictation in its tag")
    func aiInputWrapsDictation() {
        #expect(TranscriptProcessor.buildAIInput("clean this up") == "<dictation>clean this up</dictation>")
    }

    @Test("History labels name AI on as AI and AI off as AI off, with the style")
    func outputChoiceLabels() {
        #expect(TranscriptProcessor.outputChoiceLabel(mode: .dictation, style: .casual) == "AI · Casual")
        #expect(TranscriptProcessor.outputChoiceLabel(mode: .verbatim, style: .formal) == "AI off · Formal")
    }

    @Test("final transcript uses AI result and final settings")
    func finalTranscriptUsesAIResultAndFinalSettings() async {
        let processor = TranscriptProcessor(
            makeAIProvider: {
                ProviderCascade(
                    primary: FakeLLMProvider(behavior: .alwaysSucceed(output: "Hello world.")),
                    fallback: nil,
                    maxAttempts: 1,
                    timeout: .seconds(1)
                )
            },
            onAIProcessingStatus: { _ in },
            onAIInputText: { _ in }
        )

        let output = await processor.processFinalTranscript(
            "hello world",
            initialSettings: .init(promptMode: .dictation, textStyle: .casual, hasAICapability: true),
            finalSettings: {
                .init(promptMode: .dictation, textStyle: .formal, hasAICapability: true)
            },
            spellingHints: .none
        )

        #expect(output.transcript == "hello world")
        #expect(output.processed == "Hello world.")
        #expect(output.finalText == "Hello world. ")
        #expect(output.historyLabel == "AI · Formal")
    }

    @Test("a Dictation run's system prompt is the mode's prompt with the Spelling Hints and their Notes last")
    func dictationSystemPromptEndsWithSpellingHints() async throws {
        let llm = FakeLLMProvider(behavior: .alwaysSucceed(output: "Hi Glazov."))
        let processor = Self.processor(calling: llm)
        let dictionary = [Substitution(triggerPhrases: [], replacement: "Glazov", note: "my surname")]

        _ = await processor.processFinalTranscript(
            "hi glass of",
            initialSettings: .init(promptMode: .dictation, textStyle: .casual, hasAICapability: true),
            finalSettings: { .init(promptMode: .dictation, textStyle: .casual, hasAICapability: true) },
            spellingHints: SpellingHints(dictionary)
        )

        let systemPrompt = try #require(llm.receivedSystemPrompts.first)
        #expect(systemPrompt.hasPrefix(BuiltInPrompts.prompt(for: .dictation) + "\n\n<spelling_hints>"))
        #expect(systemPrompt.hasSuffix("- Glazov (my surname)\n</spelling_hints>"))
    }

    @Test("a Verbatim run with Spelling Hints makes no AI call")
    func verbatimWithSpellingHintsMakesNoCall() async {
        let llm = FakeLLMProvider(behavior: .alwaysSucceed(output: "should not be used"))
        let processor = Self.processor(calling: llm)

        let output = await processor.processFinalTranscript(
            "hi glass of",
            initialSettings: .init(promptMode: .verbatim, textStyle: .casual, hasAICapability: true),
            finalSettings: { .init(promptMode: .verbatim, textStyle: .casual, hasAICapability: true) },
            spellingHints: SpellingHints([Substitution(triggerPhrases: [], replacement: "Glazov")])
        )

        #expect(llm.attempts == 0)
        #expect(output.processed == nil)
    }

    @Test("AI timeout falls back to local transcript")
    func aiTimeoutFallsBackToLocalTranscript() async {
        let processor = TranscriptProcessor(
            makeAIProvider: {
                ProviderCascade(
                    primary: FakeLLMProvider(behavior: .hang),
                    fallback: nil,
                    maxAttempts: 1,
                    timeout: .milliseconds(1)
                )
            },
            onAIProcessingStatus: { _ in },
            onAIInputText: { _ in }
        )

        let output = await processor.processFinalTranscript(
            "local text",
            initialSettings: .init(promptMode: .dictation, textStyle: .casual, hasAICapability: true),
            finalSettings: {
                .init(promptMode: .dictation, textStyle: .casual, hasAICapability: true)
            },
            spellingHints: .none
        )

        #expect(output.processed == "local text")
        #expect(output.finalText == "local text ")
    }

    private static func processor(calling llm: FakeLLMProvider) -> TranscriptProcessor {
        TranscriptProcessor(
            makeAIProvider: {
                ProviderCascade(primary: llm, fallback: nil, maxAttempts: 1, timeout: .seconds(1))
            },
            onAIProcessingStatus: { _ in },
            onAIInputText: { _ in }
        )
    }
}
