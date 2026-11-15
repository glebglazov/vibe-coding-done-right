import Foundation
import Testing
@testable import vcdr_mac

/// Every LLM call is told the Dictionary's Spelling Hints after its system
/// prompt, with each Note only for a Dictation prompt; a path that calls no
/// LLM is told nothing and makes no call.
@Suite("TextProcessingPipeline — Spelling Hints")
struct TextProcessingPipelineSpellingHintsTests {

    /// "Glazov" is a hint-only entry; "VCDR" is also a Substitution. Glazov was
    /// edited last, so it is listed first.
    private static let dictionary = [
        Substitution(triggerPhrases: [], replacement: "Glazov", note: "my surname", lastUpdated: Date(timeIntervalSince1970: 2_000)),
        Substitution(triggerPhrase: "vee see dee are", replacement: "VCDR", lastUpdated: Date(timeIntervalSince1970: 1_000)),
    ]
    private static let hintsWithNotesSuffix = "- Glazov (my surname)\n- VCDR\n</spelling_hints>"
    private static let spellingsOnlySuffix = "- Glazov\n- VCDR\n</spelling_hints>"

    @Test("A Cloud AI Dictation run's system prompt is the mode's prompt with the hints and their Notes last")
    func cloudAISystemPromptEndsWithHints() async throws {
        let mode = Mode(id: UUID(), name: "AI", processingType: .cloudAI, promptType: .dictation)
        let ai = ScriptedAIProcessing(results: [.success("done")])

        _ = try await TextProcessingPipeline.run(
            mode: mode,
            text: "hi",
            captures: [],
            substitutions: Self.dictionary,
            aiPort: ai
        )

        let call = try #require(await ai.receivedCalls.first)
        let systemPrompt = AIProcessingAdapter.systemPrompt(for: mode, spellingHints: call.spellingHints)
        #expect(systemPrompt.hasPrefix(BuiltInPrompts.dictation + "\n\n<spelling_hints>"))
        #expect(systemPrompt.hasSuffix(Self.hintsWithNotesSuffix))
    }

    @Test("A Cloud AI run with an Assistant or Custom prompt is told the spellings without their Notes",
          arguments: [PromptType.assistant, .custom])
    func cloudAIWritingPromptGetsNoNotes(promptType: PromptType) async throws {
        let mode = Mode(id: UUID(), name: "AI", processingType: .cloudAI, systemPrompt: "Do what I ask.", promptType: promptType)
        let ai = ScriptedAIProcessing(results: [.success("done")])

        _ = try await TextProcessingPipeline.run(
            mode: mode,
            text: "hi",
            captures: [],
            substitutions: Self.dictionary,
            aiPort: ai
        )

        let call = try #require(await ai.receivedCalls.first)
        let systemPrompt = AIProcessingAdapter.systemPrompt(for: mode, spellingHints: call.spellingHints)
        #expect(systemPrompt.hasSuffix(Self.spellingsOnlySuffix))
        #expect(!systemPrompt.contains("my surname"))
    }

    @Test("A Cloud AI run with an empty Dictionary sends the mode's prompt unchanged")
    func cloudAIWithEmptyDictionarySendsPromptUnchanged() async throws {
        let mode = Mode(id: UUID(), name: "AI", processingType: .cloudAI, promptType: .dictation)
        let ai = ScriptedAIProcessing(results: [.success("done")])

        _ = try await TextProcessingPipeline.run(mode: mode, text: "hi", captures: [], aiPort: ai)

        let call = try #require(await ai.receivedCalls.first)
        #expect(call.spellingHints == .none)
        #expect(AIProcessingAdapter.systemPrompt(for: mode, spellingHints: call.spellingHints) == BuiltInPrompts.dictation)
    }

    @Test("A Local Agent's input carries the mode prompt, the style prompt, then the hints")
    func localAgentInputCarriesHintsAfterStylePrompt() async throws {
        let mode = Mode(id: UUID(), name: "Agent", processingType: .localAgent, promptType: .dictation)
        let style = Style(id: UUID(), name: "Pirate", isBuiltIn: false, isDefault: false,
                          staticRules: .casual, dynamicPrompt: "Answer in pirate speak.")
        let agent = CapturingLocalAgent()

        _ = try await TextProcessingPipeline.run(
            mode: mode,
            text: "hi",
            captures: [],
            substitutions: Self.dictionary,
            localAgentPort: agent,
            style: style
        )

        let input = try #require(await agent.receivedText)
        let prompt = BuiltInPrompts.dictation + "\n\nAnswer in pirate speak."
        #expect(input.hasPrefix(prompt + "\n\n<spelling_hints>"))
        #expect(input.contains(Self.hintsWithNotesSuffix + "\n\n<dictation>hi</dictation>"))
    }

    @Test("A Local Agent with an Assistant prompt is told the spellings without their Notes")
    func localAgentAssistantGetsNoNotes() async throws {
        let mode = Mode(id: UUID(), name: "Agent", processingType: .localAgent, promptType: .assistant, appliesStyles: false)
        let agent = CapturingLocalAgent()

        _ = try await TextProcessingPipeline.run(
            mode: mode,
            text: "hi",
            captures: [],
            substitutions: Self.dictionary,
            localAgentPort: agent
        )

        let input = try #require(await agent.receivedText)
        #expect(input.contains(Self.spellingsOnlySuffix + "\n\n<dictation>hi</dictation>"))
        #expect(!input.contains("my surname"))
    }

    @Test("A Bash Script's input carries its prompt but no hints")
    func bashScriptInputCarriesNoHints() async throws {
        // The script echoes its input back, so the result is exactly what it received.
        let mode = Mode(
            id: UUID(),
            name: "Bash",
            processingType: .bashScript,
            processingCommand: "printf '%s' \"$VCDR_TEXT\"",
            systemPromptEnabled: true,
            systemPrompt: "Script prompt.",
            appliesStyles: false
        )

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: "hi",
            captures: [],
            substitutions: Self.dictionary
        )

        #expect(result.text == "Script prompt.\n\n<dictation>hi</dictation>")
    }

    @Test("A Verbatim run with hints makes no AI call and adds no hints")
    func verbatimMakesNoCall() async throws {
        let mode = Mode(id: UUID(), name: "Verbatim", processingType: .none, appliesStyles: false)
        let ai = ScriptedAIProcessing(results: [])

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: "hi",
            captures: [],
            substitutions: Self.dictionary,
            aiPort: ai
        )

        #expect(await ai.receivedCalls.isEmpty)
        #expect(result.text == "hi")
    }
}

@MainActor
private final class CapturingLocalAgent: LocalAgentPort {
    private(set) var receivedText: String?

    nonisolated init() {}

    func process(structuredText: String, mode: Mode, environment: [String: String]) async throws -> String {
        receivedText = structuredText
        return "done"
    }
}
