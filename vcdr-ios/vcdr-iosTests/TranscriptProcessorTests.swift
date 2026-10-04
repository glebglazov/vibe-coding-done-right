import Testing
@testable import vcdr_ios

@MainActor
@Suite("TranscriptProcessor")
struct TranscriptProcessorTests {
    @Test("assistant AI input includes non-empty captures")
    func assistantAIInputIncludesCaptures() {
        let input = TranscriptProcessor.buildAIInput(
            "summarize this",
            mode: .assistant,
            captures: ["first", "", "third"]
        )

        #expect(input == """
        <dictation>summarize this</dictation>

        <capture id="1">first</capture>

        <capture id="3">third</capture>
        """)
    }

    @Test("dictation AI input leaves captures out")
    func dictationAIInputOmitsCaptures() {
        let input = TranscriptProcessor.buildAIInput(
            "clean this up",
            mode: .dictation,
            captures: ["first", "", "third"]
        )

        #expect(input == "<dictation>clean this up</dictation>")
    }

    @Test("verbatim AI input excludes captures")
    func verbatimAIInputExcludesCaptures() {
        let input = TranscriptProcessor.buildAIInput(
            "leave as is",
            mode: .verbatim,
            captures: ["selected context"]
        )

        #expect(input == "<dictation>leave as is</dictation>")
    }

    @Test("final transcript uses AI result and final settings")
    func finalTranscriptUsesAIResultAndFinalSettings() async {
        let processor = TranscriptProcessor(
            makeAIProvider: { _ in
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
            captures: [],
            spellingHints: .none
        )

        #expect(output.transcript == "hello world")
        #expect(output.processed == "Hello world.")
        #expect(output.finalText == "Hello world. ")
        #expect(output.historyLabel == "Dictation · Formal")
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
            captures: [],
            spellingHints: SpellingHints(dictionary)
        )

        let systemPrompt = try #require(llm.receivedSystemPrompts.first)
        #expect(systemPrompt.hasPrefix(BuiltInPrompts.prompt(for: .dictation) + "\n\n<spelling_hints>"))
        #expect(systemPrompt.hasSuffix("- Glazov (my surname)\n</spelling_hints>"))
    }

    @Test("an Assistant run's system prompt carries the spellings without their Notes")
    func assistantSystemPromptHasNoNotes() async throws {
        let llm = FakeLLMProvider(behavior: .alwaysSucceed(output: "Dear Kathleen, thank you."))
        let processor = Self.processor(calling: llm)
        let dictionary = [Substitution(triggerPhrases: [], replacement: "Glazov", note: "my surname")]

        _ = await processor.processFinalTranscript(
            "write a thank-you note to kathleen",
            initialSettings: .init(promptMode: .assistant, textStyle: .casual, hasAICapability: true),
            finalSettings: { .init(promptMode: .assistant, textStyle: .casual, hasAICapability: true) },
            captures: [],
            spellingHints: SpellingHints(dictionary)
        )

        let systemPrompt = try #require(llm.receivedSystemPrompts.first)
        #expect(systemPrompt.hasPrefix(BuiltInPrompts.prompt(for: .assistant) + "\n\n<spelling_hints>"))
        #expect(systemPrompt.hasSuffix("- Glazov\n</spelling_hints>"))
        #expect(!systemPrompt.contains("my surname"))
    }

    @Test("a Verbatim run with Spelling Hints makes no AI call")
    func verbatimWithSpellingHintsMakesNoCall() async {
        let llm = FakeLLMProvider(behavior: .alwaysSucceed(output: "should not be used"))
        let processor = Self.processor(calling: llm)

        let output = await processor.processFinalTranscript(
            "hi glass of",
            initialSettings: .init(promptMode: .verbatim, textStyle: .casual, hasAICapability: true),
            finalSettings: { .init(promptMode: .verbatim, textStyle: .casual, hasAICapability: true) },
            captures: [],
            spellingHints: SpellingHints([Substitution(triggerPhrases: [], replacement: "Glazov")])
        )

        #expect(llm.attempts == 0)
        #expect(output.processed == nil)
    }

    @Test("AI timeout falls back to local transcript")
    func aiTimeoutFallsBackToLocalTranscript() async {
        let processor = TranscriptProcessor(
            makeAIProvider: { _ in
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
            captures: [],
            spellingHints: .none
        )

        #expect(output.processed == "local text")
        #expect(output.finalText == "local text ")
    }

    private static func processor(calling llm: FakeLLMProvider) -> TranscriptProcessor {
        TranscriptProcessor(
            makeAIProvider: { _ in
                ProviderCascade(primary: llm, fallback: nil, maxAttempts: 1, timeout: .seconds(1))
            },
            onAIProcessingStatus: { _ in },
            onAIInputText: { _ in }
        )
    }
}
