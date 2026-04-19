import Foundation
import Testing
@testable import vcdr_mac

// MARK: - Helpers

@MainActor
private func makeProcessor(
    aiResults: [Result<String, Error>] = [],
    settings: AppSettings? = nil
) -> (TextProcessor, FileHistoryStore, ScriptedAIProcessing, AppSettings) {
    let defaults = UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
    let s = settings ?? AppSettings(userDefaults: defaults)
    s.removeFillerWords = false
    let historyDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vcdr-test-\(UUID().uuidString)")
    let history = FileHistoryStore(storageRoot: historyDir)
    let ai = ScriptedAIProcessing(results: aiResults)
    let overrides = SessionOverrides()
    let processor = TextProcessor(
        aiPort: ai,
        history: history,
        settings: s,
        overrides: overrides,
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
    style: Style = .casual
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
        captures: [],
        conversationID: UUID(),
        destination: OutputDestination.makeDefaultCopy(),
        targetAppPID: nil,
        cursorContext: nil,
        parameterValues: [:],
        variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
        inputSegments: [InputSegment(text: text)],
        hadDestinationOverride: hadDestinationOverride,
        removeFillerWords: false,
        style: style,
        saveResultToClipboard: false
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

    @Test("AI returning [NO_INSTRUCTION] sentinel yields .noInstruction disposition")
    @MainActor
    func noInstructionSentinel() async throws {
        let (processor, history, _, _) = makeProcessor(aiResults: [.success("[NO_INSTRUCTION]")])
        let input = makeInput(processingType: .cloudAI)
        let disposition = try await processor.process(input)

        guard case .noInstruction = disposition else {
            Issue.record("Expected .noInstruction, got \(disposition)")
            return
        }
        #expect(history.conversations.isEmpty)
    }

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
        let (processor, history, _, _) = makeProcessor()
        let input = makeInput(showPreview: true)

        let disposition = try await processor.process(input)
        guard case .preview(let handle) = disposition else {
            Issue.record("Expected .preview")
            return
        }

        // Confirm with the paste destination instead
        try await processor.confirm(handle, destinationOverride: OutputDestination.builtInPasteID)
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
