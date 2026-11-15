import AVFoundation
import Foundation
import Testing
@testable import vcdr_ios

/// Discard (ADR-0003, ADR-0010): the run ends at once and never blocks the
/// next run. A Discard during Capturing saves the verbatim transcript to
/// History as a Discarded Conversation; a Discard during Arming saves nothing.
/// A Discard during Finalizing is ignored.
@MainActor
@Suite("RecordingFlowCoordinator Discard", .serialized)
struct RecordingFlowCoordinatorDiscardTests {

    @Test("discard during Arming goes back to the readiness before Arming at once and saves nothing")
    func discardDuringArmingSavesNothing() async throws {
        let env = Env(captures: ["mid-arming capture"], finishText: "never heard")
        // Widen the Arming window so the Discard lands before `startCapture`
        // returns and the run reaches Capturing.
        env.engine.startCaptureDelay = .milliseconds(200)
        #expect(env.coordinator.state == .idle)

        let startTask = Task { await env.coordinator.startRecording(origin: .keyboard) }
        await waitUntil { env.coordinator.state == .arming }
        await settleMainActor()

        await env.coordinator.discardRecording()
        #expect(env.coordinator.state == .idle)
        #expect(env.channel.readState() == .cancelled)
        #expect(env.coordinator.discardNotes.note == .nothingSaved)
        await startTask.value

        #expect(env.coordinator.state == .idle)
        #expect(env.coordinator.activeRunPhase == nil)
        #expect(!env.engine.isRecording)
        #expect(env.coordinator.capturedTexts.isEmpty)
        #expect(env.channel.readCaptures().isEmpty)
        #expect(env.history.conversations.isEmpty)
    }

    @Test("discard during Arming while the model downloads shows the download again, not Ready")
    func discardDuringArmingKeepsTheModelDownloadShowing() async throws {
        let env = Env(finishText: "never heard")
        ParakeetProviderTestSupport.simulateEncoderLoadDuration = .seconds(1)
        env.engine.startCaptureDelay = .milliseconds(200)
        let initTask = Task { await env.coordinator.initializeModel(predictedVerdict: .coldDownload) }
        await waitUntil { env.coordinator.state == .initializing }

        let startTask = Task { await env.coordinator.startRecording(origin: .keyboard) }
        await waitUntil { env.coordinator.state == .arming }
        await settleMainActor()
        await env.coordinator.discardRecording()

        #expect(env.coordinator.state == .initializing)
        await startTask.value
        #expect(env.coordinator.state == .initializing)
        await initTask.value
        #expect(env.coordinator.state == .ready)
        ParakeetProviderTestSupport.reset()
    }

    @Test("discard during Capturing ends the run at once, and a new start is accepted at once")
    func discardDuringCapturingNeverBlocksTheNextRun() async throws {
        // The gate holds the discarded run's transcription open, so the new
        // start is made while the discarded run still finalizes.
        let gate = FinalizingGate()
        let env = Env(finishText: "hello world", gate: gate)

        await env.coordinator.startRecording(origin: .keyboard)
        #expect(env.coordinator.state == .recording)

        await env.coordinator.discardRecording()

        #expect(env.coordinator.state == .ready)
        #expect(env.coordinator.activeRunPhase == nil)
        #expect(!env.engine.isRecording)
        #expect(env.channel.readState() == .cancelled)
        #expect(env.history.conversations.isEmpty)

        #expect(await env.coordinator.startRecording(origin: .keyboard) == .capturing)
        #expect(env.coordinator.state == .recording)
        #expect(env.channel.readState() == .recording)

        await gate.release()
        await waitUntil { !env.history.conversations.isEmpty }

        #expect(env.history.conversations.count == 1)
        // The new run owns the screen and the wire: no note, no late token.
        #expect(env.coordinator.discardNotes.note == nil)
        #expect(env.coordinator.state == .recording)
        #expect(env.channel.readState() == .recording)
    }

    @Test("the saved Conversation is discarded, with the verbatim text, the captures and the recorded choice")
    func discardSavesTheVerbatimTranscript() async throws {
        SettingOverrides.setAIMode(.dictation)
        SettingOverrides.setTextStyle(.formal)
        defer { SettingOverrides.clearAll() }
        let env = Env(captures: ["context"], finishText: "um hello world")

        await env.coordinator.startRecording(origin: .keyboard)
        await env.coordinator.discardRecording()
        await waitUntil { env.coordinator.discardNotes.note != nil }

        let conversation = try #require(env.history.conversations.first)
        #expect(conversation.status == .discarded(RecordedOutputChoice(
            platform: .ios,
            modeID: "dictation",
            styleID: "formal",
            displayLabel: "Dictation · Formal"
        )))
        #expect(conversation.output == nil)
        #expect(conversation.label == nil)
        // Fillers stay: no Substitutions, no filler removal, no AI.
        #expect(conversation.inputSegments.first?.text == "um hello world")
        #expect(conversation.inputSegments.compactMap(\.capture?.text) == ["context"])
        #expect(env.history.discardedCount == 1)

        #expect(env.coordinator.discardNotes.note == .saved(conversationID: conversation.id))
        #expect(env.coordinator.state == .ready)
        // Nothing is inserted: the keyboard gets `cancelled` and no Bundled Result.
        #expect(env.channel.readState() == .cancelled)
        #expect(env.channel.readCaptures().isEmpty)
        // A keyboard run's app is in the background: the save must not depend
        // on the app staying awake.
        #expect(!env.backgroundTasks.names.isEmpty)
    }

    @Test("a discarded run with no words saves nothing")
    func discardWithNoSpeechSavesNothing() async throws {
        let env = Env(finishText: "  ")

        await env.coordinator.startRecording(origin: .app)
        await env.coordinator.discardRecording()
        await waitUntil { env.coordinator.discardNotes.note != nil }

        #expect(env.coordinator.discardNotes.note == .nothingSaved)
        #expect(env.history.conversations.isEmpty)
        #expect(env.coordinator.state == .ready)
    }

    @Test("a new run's transcription setup waits for the discarded run's decode")
    func newRunSetupWaitsForTheDiscardedDecode() async throws {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let log = SessionLog()
        let decode = FinalizingGate()
        let env = Env(sessions: [
            ScriptedSession(name: "discarded", finishText: "first run", finishGate: decode, log: log),
            ScriptedSession(name: "next", finishText: "second run", log: log),
        ])

        await env.coordinator.startRecording(origin: .app)
        await waitUntil { log.events.contains("discarded.start") }
        await env.coordinator.discardRecording()
        await waitUntil { log.events.contains("discarded.finish.begin") }

        #expect(await env.coordinator.startRecording(origin: .app) == .capturing)
        await settleMainActor()
        #expect(!log.events.contains("next.start"))

        await decode.release()
        await waitUntil { log.events.contains("next.start") }

        #expect(log.events == ["discarded.start", "discarded.finish.begin", "discarded.finish.end", "next.start"])
        _ = await env.coordinator.stopActiveRun()
        #expect(env.history.conversations.map(\.status.isDiscarded) == [true])
    }

    @Test("a RECORD tap removes the Discard note")
    func newStartDismissesTheNote() async throws {
        let env = Env(finishText: "hello world")

        await env.coordinator.startRecording(origin: .app)
        await env.coordinator.discardRecording()
        await waitUntil { env.coordinator.discardNotes.note != nil }

        await env.coordinator.startRecording(origin: .app)
        #expect(env.coordinator.discardNotes.note == nil)
    }

    @Test("VIEW asks History to open on the saved entry")
    func viewOpensHistoryOnTheEntry() async throws {
        let env = Env(finishText: "hello world")

        await env.coordinator.startRecording(origin: .app)
        await env.coordinator.discardRecording()
        await waitUntil { env.coordinator.discardNotes.note != nil }
        let conversation = try #require(env.history.conversations.first)

        env.coordinator.discardNotes.viewInHistory()

        #expect(env.coordinator.discardNotes.historyFocus == conversation.id)
        #expect(env.coordinator.discardNotes.note == nil)
    }

    @Test("discard during Finalizing is ignored and the run completes normally")
    func discardDuringFinalizingIsIgnored() async throws {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let gate = FinalizingGate()
        let env = Env(finishText: "hello world", gate: gate)

        await env.coordinator.startRecording(origin: .app)
        #expect(env.coordinator.state == .recording)

        let stopTask = Task { await env.coordinator.stopActiveRun() }
        await waitUntil { env.coordinator.state == .transcribing }

        await env.coordinator.discardRecording()
        #expect(env.coordinator.state == .transcribing)

        await gate.release()
        _ = await stopTask.value

        guard case .complete(let text) = env.coordinator.state else {
            Issue.record("Expected the run to complete normally despite the Discard; got \(env.coordinator.state)")
            return
        }
        #expect(text.contains("hello world"))
    }

    @Test("mode and style do not cycle during Arming or Capturing, and unlock in Finalizing")
    func outputChoicesLockWhileTheRunListens() async throws {
        SettingOverrides.setAIMode(.verbatim)
        SettingOverrides.setTextStyle(.casual)
        defer { SettingOverrides.clearAll() }
        let gate = FinalizingGate()
        let env = Env(finishText: "hello world", gate: gate)
        env.engine.startCaptureDelay = .milliseconds(200)

        let startTask = Task { await env.coordinator.startRecording(origin: .app) }
        await waitUntil { env.coordinator.state == .arming }
        env.coordinator.cycleAIState()
        env.coordinator.cycleTextStyle()
        #expect(SettingOverrides.effectiveAIMode() == .verbatim)
        #expect(SettingOverrides.effectiveTextStyle() == .casual)

        await startTask.value
        #expect(env.coordinator.state == .recording)
        env.coordinator.cycleAIState()
        env.coordinator.cycleTextStyle()
        #expect(SettingOverrides.effectiveAIMode() == .verbatim)
        #expect(SettingOverrides.effectiveTextStyle() == .casual)

        let stopTask = Task { await env.coordinator.stopActiveRun() }
        await waitUntil { env.coordinator.state == .transcribing }
        env.coordinator.cycleTextStyle()
        #expect(SettingOverrides.effectiveTextStyle() != .casual)

        await gate.release()
        _ = await stopTask.value
    }
}

// MARK: - Environment

@MainActor
private final class Env {
    let engine = SpyWarmRecordingEngine()
    let channel: KeyboardChannel
    let history: FileHistoryStore
    let backgroundTasks = SpyBackgroundTaskRunner()
    let coordinator: RecordingFlowCoordinator

    convenience init(captures: [String] = [], finishText: String = "", gate: FinalizingGate? = nil) {
        let gate = gate ?? FinalizingGate(released: true)
        self.init(captures: captures, makeSession: { GatedStreamingSession(gate: gate, finishText: finishText) })
    }

    /// Hands the sessions out in order, one per Recording Run.
    convenience init(sessions: [ScriptedSession]) {
        var remaining = sessions
        self.init(captures: [], makeSession: { remaining.removeFirst() })
    }

    private init(captures: [String], makeSession: @escaping () -> any RecordingStreamingSession) {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true
        engine.hasMicrophonePermission = true

        let suite = "RecordingFlowCoordinatorDiscardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        channel = KeyboardChannel(defaults: defaults)
        if !captures.isEmpty { channel.replaceCaptures(captures) }

        history = FileHistoryStore(snapshot: FileHistoryStore.loadSnapshot(
            storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        ))
        coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            keyboardChannel: channel,
            recordingEngine: engine,
            transcriptionProvider: ParakeetProvider(),
            backgroundTasks: backgroundTasks,
            discardedRunFinalizer: HistoryDiscardedRunFinalizer(history: history, backgroundTasks: backgroundTasks),
            makeStreamingSession: makeSession
        )
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

@MainActor
private func settleMainActor() async {
    for _ in 0..<10 { await Task.yield() }
}

// MARK: - Finalizing gate

/// Lets a test hold `RecordingRun.stop()` suspended inside `setupTask` (the
/// wrapped `streaming.start()`) so it can act while the run is genuinely in
/// Finalizing, then release it to observe the run complete on its own.
@MainActor
private final class FinalizingGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released: Bool

    init(released: Bool = false) {
        self.released = released
    }

    func awaitRelease() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Never prepares a model — these tests need no real model load, only control
/// over when `RecordingRun.stop()`'s wait on `setupTask` resolves.
/// A main-actor class rather than an actor: Swift 6.4 rejects an actor
/// conforming to the main-actor-isolated protocol from this test target.
@MainActor
private final class GatedStreamingSession: RecordingStreamingSession, @unchecked Sendable {
    private let gate: FinalizingGate
    private let finishText: String

    nonisolated init(gate: FinalizingGate, finishText: String) {
        self.gate = gate
        self.finishText = finishText
    }

    func start() async throws {
        await gate.awaitRelease()
    }

    nonisolated func streamAudio(_ buffer: AVAudioPCMBuffer) {}

    func cancel() async {}

    func finish() async throws -> String {
        finishText
    }

    func liveTranscriptUpdates() async -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

// MARK: - Scripted session

@MainActor
private final class SessionLog {
    private(set) var events: [String] = []

    func note(_ event: String) {
        events.append(event)
    }
}

/// Logs when its model setup and its final decode run, and can hold the final
/// decode open, so a test can see what a later run does meanwhile.
@MainActor
private final class ScriptedSession: RecordingStreamingSession, @unchecked Sendable {
    private let name: String
    private let finishText: String
    private let finishGate: FinalizingGate
    private let log: SessionLog

    init(name: String, finishText: String, finishGate: FinalizingGate? = nil, log: SessionLog) {
        self.name = name
        self.finishText = finishText
        self.finishGate = finishGate ?? FinalizingGate(released: true)
        self.log = log
    }

    func start() async throws {
        log.note("\(name).start")
    }

    nonisolated func streamAudio(_ buffer: AVAudioPCMBuffer) {}

    func cancel() async {}

    func finish() async throws -> String {
        log.note("\(name).finish.begin")
        await finishGate.awaitRelease()
        log.note("\(name).finish.end")
        return finishText
    }

    func liveTranscriptUpdates() async -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
