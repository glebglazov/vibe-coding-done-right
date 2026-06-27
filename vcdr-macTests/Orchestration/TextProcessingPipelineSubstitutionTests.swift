import Foundation
import Testing
@testable import vcdr_mac

// MARK: - TextProcessingPipeline Substitution Integration Tests

/// Proves Substitutions run as the pipeline's first step — before filler
/// removal and before input structuring / external processing — in every
/// Processing Type, and only on the dictated transcript (Captures stay exact).
@Suite("TextProcessingPipeline — Substitutions")
struct TextProcessingPipelineSubstitutionTests {

    private static let substitutions = [
        Substitution(triggerPhrase: "oh my zsh", replacement: "oh my gosh")
    ]

    // MARK: - Verbatim (.none)

    @Test("Substitution applies in Verbatim mode (.none)")
    func appliesInVerbatim() async throws {
        let mode = Mode(id: UUID(), name: "Verbatim", processingType: .none, showPreview: false)

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: "I said oh my zsh today",
            captures: [],
            substitutions: Self.substitutions,
            style: .casual
        )

        #expect(result.text.contains("oh my gosh"))
        #expect(!result.text.contains("oh my zsh"))
        #expect(result.hadExternalProcessing == false)
    }

    @Test("Disabled substitution is skipped in Verbatim mode")
    func disabledSkipped() async throws {
        let mode = Mode(id: UUID(), name: "Verbatim", processingType: .none, showPreview: false)
        let disabled = [Substitution(triggerPhrase: "oh my zsh", replacement: "oh my gosh", isEnabled: false)]

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: "oh my zsh",
            captures: [],
            substitutions: disabled,
            style: .casual
        )

        #expect(result.text.contains("oh my zsh"))
        #expect(!result.text.contains("oh my gosh"))
    }

    // MARK: - Cloud AI: flows into prompt, Captures untouched

    @Test("Substitution flows into the AI prompt and leaves Captures byte-exact")
    func appliesInCloudAIAndSpareCaptures() async throws {
        let mode = Mode(id: UUID(), name: "AI", processingType: .cloudAI, showPreview: false)
        // The Capture text deliberately contains the Trigger Phrase: it must NOT
        // be rewritten, proving substitution touches the transcript only.
        let captures = [CapturedContext(text: "literally oh my zsh", source: .selection)]
        let scripted = ScriptedAIProcessing(results: [.success("done")])

        _ = try await TextProcessingPipeline.run(
            mode: mode,
            text: "please oh my zsh it",
            captures: captures,
            substitutions: Self.substitutions,
            aiPort: scripted,
            style: .casual
        )

        let calls = await scripted.receivedCalls
        let prompt = try #require(calls.first).structuredText
        // Dictation portion was substituted before it reached the AI.
        #expect(prompt.contains("<dictation>please oh my gosh it</dictation>"))
        // Capture portion is preserved verbatim — the matcher never ran on it.
        #expect(prompt.contains("literally oh my zsh"))
    }

    // MARK: - Bash script (external processing)

    @Test("Substitution applies before external processing in bash mode")
    func appliesInBashScript() async throws {
        // The script echoes the structured input ($VCDR_TEXT) straight back, so the
        // output reflects exactly what substitution + structuring produced before it ran.
        let mode = Mode(
            id: UUID(),
            name: "Bash",
            processingType: .bashScript,
            processingCommand: "printf '%s' \"$VCDR_TEXT\"",
            showPreview: false
        )

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: "ran oh my zsh here",
            captures: [],
            substitutions: Self.substitutions,
            style: .casual
        )

        #expect(result.text.contains("oh my gosh"))
        #expect(!result.text.contains("oh my zsh"))
        #expect(result.hadExternalProcessing == true)
    }

    // MARK: - Ordering: substitution before filler removal

    @Test("Substitution runs before filler-word removal")
    func runsBeforeFillerRemoval() async throws {
        // The Replacement injects the filler "um"; because substitution runs
        // FIRST, the subsequent filler pass then strips it — proving order.
        let mode = Mode(id: UUID(), name: "Verbatim", processingType: .none, showPreview: false)
        let subs = [Substitution(triggerPhrase: "intro", replacement: "um welcome")]

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: "intro now",
            captures: [],
            substitutions: subs,
            removeFillerWords: true,
            style: .casual
        )

        // "um" is a filler word removed by the later pass; "welcome" survives.
        #expect(result.text.contains("welcome"))
        #expect(!result.text.contains("um"))
    }
}
