import Foundation
import FluidAudio
import OSLog
import UIKit

private enum PrewarmBarrierResult: Sendable {
    case prewarmFinished
    case timedOut
}

private final class PrewarmBarrierContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ result: PrewarmBarrierResult,
        _ continuation: CheckedContinuation<PrewarmBarrierResult, Never>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: result)
    }
}

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
        /// Recording Run phase: the record intent is acknowledged and the audio
        /// engine is warming, but no audio is captured yet. Honest facade — the
        /// UI shows the tap registered ("STARTING…") without a timer or waveform.
        /// About the audio engine, never the transcription model.
        case arming
        /// Recording Run phase: audio is flowing (Capturing). Timer + waveform
        /// are truthful. May precede Transcription Readiness; transcription
        /// catches up at Finalizing (`.transcribing`).
        case recording
        case transcribing
        /// Brief Discard acknowledgement — auto-reverts to idle or ready.
        case cancelled
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
    /// True while artifacts are already on disk and Transcription Readiness is
    /// still pending. The hero may show READY because Recording Runs can begin
    /// during this window; PREPARING remains reserved for Cold Download.
    private(set) var isModelWarming = false
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

    private let recordingEngine: any RecordingEngine
    /// Owns the *Hot Mic Session* lifecycle — warm engine, heartbeat, Live
    /// Activity presence, and the inactivity-timeout state machine. This
    /// coordinator drives it via lifecycle notifications (`prewarm`, `start`,
    /// `recordingStarted` / `recordingStopped`, `policyChanged`) and never
    /// touches the engine's warmth directly.
    private let hotMicSession: HotMicSession
    private let transcriptionProvider: ParakeetProvider
    /// Builds the streaming transport for each Recording Run. Defaults to the
    /// production `LiveRecordingStreamingSession`; tests inject a controllable
    /// fake to hold a run in Finalizing so Discard's ignore-during-Finalizing
    /// behaviour can be exercised deterministically.
    private let makeStreamingSession: () -> any RecordingStreamingSession
    /// Reused, prewarmed haptic generator. A freshly constructed generator
    /// connects to the haptic daemon lazily on its first `impactOccurred()`,
    /// and that connect blocks the *main thread* for seconds under the
    /// concurrent CoreML ANE compile — the cold-launch freeze that swallowed
    /// the record tap and starved every other main-actor task. Prewarmed via
    /// `prepare()` once the model is ready (system idle); the record/stop paths
    /// skip it until then.
    private let recordHaptic = UIImpactFeedbackGenerator(style: .medium)
    /// Cached transcription-model readiness for synchronous checks on the hot
    /// path (the authoritative flag lives in the `ParakeetProvider` actor).
    /// Gates the haptic so a cold first-use connect never blocks recording.
    private var isModelReady = false
    let keyboardChannel: any KeyboardChannelProtocol
    /// Populated asynchronously by `bootstrapHistory()` — the scene construction
    /// path can't block on it, because `FileManager.url(forUbiquityContainerIdentifier:)`
    /// can take seconds on first launch after install. `nil` until the
    /// bootstrap task completes; callers must tolerate the transient gap.
    private(set) var history: (any HistoryStore)?
    private var isHistoryBootstrapRunning = false
    /// Stable Substitution store reference handed out at launch. Backed by a
    /// proxy so the Settings screen and the recording pipeline can read it
    /// immediately, while the real (possibly iCloud-backed) store is resolved
    /// off-main in `bootstrapSubstitutions()`. Mirrors the macOS
    /// `AppDependencies.substitutionStore` shell-first pattern.
    let substitutionStore = SubstitutionStoreProxy()
    private var isSubstitutionBootstrapRunning = false
    private let historyCompletionAdapter = HistoryRecordingRunCompletionAdapter()
    private var recordingRun: RecordingRun?
    /// Set to true while `startRecording` is between its UI flip and
    /// `audioRecorder.startCapture` returning. A second tap arriving in that
    /// window would otherwise pass the `!audioRecorder.isRecording` guard
    /// (which is only set inside `startCapture`'s tail) and spawn a duplicate
    /// session + buffer handler — the second tap stomps the first's closure,
    /// leaving the first stream subscribed to no audio.
    private var isStartingRecording = false
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

    init(
        keyboardChannel: (any KeyboardChannelProtocol)? = nil,
        recordingEngine: (any RecordingEngine)? = nil,
        transcriptionProvider: ParakeetProvider? = nil,
        hotMicSession: HotMicSession? = nil,
        makeStreamingSession: (() -> any RecordingStreamingSession)? = nil
    ) {
        let engine = recordingEngine ?? AudioRecorder()
        let keyboardChannel = keyboardChannel ?? KeyboardChannel.live
        self.recordingEngine = engine
        self.transcriptionProvider = transcriptionProvider ?? ParakeetProvider()
        self.keyboardChannel = keyboardChannel
        self.hotMicSession = hotMicSession ?? HotMicSession(engine: engine, keyboard: keyboardChannel)
        self.makeStreamingSession = makeStreamingSession ?? { LiveRecordingStreamingSession() }
    }

    // MARK: - Constants
    private static let initPollInterval: Duration = .milliseconds(200)
    /// Leaves the cooperative executor free for the App Shell's first frame
    /// and immediate navigation before automatic CoreML specialization starts.
    private static let shellRenderGracePeriod: Duration = .milliseconds(500)
    /// Grace before automatic init on a predicted-Warm launch. A warm load is
    /// ~2s of GCD work with no ANE grind, so the shell only needs first-frame
    /// headroom — the full cold grace would just be latency floor (F6).
    private static let warmShellRenderGracePeriod: Duration = .milliseconds(100)
    /// Upper bound on the predicted-Warm prewarm barrier. When there is no
    /// expected encoder specialization to isolate, audio prep must not hold
    /// Transcription Readiness hostage behind route/Bluetooth HAL delays.
    private static let predictedWarmPrewarmBarrierTimeout: Duration = .seconds(2)
    /// Seconds the model can spend in a single init phase before the
    /// progress label starts appending elapsed time. Fast inits stay quiet;
    /// slow ones get a visible tick so the wait reads as bounded.
    private static let initElapsedRevealThreshold: Int = 2
    private nonisolated static let initElapsedRevealThresholdForLabel: Int = 2

    /// Renders the init progress label for the given phase + elapsed time.
    /// Past `initElapsedRevealThreshold` seconds the label gains a "· Ns"
    /// suffix so a stuck-looking spinner gains a visible heartbeat.
    nonisolated static func formatInitProgress(
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
        if elapsedSeconds >= initElapsedRevealThresholdForLabel {
            return "\(base) · \(elapsedSeconds)s"
        }
        return base
    }

    var isRecording: Bool { recordingEngine.isRecording }
    var isHotSessionActive: Bool { hotMicSession.isAlive }
    var audioLevels: [Float] { recordingEngine.audioLevels }

    // MARK: - Hot Session Lifecycle

    /// Foreground lifecycle hook. A live Hot Mic Session gets its heartbeat and
    /// idle deadline renewed, but cold launch does not start audio preparation.
    func renewHotSessionIfAlive() async {
        await hotMicSession.renewIfAlive()
    }

    /// Resolves the iCloud container and reconciles local ↔︎ ubiquity storage
    /// off the main actor, then constructs the active store on the main actor
    /// (stores are `@Observable` / `@MainActor`, so init must hop back).
    ///
    /// The iCloud resolve — `FileManager.url(forUbiquityContainerIdentifier:)`,
    /// reached via `resolveStorageRoot()` — blocks for seconds while iCloud
    /// provisions the container. It must run on a GCD thread via
    /// `withBlockingTask`, NOT on a `Task.detached` (cooperative pool): a
    /// blocking syscall there pins one of the pool's few threads for its whole
    /// duration and starves other launch work — notably model init, which then
    /// can't even start until the resolve returns (see ADR-0002 / `BlockingWork`).
    /// Resolve exactly once and reuse the root for both reconcile and store
    /// construction so `make` never blocks the main actor a second time.
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
        Logger.app.info("[LaunchProbe] bootstrapHistory before resolve+reconcile (GCD)")
        let ubiquityRoot: URL? = await withBlockingTask(qos: .userInitiated) {
            let root = UbiquityHistoryStore.resolveStorageRoot()
            HistoryMigrator.reconcileAtLaunch(syncEnabled: syncEnabled, ubiquityRoot: root)
            return root
        }
        Logger.app.info("[LaunchProbe] bootstrapHistory after resolve+reconcile main=\(Thread.isMainThread) iCloud=\(ubiquityRoot != nil)")
        let history = HistoryStoreFactory.make(defaults: defaults, ubiquityRoot: ubiquityRoot)
        self.history = history
        historyCompletionAdapter.setHistory(history)
        Logger.app.info("[LaunchProbe] bootstrapHistory exit main=\(Thread.isMainThread)")
    }

    /// Deferred Substitutions bootstrap, mirroring `bootstrapHistory`: resolves
    /// the iCloud ubiquity container off-main (it can block for seconds on first
    /// launch), builds the real store via the factory on the main actor, and
    /// installs it on the proxy — replaying any edits the user made before the
    /// store was ready. The proxy stays the stable reference handed to the UI
    /// and pipeline throughout.
    func bootstrapSubstitutions() async {
        guard !isSubstitutionBootstrapRunning else { return }
        isSubstitutionBootstrapRunning = true
        defer { isSubstitutionBootstrapRunning = false }
        let defaults = SharedConstants.sharedDefaults
        let ubiquityRoot: URL? = await withBlockingTask(qos: .userInitiated) {
            UbiquitySubstitutionStore.resolveStorageRoot()
        }
        let store = SubstitutionStoreFactory.make(defaults: defaults, ubiquityRoot: ubiquityRoot)
        substitutionStore.setRealStore(store)
    }

    /// Automatic launch path, driven by the Predicted Launch Verdict. A
    /// predicted-Warm launch initializes at `.userInitiated` with only a short
    /// shell grace — `.utility` is throttled under Low Power Mode and elevated
    /// thermal state, stretching a warm ~2s load to 10s+ (F2), and the QoS
    /// choice only earns its keep when a cold grind is expected. Predicted-cold
    /// launches keep the full grace and `.utility` so the App Shell stays
    /// responsive during the specialization grind. A Recording Run bypasses
    /// this delay and asks the provider to initialize promptly through its own
    /// setup task. Mispredictions are visible in Launch History: the actual
    /// verdict lands in launch telemetry alongside this prediction's log line.
    func initializeModelAutomatically() async {
        let predicted = await LaunchTelemetry.predictedVerdict()
        publishReadinessPresentation(for: predicted)
        let warmPredicted = predicted == .warm
        let priority: TaskPriority = warmPredicted ? .userInitiated : .utility
        let grace = warmPredicted ? Self.warmShellRenderGracePeriod : Self.shellRenderGracePeriod
        Logger.app.info(
            "[InitTiming] predicted verdict=\(predicted.rawValue) "
                + "qos=\(warmPredicted ? "userInitiated" : "utility") "
                + "graceMs=\(Int(grace / .milliseconds(1)))"
        )
        try? await Task.sleep(for: grace)
        guard !Task.isCancelled else { return }
        await Task(priority: priority) { [weak self] in
            await self?.initializeModel(priority: priority, predictedVerdict: predicted)
        }.value
    }

    func initializeModel(
        priority: TaskPriority = .userInitiated,
        predictedVerdict: LaunchVerdict = .coldSpecialize,
        prewarmBarrierTimeout: Duration = RecordingFlowCoordinator.predictedWarmPrewarmBarrierTimeout
    ) async {
        Logger.app.info("[LaunchProbe] initializeModel entry main=\(Thread.isMainThread) state=\(String(describing: self.state))")
        // If recording already started, model init is handled by the active session setup task.
        guard state != .recording else { return }

        let initStart = ContinuousClock.now
        Logger.app.info("[InitTiming] initializeModel entered")
        publishReadinessPresentation(for: predictedVerdict)
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
            // HAL warm runs in parallel with the cheap core loads and must
            // finish before the encoder grind (ADR-0001). Prewarm does not call
            // `engine.start()` — no microphone indicator.
            let prewarmTask = Task { [hotMicSession] in
                await hotMicSession.prewarmIfPermitted()
            }
            Logger.app.info("[LaunchProbe] before transcriptionProvider.loadCoreModels await main=\(Thread.isMainThread)")
            try await transcriptionProvider.loadCoreModels(
                priority: priority,
                predictedVerdict: predictedVerdict
            )
            Logger.app.info("[LaunchProbe] before engine prewarm barrier main=\(Thread.isMainThread)")
            await waitForPrewarmBarrier(
                prewarmTask,
                predictedVerdict: predictedVerdict,
                timeout: prewarmBarrierTimeout
            )
            Logger.app.info("[LaunchProbe] before transcriptionProvider.finishWithEncoder await main=\(Thread.isMainThread)")
            try await transcriptionProvider.finishWithEncoder()
            Logger.app.info("[LaunchProbe] after transcriptionProvider.finishWithEncoder main=\(Thread.isMainThread)")
            Logger.app.info("[InitTiming] transcriptionProvider two-phase init done at +\(ContinuousClock.now - initStart)")

            pollTask.cancel()
            // Don't overwrite state if recording started while we were initializing
            if state == .initializing {
                state = .ready
            }
            initProgress = "Ready"
            isModelWarming = false
            isModelReady = true
            // Warm the haptic daemon now that the ANE compile is done and the
            // system is idle, so the first record-tap haptic fires instantly
            // instead of connecting under load on the main thread.
            recordHaptic.prepare()
            Logger.app.info("[InitTiming] initializeModel complete at +\(ContinuousClock.now - initStart)")
            if let outcome = await transcriptionProvider.launchLoadOutcome {
                await LaunchTelemetry.recordOnce(outcome: outcome)
                if outcome.verdict == .coldSpecialize {
                    await UserDefaultsBackgroundModelWarmTriggerStore()
                        .markPurgeTrigger(.coldSpecializeVerdict)
                    BackgroundModelWarmScheduler.schedule()
                } else if outcome.verdict == .warm {
                    await UserDefaultsBackgroundModelWarmTriggerStore()
                        .clearPendingPurgeTrigger()
                }
            }

            // Transcription Readiness does not grant Post-Capture Warmth. If a
            // Hot Mic Session is already alive, re-sync its heartbeat/deadline;
            // otherwise leave the audio engine cold until a Recording Run
            // reaches Capturing.
            Task { [weak self] in
                guard let self else { return }
                await self.renewHotSessionIfAlive()
            }
        } catch {
            pollTask.cancel()
            isModelWarming = false
            if state == .initializing || state == .ready {
                state = .error("Model initialization failed: \(error.localizedDescription)")
            }
            Logger.app.error("Model init failed: \(error)")
        }
    }

    private func publishReadinessPresentation(for predictedVerdict: LaunchVerdict) {
        switch predictedVerdict {
        case .coldDownload:
            isModelWarming = false
            state = .initializing
        case .coldSpecialize, .warm:
            isModelWarming = true
            if state == .idle || state == .initializing {
                state = .ready
            }
        }
    }

    private func waitForPrewarmBarrier(
        _ prewarmTask: Task<Void, Never>,
        predictedVerdict: LaunchVerdict,
        timeout: Duration
    ) async {
        guard predictedVerdict == .warm else {
            await prewarmTask.value
            return
        }

        let result = await withCheckedContinuation { continuation in
            let resumeBox = PrewarmBarrierContinuation()
            Task {
                await prewarmTask.value
                resumeBox.resume(.prewarmFinished, continuation)
            }
            Task {
                try? await Task.sleep(for: timeout)
                resumeBox.resume(.timedOut, continuation)
            }
        }

        switch result {
        case .prewarmFinished:
            Logger.app.info("[InitTiming] predicted-warm prewarm barrier finished before timeout")
        case .timedOut:
            Logger.app.warning(
                "[InitTiming] predicted-warm prewarm barrier timed out after "
                    + "\(Int(timeout / .milliseconds(1)))ms; continuing to encoder while prewarm remains in flight"
            )
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
        guard !recordingEngine.isRecording, !isStartingRecording, recordingRun == nil else {
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
        // Arming, not Capturing: the tap is acknowledged instantly, but the
        // audio engine isn't up yet. The UI shows "STARTING…" with no timer or
        // waveform until audio actually flows (see the `.arming` guard below).
        state = .arming
        setIdleTimerDisabled(true)
        Logger.app.info("[RecordTiming] state=arming set at +\(ContinuousClock.now - recordStart)")

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

        // We're about to record: protect any already-alive Hot Mic Session
        // while Arming, without creating fresh Mic Presence for a cold engine.
        hotMicSession.recordIntentStarted()

        let run = makeRecordingRun(deliversToKeyboard: fromDeepLink)
        recordingRun = run
        Logger.app.info("[RecordTiming] recording run created at +\(ContinuousClock.now - recordStart)")

        let started = await run.start()
        Logger.app.info("[RecordTiming] audioRecorder.startCapture returned (Capturing) at +\(ContinuousClock.now - recordStart)")

        guard started else {
            // Engine warmup failed (mic seized, route/HAL error). The Recording
            // Run already terminated in processing failure inside `run.start()`,
            // and its keyboard completion adapter has already published that
            // failure on the wire — writing anything here would overwrite the
            // reason with a state the run did not reach (ADR-0004).
            state = .error("Microphone unavailable — couldn't start recording")
            recordingRun = nil
            hotMicSession.recordIntentCancelledBeforeCapture()
            isStartingRecording = false
            return
        }

        // Stop landed while we were Arming: the stop handler flipped state off
        // `.arming` (to `.idle`). The engine is up now, but the user already
        // cancelled — tear the run down instead of entering Capturing.
        guard state == .arming else {
            _ = await run.cancel()
            recordingRun = nil
            hotMicSession.recordIntentCancelledBeforeCapture()
            isStartingRecording = false
            return
        }

        // Capturing: audio is flowing. Flip to the truthful recording UI (timer
        // + waveform) and fire the "go" haptic — the auto-start signal. Skipped
        // while the model is cold so a first-use haptic-daemon connect can't
        // block the main thread under the concurrent ANE compile.
        state = .recording
        hotMicSession.recordingStarted()
        if isModelReady { recordHaptic.impactOccurred() }
        isStartingRecording = false
    }

    /// Stops recording and shows the result immediately from the live transcript.
    /// Finalizes streaming in the background and updates the result if it differs.
    /// - Parameter sendToKeyboard: When true, the transcription result is delivered to the keyboard extension via state bundling.
    func stopAndTranscribe(sendToKeyboard: Bool = false) async {
        if isStartingRecording {
            // Stop landed during Arming — no audio ever flowed. Flip to idle
            // instantly (responsiveness-first); the in-flight start sees state
            // is no longer `.arming` and tears the run down. This is a
            // cancellation, not an Empty Result, and the wire now says so.
            Logger.app.info("[RecordTiming] stopAndTranscribe during Arming — cancelling")
            abortArming()
            return
        }

        // Haptic only when the model is warm — a cold first-use connect blocks
        // the main thread for seconds under ANE-compile load (see startRecording).
        if isModelReady { recordHaptic.impactOccurred() }

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
            // No run means no completion adapter to publish for us, so this is
            // the one Processing Failure the coordinator puts on the wire
            // itself — and only when the keyboard is the one waiting for it.
            let reason = "Recording was interrupted before audio started"
            Logger.recording.error("Publishing failure: stop found no Recording Run — \(reason)")
            state = .error(reason)
            if sendToKeyboard {
                writeFailure(reason: reason)
            } else {
                writeState(.idle)
            }
            return
        }

        state = .transcribing
        writeState(.transcribing)

        let terminalState = await run.stop(deliversToKeyboard: sendToKeyboard)
        applyTerminalStateToUI(terminalState)
        recordingRun = nil
    }

    /// Ends the active Recording Run without producing text (Discard,
    /// ADR-0003). Scoped to Arming and Capturing:
    /// - Arming reuses the exact path a stop landing mid-Arming already takes
    ///   (`abortArming`) — the in-flight `startRecording` tears the run down
    ///   once it observes `state` is no longer `.arming`.
    /// - Capturing cancels the run directly, terminating in `.cancellation`
    ///   (no Bundled Result, no Conversation — see `RecordingRunCompletion`
    ///   adapters) while leaving the Hot Mic Session warm exactly as a normal
    ///   stop does.
    /// - Any other state (notably Finalizing / `.transcribing`) is ignored —
    ///   a model load or AI call already in flight is not abortable.
    func discardRecording() async {
        if isStartingRecording {
            Logger.app.info("[RecordTiming] discardRecording during Arming — cancelling")
            clearCapturedTexts()
            abortArming()
            flashCancelled(revertingTo: .idle)
            return
        }

        guard state == .recording, let run = recordingRun else { return }

        hotMicSession.recordingStopped()
        setIdleTimerDisabled(false)
        clearCapturedTexts()

        let terminalState = await run.cancel()
        recordingRun = nil
        switch terminalState {
        case .cancellation:
            flashCancelled(revertingTo: .ready)
        default:
            applyTerminalStateToUI(terminalState)
        }
    }

    /// Surfaces the optimistic "CANCELLED" flash for ~1s, then returns to the
    /// given steady state. Discard always shows this on the app surface; the
    /// keyboard shows its own optimistic flash (ADR-0003).
    private func flashCancelled(revertingTo target: State) {
        state = .cancelled
        Task {
            try? await Task.sleep(for: .seconds(HoldToDiscardController.cancelledFlashDuration))
            if state == .cancelled {
                state = target
            }
        }
    }

    /// Shared by `stopAndTranscribe` and `discardRecording`: a stop or
    /// Discard landing while `isStartingRecording` is true means no audio
    /// ever flowed. Flips to idle instantly (responsiveness-first); the
    /// in-flight `startRecording` observes `state` is no longer `.arming`
    /// and tears the run down itself.
    ///
    /// Publishes cancellation — never Empty Result, never idle — because that
    /// is what the run will terminate in once the in-flight start tears it
    /// down. Publishing here rather than waiting for that teardown is what
    /// keeps a keyboard stop poll from timing out into a deep-link bounce
    /// while the engine finishes coming up.
    private func abortArming() {
        Logger.recording.info(
            "Publishing cancelled: stop or Discard landed during Arming — no audio was captured"
        )
        state = .idle
        writeState(.cancelled)
        setIdleTimerDisabled(false)
    }

    private func clearCapturedTexts() {
        keyboardChannel.clearCaptures()
        capturedTexts = []
    }

    private func applyTerminalStateToUI(_ terminalState: RecordingRunTerminalState) {
        switch terminalState {
        case .success(let success):
            state = .complete(success.finalText)
        case .emptyResult:
            // Same constant the status row recognises, so the empty-result
            // wording can't drift between the two.
            state = .error(TransientStatus.noSpeechDetectedText)
        case .cancellation:
            state = .ready
        case .processingFailure(let failure):
            state = .error(failure.message)
        }
    }

    private func makeRecordingRun(deliversToKeyboard: Bool) -> RecordingRun {
        RecordingRun(
            audioRecorder: recordingEngine,
            transcriptionProvider: transcriptionProvider,
            streaming: makeStreamingSession(),
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
            currentSubstitutions: { [weak self] in
                self?.substitutionStore.substitutions ?? []
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
        isStartingRecording = false
        aiRetryTask?.cancel()
        aiRetryTask = nil
        hotMicSession.reset()
    }

    // MARK: - Idle Timer

    /// Prevents the screen from auto-locking while recording is active.
    /// Must be re-applied after scene phase transitions (iOS can reset it).
    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
        Logger.app.info("Idle timer \(disabled ? "disabled" : "enabled")")
    }
}
