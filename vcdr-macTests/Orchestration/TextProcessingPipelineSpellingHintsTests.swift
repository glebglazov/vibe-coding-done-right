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

    @Test("A Cloud AI run with a Custom prompt is told the spellings without their Notes")
    func cloudAICustomPromptGetsNoNotes() async throws {
        let mode = Mode(id: UUID(), name: "AI", processingType: .cloudAI, systemPrompt: "Do what I ask.", promptType: .custom)
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
