import Foundation
import FluidAudio
import OSLog
import UIKit

/// Orchestrates the iOS recording lifecycle: initialization, the recording
/// state machine, and start/stop. Each surrounding concern lives in its own
/// same-type extension file, mirroring how the macOS Capture Session is split:
///
/// - `RecordingFlowCoordinator+DeepLink` — deep-link entry points.
/// - `RecordingFlowCoordinator+KeyboardCommands` — Keyboard Channel command +
///   settings listeners.
/// - `RecordingFlowCoordinator+AIProcessing` — AI processing + retry.
/// - `RecordingFlowCoordinator+StatePublishing` — recording-state publishing.
///
/// Members shared across those files are `internal` (or `private(set)`) rather
/// than `private` because Swift scopes `private` to a single file; the
/// coordinator's observable surface is unchanged — views still only read it.
@MainActor
@Observable
final class RecordingFlowCoordinator {
    enum State: Equatable {
        case idle
        case initializing
        case ready
        case recording
        case transcribing
        case complete(String)
        case error(String)
    }

    enum AIProcessingStatus: Equatable {
        case idle
        case processing
        case timedOut
        case completed
        case error(String)
    }

    var state: State = .idle
    private(set) var initProgress: String = "Preparing"
    /// Live transcription text updated in real-time during recording
    private(set) var liveTranscript: String = ""
    /// Shown in the transcribing state — describes what the app is waiting on
    var transcribingMessage: String = ""
    /// When true, the current recording was started via deep link from keyboard.
    /// Exposed for the view to show/hide the back button.
    var launchedViaDeepLink = false
    /// When true, the app was foregrounded by the keyboard's stop-deep-link
    /// fallback (`vcdr-ios://stop`). Drives the Done-page "Swipe to paste"
    /// hint, which is only meaningful in that path — every other way of
    /// landing on the Done page leaves the user already where they want
    /// the text to appear, or with no host app to swipe back to.
    var stoppedViaDeepLink = false
    /// Status of the AI post-processing request
    var aiProcessingStatus: AIProcessingStatus = .idle
    /// Per-session prompt mode — initialized from the current effective setting.
    /// `.verbatim` is the canonical "AI off" value; mode is the single source of
    /// truth for whether AI runs and which prompt it uses.
    var selectedPromptMode: AIPromptMode = SessionSettings.effectiveAIMode()
    /// Per-session text style — initialized from the current effective setting.
    var currentTextStyle: TextStyle = SessionSettings.effectiveTextStyle()

    // MARK: - In-Session Settings (written to session_* storage)

    /// Cycles the AI state through Verbatim → Dictation → Assistant → Verbatim.
    func cycleAIState() {
        switch selectedPromptMode {
        case .verbatim: selectedPromptMode = .dictation
        case .dictation: selectedPromptMode = .assistant
        case .assistant: selectedPromptMode = .verbatim
        }
        SessionSettings.setAIMode(selectedPromptMode)
    }

    func cycleTextStyle() {
        let all = TextStyle.allCases
        let idx = all.firstIndex(of: currentTextStyle) ?? 0
        currentTextStyle = all[(idx + 1) % all.count]
        SessionSettings.setTextStyle(currentTextStyle)
    }

    let audioRecorder: AudioRecorder
    /// Owns the *Hot Mic Session* lifecycle — warm engine, heartbeat, Live
    /// Activity presence, and the inactivity-timeout state machine. This
    /// coordinator drives it via lifecycle notifications (`prewarm`, `start`,
    /// `recordingStarted` / `recordingStopped`, `policyChanged`) and never
    /// touches the engine's warmth directly.
    private let hotMicSession: HotMicSession
    private let transcriptionProvider = ParakeetProvider()
    let keyboardChannel: any KeyboardChannelProtocol
    /// Populated asynchronously by `bootstrapHistory()` — the scene construction
    /// path can't block on it, because `FileManager.url(forUbiquityContainerIdentifier:)`
    /// can take seconds on first launch after install. `nil` until the
    /// bootstrap task completes; callers must tolerate the transient gap.
    private(set) var history: (any HistoryStore)?
    private var isHistoryBootstrapRunning = false
    private let historyCompletionAdapter = HistoryRecordingRunCompletionAdapter()
    private var recordingRun: RecordingRun?
    /// Set to true while `startRecording` is between its UI flip and
    /// `audioRecorder.startCapture` returning. A second tap arriving in that
    /// window would otherwise pass the `!audioRecorder.isRecording` guard
    /// (which is only set inside `startCapture`'s tail) and spawn a duplicate
    /// session + buffer handler — the second tap stomps the first's closure,
    /// leaving the first stream subscribed to no audio.
    private var isStartingRecording = false
    /// Stop can be tapped while `startRecording` is suspended in audio session /
    /// engine startup. Those callers wait here so they don't observe the
    /// half-started state as a missing streaming session.
    private var startWaiters: [CheckedContinuation<Bool, Never>] = []
    /// Text sent to AI processing — retained for the existing Done-page retry action.
    var aiInputText: String = ""
    /// Text selections captured by the keyboard extension during recording (assistant mode only).
    /// Populated from captures published through the Keyboard Channel.
    private(set) var capturedTexts: [String] = []
    /// Tracks the in-flight AI retry so rapid taps cancel the previous attempt.
    var aiRetryTask: Task<Void, Never>?
    /// Token for the keyboard command NotificationCenter observer, stored so we can
    /// remove it before re-registering to prevent observer accumulation on scene re-entry.
    var commandObserverToken: (any NSObjectProtocol)?
    var settingsObserverToken: (any NSObjectProtocol)?

    init(keyboardChannel: (any KeyboardChannelProtocol)? = nil) {
        let recorder = AudioRecorder()
        let keyboardChannel = keyboardChannel ?? KeyboardChannel.live
        audioRecorder = recorder
        self.keyboardChannel = keyboardChannel
        hotMicSession = HotMicSession(engine: recorder, keyboard: keyboardChannel)
    }

    // MARK: - Constants
    private static let initPollInterval: Duration = .milliseconds(200)
    /// Leaves the cooperative executor free for the App Shell's first frame
    /// and immediate navigation before automatic CoreML specialization starts.
    private static let shellRenderGracePeriod: Duration = .milliseconds(500)
    /// Seconds the model can spend in a single init phase before the
    /// progress label starts appending elapsed time. Fast inits stay quiet;
    /// slow ones get a visible tick so the wait reads as bounded.
    private static let initElapsedRevealThreshold: Int = 2

    /// Renders the init progress label for the given phase + elapsed time.
    /// Past `initElapsedRevealThreshold` seconds the label gains a "· Ns"
    /// suffix so a stuck-looking spinner gains a visible heartbeat.
    private static func formatInitProgress(
        phase: ParakeetProvider.InitPhase,
        elapsedSeconds: Int
    ) -> String {
        let base: String
        switch phase {
        case .notStarted: base = "Preparing"
        case .downloading: base = "Downloading model"
        case .compiling: base = "Loading model"
        case .ready: return "Ready"
        }
        if elapsedSeconds >= initElapsedRevealThreshold {
            return "\(base) · \(elapsedSeconds)s"
        }
        return base
    }

    private func waitForRecordingStart() async -> Bool {
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func finishRecordingStart(_ started: Bool) {
        isStartingRecording = false
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: started)
        }
    }

    var isRecording: Bool { audioRecorder.isRecording }
    var isHotSessionActive: Bool { hotMicSession.isAlive }
    var audioLevels: [Float] { audioRecorder.audioLevels }

    // MARK: - Hot Session Lifecycle

    /// Brings the hot mic session up so the next recording begins instantly.
    /// Idempotent — safe to call after model-ready. The `.never` /
    /// `.always` / finite policy, the heartbeat, the Live Activity presence,
    /// and the idle-timeout teardown all live inside `HotMicSession`.
    ///
    /// Skipped while the model is still initializing or after an init failure.
    func startHotSessionIfNeeded() async {
        switch state {
        case .initializing, .error:
            Logger.app.info("startHotSessionIfNeeded: skipping — state is \(String(describing: self.state))")
            return
        default:
            break
        }
        await hotMicSession.startIfPermitted()
    }

    /// Foreground lifecycle hook. A live Hot Mic Session gets its heartbeat and
    /// idle deadline renewed, but cold launch does not start audio preparation.
    func renewHotSessionIfAlive() async {
        await hotMicSession.renewIfAlive()
    }

    /// Resolves the iCloud container and reconciles local ↔︎ ubiquity storage
    /// off the main actor, then constructs the active store on the main actor
    /// (stores are `@Observable` / `@MainActor`, so init must hop back).
    ///
    /// Previously this ran inside the `history` stored-property initializer,
    /// which executes during SwiftUI scene construction on the main actor —
    /// the synchronous `FileManager.url(forUbiquityContainerIdentifier:)`
    /// call blocks for seconds on first launch after install while iCloud
    /// provisions the container, holding back the first frame and leaving
    /// the user staring at the blank launch screen.
    func bootstrapHistory() async {
        Logger.app.info("[LaunchProbe] bootstrapHistory entry main=\(Thread.isMainThread)")
        guard history == nil, !isHistoryBootstrapRunning else {
            Logger.app.info("[LaunchProbe] bootstrapHistory already-bootstrapped")
            return
        }
        isHistoryBootstrapRunning = true
        defer { isHistoryBootstrapRunning = false }
        let defaults = SharedConstants.sharedDefaults
        let syncEnabled = HistoryStoreFactory.effectiveSyncEnabled(defaults: defaults)
        Logger.app.info("[LaunchProbe] bootstrapHistory before reconcile detached")
        await Task.detached(priority: .userInitiated) {
            Logger.app.info("[LaunchProbe] bootstrapHistory reconcile detached body main=\(Thread.isMainThread)")
            HistoryMigrator.reconcileAtLaunch(syncEnabled: syncEnabled)
            Logger.app.info("[LaunchProbe] bootstrapHistory reconcile detached body done main=\(Thread.isMainThread)")
        }.value
        Logger.app.info("[LaunchProbe] bootstrapHistory after reconcile main=\(Thread.isMainThread)")
        let history = HistoryStoreFactory.make(defaults: defaults)
        self.history = history
        historyCompletionAdapter.setHistory(history)
        Logger.app.info("[LaunchProbe] bootstrapHistory exit main=\(Thread.isMainThread)")
    }

    /// Automatic launch path: render the App Shell first, then initialize below
    /// interactive UI priority. A Recording Run bypasses this delay and asks the
    /// provider to initialize promptly through its own setup task.
    func initializeModelAutomatically() async {
        try? await Task.sleep(for: Self.shellRenderGracePeriod)
        guard !Task.isCancelled else { return }
        await Task(priority: .utility) { [weak self] in
            await self?.initializeModel(priority: .utility)
        }.value
    }

    func initializeModel(priority: TaskPriority = .userInitiated) async {
        Logger.app.info("[LaunchProbe] initializeModel entry main=\(Thread.isMainThread) state=\(String(describing: self.state))")
        // If recording already started, model init is handled by the active session setup task.
        guard state != .recording else { return }

        let initStart = ContinuousClock.now
        Logger.app.info("[InitTiming] initializeModel entered")
        state = .initializing
        // Initial label; pollTask below replaces this on the first iteration
        // with phase-true text once `ParakeetProvider.initPhase` advances.
        initProgress = "Preparing"

        let pollTask = Task {
            Logger.app.info("[LaunchProbe] pollTask started main=\(Thread.isMainThread)")
            // Track the last published phase + the last text we wrote so we
            // only mutate `initProgress` (an @Observable) when the visible
            // content actually changes. Unconditional writes here tick at the
            // poll cadence and force a SwiftUI body re-evaluation every
            // iteration, which is enough to starve sheet-presentation
            // animations during init and make the Settings gear feel dead.
            // Past a short grace period we also append elapsed-in-phase so
            // a slow load reads as bounded rather than frozen.
            var lastPhase: ParakeetProvider.InitPhase?
            var phaseStart = ContinuousClock.now
            var lastWrittenText = ""
            while !Task.isCancelled {
                let phase = await transcriptionProvider.initPhase
                if phase != lastPhase {
                    Logger.app.info("[LaunchProbe] pollTask phase=\(String(describing: phase)) main=\(Thread.isMainThread)")
                    phaseStart = ContinuousClock.now
                    lastPhase = phase
                    if phase == .ready { return }
                }

                let elapsedSeconds = Int((ContinuousClock.now - phaseStart).components.seconds)
                let text = Self.formatInitProgress(phase: phase, elapsedSeconds: elapsedSeconds)
                if text != lastWrittenText {
                    initProgress = text
                    lastWrittenText = text
                }
                try? await Task.sleep(for: Self.initPollInterval)
            }
        }

        do {
            Logger.app.info("[LaunchProbe] before transcriptionProvider.initialize await main=\(Thread.isMainThread)")
            try await transcriptionProvider.initialize(priority: priority)
            Logger.app.info("[LaunchProbe] after transcriptionProvider.initialize main=\(Thread.isMainThread)")
            Logger.app.info("[InitTiming] transcriptionProvider.initialize() done at +\(ContinuousClock.now - initStart)")

            pollTask.cancel()
            // Don't overwrite state if recording started while we were initializing
            if state == .initializing {
                state = .ready
            }
            initProgress = "Ready"
            Logger.app.info("[InitTiming] initializeModel complete at +\(ContinuousClock.now - initStart)")

            // Audio preparation is opportunistic follow-up work. It must not
            // delay Transcription Readiness or prompt on automatic launch.
            Task { [weak self] in
                guard let self else { return }
                await self.hotMicSession.prewarmIfPermitted()
                await self.startHotSessionIfNeeded()
            }
        } catch {
            pollTask.cancel()
            if state == .initializing {
                state = .error("Model initialization failed: \(error.localizedDescription)")
            }
            Logger.app.error("Model init failed: \(error)")
        }
    }

    // MARK: - Recording State Machine

    /// Starts recording with real-time streaming transcription.
    /// Audio capture begins immediately; model initialization and streaming setup
    /// proceed in the background. Buffers queue in StreamingAsrManager's AsyncStream
    /// until the recognition task starts consuming them.
    /// - Parameter fromDeepLink: When true, transcription result will be sent to the keyboard extension.
    func startRecording(fromDeepLink: Bool = false) async {
        // Prevent double-start from rapid button taps or duplicate deep links.
        // Check audioRecorder.isRecording (not state) because the deep link flow
        // sets state = .recording synchronously in prepareForDeepLinkRecording()
        // before this method runs — blocking on state would prevent actual startup.
        // `isStartingRecording` covers the window between the UI flip and
        // `startCapture` returning, when `isRecording` is still false but a
        // setup is already in progress.
        guard !audioRecorder.isRecording, !isStartingRecording, recordingRun == nil else {
            Logger.app.info("[RecordTiming] startRecording bailed — session already active or starting")
            return
        }
        isStartingRecording = true
        let recordStart = ContinuousClock.now
        Logger.app.info("[RecordTiming] startRecording entered")

        // UI flip FIRST — nothing blocks it. Everything perceptually slow
        // (haptics, UserDefaults reads, disk flushes, engine start) runs after.
        launchedViaDeepLink = fromDeepLink
        stoppedViaDeepLink = false
        aiProcessingStatus = .idle
        state = .recording
        setIdleTimerDisabled(true)
        Logger.app.info("[RecordTiming] state=recording set at +\(ContinuousClock.now - recordStart)")

        // Haptics on detached task — CHHapticEngine daemon connect can block
        // for seconds under concurrent CoreML load.
        Task { @MainActor in UIImpactFeedbackGenerator(style: .medium).impactOccurred() }

        // Session snapshot from shared defaults — fields are only consumed on stop /
        // AI processing, so schedule them after the audio start rather than blocking
        // the hot path. UserDefaults reads + JSON decode can cost 5-50ms on MainActor
        // under I/O contention; the stop-time re-read catches anything the keyboard
        // writes while recording.
        capturedTexts = []
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.selectedPromptMode = SessionSettings.effectiveAIMode()
            self.currentTextStyle = SessionSettings.effectiveTextStyle()
            let texts = self.keyboardChannel.readCaptures()
            if !texts.isEmpty {
                self.capturedTexts = texts
                Logger.ai.info("Initial captures on start: \(texts.count) item(s)")
            }
            self.keyboardChannel.clearLegacySelectedText()
        }

        // Shared-defaults write + Darwin post — off the critical path.
        // Keyboard extension reads this asynchronously anyway.
        Task.detached { [weak self] in
            await self?.writeStateAsync(.recording)
        }

        // We're about to record: cancel any pending hot-session teardown and
        // light the heartbeat + presence now. The cold path warms the engine
        // via `startCapture` below without ever going through `start()`, so the
        // session needs telling regardless of how it got hot.
        hotMicSession.recordingStarted()

        let run = makeRecordingRun(deliversToKeyboard: fromDeepLink)
        recordingRun = run
        Logger.app.info("[RecordTiming] recording run created at +\(ContinuousClock.now - recordStart)")

        let started = await run.start()
        Logger.app.info("[RecordTiming] audioRecorder.startCapture returned at +\(ContinuousClock.now - recordStart)")

        guard started else {
            state = .error("Failed to start recording — check microphone permission")
            writeState(.idle)
            recordingRun = nil
            // The engine never came up, so tear down the heartbeat/presence we
            // optimistically lit above rather than leaving them orphaned.
            hotMicSession.recordingStopped()
            finishRecordingStart(false)
            return
        }

        finishRecordingStart(true)
    }

    /// Stops recording and shows the result immediately from the live transcript.
    /// Finalizes streaming in the background and updates the result if it differs.
    /// - Parameter sendToKeyboard: When true, the transcription result is delivered to the keyboard extension via state bundling.
    func stopAndTranscribe(sendToKeyboard: Bool = false) async {
        if isStartingRecording {
            Logger.app.info("[RecordTiming] stopAndTranscribe waiting for in-flight recording start")
            guard await waitForRecordingStart() else {
                Logger.app.info("[RecordTiming] stopAndTranscribe aborted because recording start failed")
                setIdleTimerDisabled(false)
                writeState(.idle)
                return
            }
        }

        // Fire haptics as a separate task so CHHapticEngine init (which connects
        // to a system daemon) doesn't block recording start. Under heavy CoreML
        // compilation load the daemon can take seconds to respond.
        Task { @MainActor in UIImpactFeedbackGenerator(style: .medium).impactOccurred() }

        hotMicSession.recordingStopped()
        setIdleTimerDisabled(false)

        // Re-read the captures array — the keyboard may have added more during recording.
        if sendToKeyboard {
            let texts = keyboardChannel.readCaptures()
            if !texts.isEmpty {
                capturedTexts = texts
                Logger.ai.info("Final captures on stop: \(texts.count) item(s)")
            }
            keyboardChannel.clearCaptures()
        }

        guard let run = recordingRun else {
            state = .error("Recording was interrupted before audio started")
            writeState(.idle)
            return
        }

        state = .transcribing
        writeState(.transcribing)

        let terminalState = await run.stop(deliversToKeyboard: sendToKeyboard)
        applyTerminalStateToUI(terminalState)
        recordingRun = nil
    }

    private func applyTerminalStateToUI(_ terminalState: RecordingRunTerminalState) {
        switch terminalState {
        case .success(let success):
            state = .complete(success.finalText)
        case .emptyResult:
            state = .error("No speech detected")
        case .cancellation:
            state = .ready
        case .processingFailure(let failure):
            state = .error(failure.message)
        }
    }

    private func makeRecordingRun(deliversToKeyboard: Bool) -> RecordingRun {
        RecordingRun(
            audioRecorder: audioRecorder,
            transcriptionProvider: transcriptionProvider,
            transcriptProcessor: makeTranscriptProcessor(),
            completionAdapters: [
                KeyboardChannelRecordingRunCompletionAdapter(
                    keyboardChannel: keyboardChannel,
                    deliversToKeyboard: deliversToKeyboard
                ),
                historyCompletionAdapter
            ],
            currentSettings: { [weak self] in
                guard let self else {
                    return RecordingRun.Settings(
                        promptMode: .verbatim,
                        textStyle: .casual,
                        hasAICapability: false
                    )
                }
                self.resyncSettingsFromSharedDefaults()
                return RecordingRun.Settings(
                    promptMode: self.selectedPromptMode,
                    textStyle: self.currentTextStyle,
                    hasAICapability: AIProcessingSettings.hasAICapability
                )
            },
            currentCaptures: { [weak self] in
                self?.capturedTexts ?? []
            },
            onLiveTranscript: { [weak self] text in
                self?.liveTranscript = text
            },
            onInterimResult: { [weak self] text in
                self?.state = .complete(text)
            },
            onTranscribingMessage: { [weak self] message in
                self?.transcribingMessage = message
            }
        )
    }

    // MARK: - Cross-process settings sync

    /// Re-reads mode/style from shared defaults right before a pipeline
    /// decision. Guards against cross-process staleness: the keyboard may
    /// have flipped mode since the last Darwin `settingsChanged` notif
    /// landed, and `handleSettingsChanged`'s MainActor task may still be
    /// queued. `synchronize()` forces the current process to pull the latest
    /// cross-process writes. Cheap (µs) — safe to call on hot paths.
    func resyncSettingsFromSharedDefaults() {
        SharedConstants.sharedDefaults.synchronize()
        selectedPromptMode = SessionSettings.effectiveAIMode()
        currentTextStyle = SessionSettings.effectiveTextStyle()
    }

    func reset() {
        state = .ready
        writeState(.idle)
        setIdleTimerDisabled(false)
        liveTranscript = ""
        launchedViaDeepLink = false
        stoppedViaDeepLink = false
        aiProcessingStatus = .idle
        selectedPromptMode = SessionSettings.effectiveAIMode()
        currentTextStyle = SessionSettings.effectiveTextStyle()
        capturedTexts = []
        let run = recordingRun
        recordingRun = nil
        Task { await run?.cancel() }
        if isStartingRecording {
            finishRecordingStart(false)
        }
        aiRetryTask?.cancel()
        aiRetryTask = nil
        // Re-arm the inactivity timer so a reset counts as fresh activity
        // rather than leaving a stale teardown scheduled from the prior flow.
        hotMicSession.recordingStopped()
    }

    // MARK: - Idle Timer

    /// Prevents the screen from auto-locking while recording is active.
    /// Must be re-applied after scene phase transitions (iOS can reset it).
    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
        Logger.app.info("Idle timer \(disabled ? "disabled" : "enabled")")
    }
}
