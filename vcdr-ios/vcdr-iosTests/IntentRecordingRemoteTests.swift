import Foundation
import Testing
@testable import vcdr_ios

/// What a Shortcut or the card's Stop button does to VCDR, through the remote
/// the intents resolve.
@MainActor
@Suite("IntentRecordingRemote", .serialized)
struct IntentRecordingRemoteTests {
    @MainActor
    private struct Env {
        let engine = SpyWarmRecordingEngine()
        let card = SpyMicPresenceCard()
        let pasteboard = SpyPasteboard()
        let coordinator: RecordingFlowCoordinator
        let remote: IntentRecordingRemote

        init(requiresCardToRecord: Bool = true, startCaptureDelay: Duration = .zero) {
            engine.hasMicrophonePermission = true
            engine.startCaptureDelay = startCaptureDelay
            coordinator = RecordingFlowCoordinator(
                presence: card,
                keyboardChannel: FakeKeyboardChannel(),
                recordingEngine: engine,
                backgroundTasks: SpyBackgroundTaskRunner(),
                pasteboard: pasteboard,
                makeStreamingSession: { FakeRecordingStreamingSession(result: .success("hello world")) }
            )
            remote = IntentRecordingRemote(
                boot: AppBoot(steps: AppBoot.Steps(prefix: {}, deferred: {})),
                coordinator: coordinator,
                card: card,
                requiresCardToRecord: requiresCardToRecord
            )
        }
    }

    /// Toggles once and answers the refusal, or nil when the toggle went ahead.
    private func toggle(_ env: Env) async -> RecordingRemoteRefusal? {
        do {
            try await env.remote.toggleFromShortcut()
            return nil
        } catch {
            return error
        }
    }

    @Test("without microphone permission the toggle refuses and starts no run")
    func noMicrophonePermission() async {
        let env = Env()
        env.engine.hasMicrophonePermission = false

        #expect(await toggle(env) == .microphoneNotAllowed)
        #expect(env.coordinator.activeRunPhase == nil)
        #expect(env.card.runs.isEmpty)
    }

    @Test("on iPhone, Live Activities turned off refuse the start")
    func liveActivitiesOffOnPhone() async {
        let env = Env()
        env.card.areActivitiesEnabled = false

        #expect(await toggle(env) == .liveActivitiesOff)
        #expect(env.coordinator.activeRunPhase == nil)
    }

    @Test("on iPad, Live Activities turned off still record")
    func liveActivitiesOffOnPad() async {
        let env = Env(requiresCardToRecord: false)
        env.card.areActivitiesEnabled = false
        env.card.showsCard = false

        #expect(await toggle(env) == nil)
        guard case .capturing? = env.coordinator.activeRunPhase else {
            Issue.record("Expected Capturing, got \(String(describing: env.coordinator.activeRunPhase))")
            return
        }
    }

    @Test("on iPhone, a card ActivityKit refuses discards the run")
    func refusedCardDiscardsTheRun() async {
        let env = Env()
        env.card.showsCard = false

        #expect(await toggle(env) == .cardUnavailable)
        #expect(env.coordinator.activeRunPhase == nil)
        #expect(!env.engine.isRecording)
        #expect(env.pasteboard.writes.isEmpty)
    }

    @Test("a second toggle during Arming cancels the run and copies nothing")
    func doublePressCancels() async {
        let env = Env(startCaptureDelay: .milliseconds(200))

        let first = Task { await toggle(env) }
        await waitUntil { env.coordinator.activeRunPhase == .arming }
        #expect(await toggle(env) == nil)
        #expect(await first.value == nil)

        #expect(env.coordinator.activeRunPhase == nil)
        #expect(env.pasteboard.writes.isEmpty)
    }

    @Test("a second toggle copies the text and the card goes from Transcribing to Copied")
    func toggleTwiceCopies() async {
        SessionSettings.setAIMode(.verbatim)
        defer { SessionSettings.clearAll() }
        let env = Env()

        #expect(await toggle(env) == nil)
        #expect(await toggle(env) == nil)
        await waitUntil { env.coordinator.activeRunPhase == nil }

        #expect(env.pasteboard.writes.count == 1)
        #expect(env.pasteboard.writes.first?.localizedCaseInsensitiveContains("hello world") == true)
        let lastTwo = Array(env.card.runs.suffix(2))
        guard lastTwo.count == 2,
              case .active(.shortcut, .finalizing)? = lastTwo[0],
              case .concluded(.copied, _)? = lastTwo[1] else {
            Issue.record("Expected Finalizing then Copied, got \(lastTwo)")
            return
        }
    }

    @Test("the card's Stop button never starts a run")
    func stopFromCardWithoutRun() async {
        let env = Env()

        await env.remote.stopFromCard()
        await Task.yield()

        #expect(env.coordinator.activeRunPhase == nil)
        #expect(env.card.runs.isEmpty)
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
