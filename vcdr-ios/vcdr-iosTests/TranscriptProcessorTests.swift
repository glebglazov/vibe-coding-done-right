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
            captures: []
        )

        #expect(output.transcript == "hello world")
        #expect(output.processed == "Hello world.")
        #expect(output.finalText == "Hello world. ")
        #expect(output.historyLabel == "Dictation · Formal")
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
            captures: []
        )

        #expect(output.processed == "local text")
        #expect(output.finalText == "local text ")
    }
}
