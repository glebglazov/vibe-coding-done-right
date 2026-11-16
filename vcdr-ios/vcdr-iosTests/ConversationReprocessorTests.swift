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
        #expect(env.reprocessor.choiceInProgress(for: discarded.id) == ReprocessChoice(style: .formal))
        await waitUntil { env.reprocessor.choiceInProgress(for: discarded.id) == nil }

        let resolved = try #require(env.history.conversations.first)
        #expect(resolved.id == discarded.id)
        #expect(resolved.status == .normal)
        #expect(resolved.output == "Hello world. ")
        #expect(resolved.label == "AI · Formal")
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

    @Test("a choice the Mac recorded uses the current iOS style")
    func macChoiceUsesTheCurrentIOSStyle() {
        let env = Env(ai: .alwaysThrow, currentStyle: .messaging)
        let fromMac = env.recordDiscarded("hello", choice: RecordedOutputChoice(
            platform: .mac,
            modeID: UUID().uuidString,
            styleID: UUID().uuidString,
            displayLabel: "Email · Formal"
        ))

        #expect(env.reprocessor.defaultChoice(for: fromMac) == ReprocessChoice(style: .messaging))
    }

    @Test("a run recorded with AI off is processed with AI on and its recorded style")
    func aiOffChoiceKeepsItsStyle() async throws {
        let env = Env(ai: .alwaysSucceed(output: "Hello."), currentStyle: .casual)
        let aiOff = env.recordDiscarded("hello", choice: RecordedOutputChoice(mode: .verbatim, style: .messaging))

        let choice = env.reprocessor.defaultChoice(for: aiOff)
        #expect(choice == ReprocessChoice(style: .messaging))
        env.reprocessor.process(aiOff, with: choice)
        await waitUntil { env.reprocessor.choiceInProgress(for: aiOff.id) == nil }

        #expect(try #require(env.history.conversations.first).label == "AI · Messaging")
    }
}

@MainActor
private final class Env {
    let history: FileHistoryStore
    let reprocessor: AIConversationReprocessor

    init(
        ai: FakeLLMProvider.Behavior,
        hasAI: Bool = true,
        currentStyle: TextStyle = .casual
    ) {
        history = FileHistoryStore(snapshot: FileHistoryStore.loadSnapshot(
            storageRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("ConversationReprocessorTests-\(UUID().uuidString)")
        ))
        reprocessor = AIConversationReprocessor(
            history: history,
            backgroundTasks: SpyBackgroundTaskRunner(),
            substitutions: { [] },
            currentStyle: { currentStyle },
            hasAICapability: { hasAI },
            makeAIProvider: {
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
