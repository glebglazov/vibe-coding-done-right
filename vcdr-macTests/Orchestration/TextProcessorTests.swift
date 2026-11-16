import Foundation
import Testing
@testable import vcdr_mac

// MARK: - Helpers

@MainActor
private func makeProcessor(
    aiResults: [Result<String, Error>] = [],
    settings: AppSettings? = nil,
    overrides: SessionOverrides? = nil
) -> (TextProcessor, FileHistoryStore, ScriptedAIProcessing, AppSettings) {
    let defaults = UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
    let s = settings ?? AppSettings(userDefaults: defaults, secretStore: InMemorySecretStore())
    s.removeFillerWords = false
    let historyDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vcdr-test-\(UUID().uuidString)")
    let history = FileHistoryStore(snapshot: FileHistoryStore.loadSnapshot(storageRoot: historyDir))
    let ai = ScriptedAIProcessing(results: aiResults)
    let processor = TextProcessor(
        aiPort: ai,
        history: history,
        settings: s,
        overrides: overrides ?? SessionOverrides(),
        styleProvider: { .casual }
    )
    return (processor, history, ai, s)
}

@MainActor
private func makeInput(
    text: String = "Hello world",
    mode: Mode? = nil,
    processingType: ProcessingType = .none,
    showPreview: Bool = false,
    hadDestinationOverride: Bool = false,
    style: Style = .casual,
    destination: OutputDestination = OutputDestination.makeDefaultCopy(),
    substitutions: [Substitution] = []
) -> TranscriptionInput {
    let m = mode ?? Mode(
        id: UUID(),
        name: "Test",
        processingType: processingType,
        showPreview: showPreview
    )
    return TranscriptionInput(
        text: text,
        mode: m,
        conversationID: UUID(),
        destination: destination,
        targetAppPID: nil,
        cursorContext: nil,
        parameterValues: [:],
        variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
        inputSegments: [InputSegment(text: text)],
        hadDestinationOverride: hadDestinationOverride,
        removeFillerWords: false,
        style: style,
        saveResultToClipboard: false,
        substitutions: substitutions
    )
}

// MARK: - Happy Path

@Suite("TextProcessor — Happy Path")
struct TextProcessorHappyPathTests {

    @Test("Empty text returns .empty")
    @MainActor
    func emptyText() async throws {
        let (processor, history, _, _) = makeProcessor()
        let input = makeInput(text: "")
        let disposition = try await processor.process(input)

        guard case .empty = disposition else {
            Issue.record("Expected .empty, got \(disposition)")
            return
        }
        #expect(history.conversations.isEmpty)
    }

    @Test("Passthrough mode executes action and records history")
    @MainActor
    func passthroughExecutes() async throws {
        let (processor, history, _, _) = makeProcessor()
        let input = makeInput(text: "Hello world")
        let disposition = try await processor.process(input)

        guard case .execute(let result) = disposition else {
            Issue.record("Expected .execute, got \(disposition)")
            return
        }
        // Casual style: lowercase + trailing space
        #expect(result.text == "hello world ")
        #expect(result.destinationName == "copy")
        #expect(history.conversations.count == 1)
    }

    @Test("Preview mode returns .preview")
    @MainActor
    func previewMode() async throws {
        let (processor, history, _, _) = makeProcessor()
        let input = makeInput(showPreview: true)
        let disposition = try await processor.process(input)

        guard case .preview(let handle) = disposition else {
            Issue.record("Expected .preview, got \(disposition)")
            return
        }
        #expect(handle.displayText == "hello world ")
        #expect(handle.aiErrorMessage == nil)
        // History not recorded until confirm
        #expect(history.conversations.isEmpty)
    }

    @Test("Destination override skips preview even when showPreview is true")
    @MainActor
    func destinationOverrideSkipsPreview() async throws {
        let (processor, _, _, _) = makeProcessor()
        let input = makeInput(showPreview: true, hadDestinationOverride: true)
        let disposition = try await processor.process(input)

        guard case .execute = disposition else {
            Issue.record("Expected .execute (override skips preview), got \(disposition)")
            return
        }
    }
}

// MARK: - AI Processing

@Suite("TextProcessor — AI Processing")
struct TextProcessorAITests {

    @Test("AI failure returns preview with error and retry context")
    @MainActor
    func aiFailureShowsPreviewWithRetry() async throws {
        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "AI failed" }
        }
        let (processor, _, _, _) = makeProcessor(aiResults: [.failure(TestError())])
        let input = makeInput(processingType: .cloudAI)
        let disposition = try await processor.process(input)

        guard case .preview(let handle) = disposition else {
            Issue.record("Expected .preview with AI fallback, got \(disposition)")
            return
        }
        #expect(handle.aiErrorMessage != nil)
        #expect(handle.aiRetryStructuredText != nil)
    }

    @Test("AI retry replays exact same structured text through AI port")
    @MainActor
    func aiRetryParity() async throws {
        struct TestError: Error { }
        let (processor, _, ai, _) = makeProcessor(
            aiResults: [.failure(TestError()), .success("polished")]
        )
        let input = makeInput(processingType: .cloudAI)

        // First call fails
        let firstDisposition = try await processor.process(input)
        guard case .preview(let handle) = firstDisposition else {
            Issue.record("Expected .preview")
            return
        }

        let callsBefore = await ai.receivedCalls
        #expect(callsBefore.count == 1)

        // Retry
        let retryDisposition = try await processor.retryAI(handle)
        guard case .preview(let newHandle) = retryDisposition else {
            Issue.record("Expected .preview after retry")
            return
        }
        #expect(newHandle.aiErrorMessage == nil, "Retry should succeed")

        let callsAfter = await ai.receivedCalls
        #expect(callsAfter.count == 2)
        // CRITICAL: both calls must carry identical structured text
        #expect(callsAfter[0].structuredText == callsAfter[1].structuredText)
    }

    @Test("AI retry carries the same Spelling Hints as the first attempt")
    @MainActor
    func aiRetryCarriesSpellingHints() async throws {
        struct TestError: Error { }
        let (processor, _, ai, _) = makeProcessor(
            aiResults: [.failure(TestError()), .success("polished")]
        )
        let dictionary = [Substitution(triggerPhrases: [], replacement: "Glazov", note: "my surname")]
        let input = makeInput(processingType: .cloudAI, substitutions: dictionary)

        guard case .preview(let handle) = try await processor.process(input) else {
            Issue.record("Expected .preview")
            return
        }
        _ = try await processor.retryAI(handle)

        let calls = await ai.receivedCalls
        #expect(calls.count == 2)
        let hint = SpellingHints.Hint(spelling: "Glazov", note: "my surname")
        #expect(calls.map(\.spellingHints.hints) == [[hint], [hint]])
    }

    @Test("Style transform applied on retry path (no drift)")
    @MainActor
    func retryAppliesPostProcessing() async throws {
        struct TestError: Error { }
        let (processor, _, _, _) = makeProcessor(
            aiResults: [.failure(TestError()), .success("hello world")]
        )
        let input = makeInput(processingType: .cloudAI, style: .casual)

        let firstDisposition = try await processor.process(input)
        guard case .preview(let handle) = firstDisposition else {
            Issue.record("Expected .preview")
            return
        }

        let retryDisposition = try await processor.retryAI(handle)
        guard case .preview(let newHandle) = retryDisposition else {
            Issue.record("Expected .preview after retry")
            return
        }
        // Casual style: lowercase + trailing space
        #expect(newHandle.displayText == "hello world ")
    }
}

// MARK: - Confirm

@Suite("TextProcessor — Confirm")
struct TextProcessorConfirmTests {

    @Test("Confirm records history")
    @MainActor
    func confirmRecordsHistory() async throws {
        let (processor, history, _, _) = makeProcessor()
        let input = makeInput(showPreview: true)

        let disposition = try await processor.process(input)
        guard case .preview(let handle) = disposition else {
            Issue.record("Expected .preview")
            return
        }
        #expect(history.conversations.isEmpty)

        try await processor.confirm(handle)
        #expect(history.conversations.count == 1)
    }

    @Test("Confirm with destination override uses overridden destination")
    @MainActor
    func confirmWithDestinationOverride() async throws {
        // The overridden destination is the one that executes, so it must be a
        // destination that needs no Accessibility grant — the test host is its own
        // app bundle and never holds one.
        let (processor, history, _, _) = makeProcessor()
        let input = makeInput(showPreview: true, destination: .makeDefaultPasteToInitialApp())

        let disposition = try await processor.process(input)
        guard case .preview(let handle) = disposition else {
            Issue.record("Expected .preview")
            return
        }

        try await processor.confirm(handle, destinationOverride: OutputDestination.builtInCopyID)
        #expect(history.conversations.count == 1)
    }

    @Test("recordDismissedPreview writes history")
    @MainActor
    func dismissedPreviewRecordsHistory() async throws {
        let (processor, history, _, _) = makeProcessor()
        let input = makeInput(showPreview: true)

        let disposition = try await processor.process(input)
        guard case .preview(let handle) = disposition else {
            Issue.record("Expected .preview")
            return
        }

        processor.recordDismissedPreview(handle)
        #expect(history.conversations.count == 1)
    }
}

// MARK: - Session Overrides

@Suite("TextProcessor — Session Overrides")
struct TextProcessorSessionOverrideTests {

    @Test("a completed Capture Session clears its Mode Parameter overrides")
    @MainActor
    func completionClearsParameterOverrides() async throws {
        let overrides = SessionOverrides()
        overrides.parameterOverrides[UUID()] = "sonnet"
        let (processor, _, _, _) = makeProcessor(overrides: overrides)

        _ = try await processor.process(makeInput(text: "Hello world"))

        #expect(overrides.parameterOverrides.isEmpty)
    }

    @Test("a confirmed preview clears its Mode Parameter overrides")
    @MainActor
    func confirmClearsParameterOverrides() async throws {
        let overrides = SessionOverrides()
        overrides.parameterOverrides[UUID()] = "sonnet"
        let (processor, _, _, _) = makeProcessor(overrides: overrides)
        guard case .preview(let handle) = try await processor.process(makeInput(text: "Hello world", showPreview: true)) else {
            Issue.record("Expected .preview")
            return
        }
        #expect(!overrides.parameterOverrides.isEmpty)

        try await processor.confirm(handle)

        #expect(overrides.parameterOverrides.isEmpty)
    }
}
