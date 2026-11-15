import Foundation
import Testing
@testable import vcdr_ios

/// "Process with AI" for a Discarded Conversation (ADR-0010): the full
/// pipeline runs on the verbatim text, and the result goes to History only.
@MainActor
@Suite("ConversationReprocessor")
struct ConversationReprocessorTests {
    private static let recorded = RecordedOutputChoice(mode: .dictation, style: .formal)

    @Test("processing gives the entry its AI output and makes it a normal entry")
    func processingResolvesTheEntry() async throws {
        let env = Env(ai: .alwaysSucceed(output: "Hello world."))
        let discarded = env.recordDiscarded("um hello world", choice: Self.recorded)

        env.reprocessor.process(discarded, with: env.reprocessor.defaultChoice(for: discarded))
        #expect(env.reprocessor.choiceInProgress(for: discarded.id) == ReprocessChoice(mode: .dictation, style: .formal))
        await waitUntil { env.reprocessor.choiceInProgress(for: discarded.id) == nil }

        let resolved = try #require(env.history.conversations.first)
        #expect(resolved.id == discarded.id)
        #expect(resolved.status == .normal)
        #expect(resolved.output == "Hello world. ")
        #expect(resolved.label == "Dictation · Formal")
        #expect(resolved.inputText == "um hello world")
        #expect(resolved.capturedAt == discarded.capturedAt)
        #expect(env.history.discardedCount == 0)
        #expect(env.reprocessor.failure(for: discarded.id) == nil)
    }

    @Test("a failed AI call leaves the entry discarded and reports the error")
    func failureKeepsTheEntryDiscarded() async throws {
        let env = Env(ai: .alwaysThrow)
        let discarded = env.recordDiscarded("um hello world", choice: Self.recorded)

        env.reprocessor.process(discarded, with: env.reprocessor.defaultChoice(for: discarded))
        await waitUntil { env.reprocessor.choiceInProgress(for: discarded.id) == nil }

        let kept = try #require(env.history.conversations.first)
        #expect(kept.status == .discarded(Self.recorded))
        #expect(kept.output == nil)
        #expect(env.reprocessor.failure(for: discarded.id) != nil)
    }

    @Test("with no AI set up the entry stays discarded and the reason shows")
    func noAICapabilityKeepsTheEntryDiscarded() async throws {
        let env = Env(ai: .alwaysSucceed(output: "unused"), hasAI: false)
        let discarded = env.recordDiscarded("hello world", choice: Self.recorded)

        env.reprocessor.process(discarded, with: env.reprocessor.defaultChoice(for: discarded))
        await waitUntil { env.reprocessor.choiceInProgress(for: discarded.id) == nil }

        #expect(env.history.conversations.first?.status.isDiscarded == true)
        #expect(env.reprocessor.failure(for: discarded.id) == AIConversationReprocessor.noAIMessage)
    }

    @Test("a choice the Mac recorded uses the current iOS mode and style")
    func macChoiceUsesTheCurrentIOSChoice() {
        let env = Env(ai: .alwaysThrow, current: (.assistant, .messaging))
        let fromMac = env.recordDiscarded("hello", choice: RecordedOutputChoice(
            platform: .mac,
            modeID: UUID().uuidString,
            styleID: UUID().uuidString,
            displayLabel: "Email · Formal"
        ))

        #expect(env.reprocessor.defaultChoice(for: fromMac) == ReprocessChoice(mode: .assistant, style: .messaging))
    }

    @Test("a run recorded in Verbatim is processed with Dictation and its recorded style")
    func verbatimChoiceBecomesDictation() {
        let env = Env(ai: .alwaysThrow, current: (.verbatim, .casual))
        let verbatim = env.recordDiscarded("hello", choice: RecordedOutputChoice(mode: .verbatim, style: .messaging))

        #expect(env.reprocessor.defaultChoice(for: verbatim) == ReprocessChoice(mode: .dictation, style: .messaging))
    }
}

@MainActor
private final class Env {
    let history: FileHistoryStore
    let reprocessor: AIConversationReprocessor

    init(
        ai: FakeLLMProvider.Behavior,
        hasAI: Bool = true,
        current: (mode: AIPromptMode, style: TextStyle) = (.dictation, .casual)
    ) {
        history = FileHistoryStore(snapshot: FileHistoryStore.loadSnapshot(
            storageRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("ConversationReprocessorTests-\(UUID().uuidString)")
        ))
        reprocessor = AIConversationReprocessor(
            history: history,
            backgroundTasks: SpyBackgroundTaskRunner(),
            substitutions: { [] },
            currentChoice: { current },
            hasAICapability: { hasAI },
            makeAIProvider: { _ in
                ProviderCascade(
                    primary: FakeLLMProvider(behavior: ai),
                    fallback: nil,
                    maxAttempts: 1,
                    timeout: .seconds(1)
                )
            }
        )
    }

    func recordDiscarded(_ text: String, choice: RecordedOutputChoice) -> Conversation {
        let id = UUID()
        history.recordDiscarded(conversationID: id, inputSegments: [InputSegment(text: text)], choice: choice)
        return history.conversations.first { $0.id == id }!
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () -> Bool
) async {
    let start = ContinuousClock.now
    while start.duration(to: .now) < timeout {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
