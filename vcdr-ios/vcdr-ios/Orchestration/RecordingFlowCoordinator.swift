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
/// - `RecordingFlowCoordinator+RunControl` — starting and stopping the
///   active Recording Run.
/// - `RecordingFlowCoordinator+Discard` — Discard, and cancelling a run for
///   a caller that is not the user.
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
    /// What the model preparation last published, while a run may cover it:
    /// `.idle`, `.initializing`, `.ready`, or the failure. A run that ends
    /// with nothing to show goes back to it.
    @ObservationIgnored private(set) var readinessState: State = .idle
    private(set) var initProgress: String = ModelPreparationPhase.initialLabel
    /// True while artifacts are already on disk and Transcription Readiness is
    /// still pending. The hero may show READY because Recording Runs can begin
    /// during this window; PREPARING remains reserved for Cold Download.
    private(set) var isModelWarming = false
    /// Live transcription text updated in real-time during recording
    private(set) var liveTranscript: String = ""
    /// Shown in the transcribing state — describes what the app is waiting on
    var transcribingMessage: String = ""
    var isKeyboardRun = false
    /// When true, the app was foregrounded by the keyboard's stop-deep-link
    /// fallback (`vcdr-ios://stop`). Drives the Done-page "Swipe to paste"
    /// hint, which is only meaningful in that path — every other way of
    /// landing on the Done page leaves the user already where they want
    /// the text to appear, or with no host app to swipe back to.
    var stoppedViaDeepLink = false
    /// Status of the AI post-processing request
    var aiProcessingStatus: AIProcessingStatus = .idle
    /// Prompt mode — initialized from the current effective setting.
    /// `.verbatim` is the canonical "AI off" value; mode is the single source of
    /// truth for whether AI runs and which prompt it uses.
    var selectedPromptMode: AIPromptMode = SettingOverrides.effectiveAIMode()
    /// Text style — initialized from the current effective setting.
    var currentTextStyle: TextStyle = SettingOverrides.effectiveTextStyle()

    // MARK: - Setting Overrides

    /// AI Prompt Mode and Text Style are fixed while a run listens. A deep-link
    /// start shows Arming before its run exists, so that state locks them too.
    var areOutputChoicesLocked: Bool {
        guard let phase = activeRunPhase else { return state == .arming }
        return phase.locksOutputChoices
    }

    func toggleAIMode() {
        guard !areOutputChoicesLocked else { return }
        selectedPromptMode = selectedPromptMode.toggled
        SettingOverrides.setAIMode(selectedPromptMode)
    }

    func cycleTextStyle() {
        guard !areOutputChoicesLocked else { return }
        let all = TextStyle.allCases
        let idx = all.firstIndex(of: currentTextStyle) ?? 0
        currentTextStyle = all[(idx + 1) % all.count]
        SettingOverrides.setTextStyle(currentTextStyle)
    }

    let recordingEngine: any RecordingEngine
    let hotMicSession: HotMicSession
    /// Every Transcription Model this device can run, each provider kept once
    /// it has been handed out so switching the Default away and back does not
    /// pay the cold load twice.
    private let providers: TranscriptionProviderRegistry
    /// The Library over this device's Transcription Models, reading the same
    /// providers a recording runs — so a model installed in Settings is the one
    /// the next recording finds already loaded, and a model preparing for a
    /// recording moves the Library's row while Settings is open.
    let transcriptionLibrary: TranscriptionLibrary
    /// Overrides the streaming transport for each Recording Run. Nil in
    /// production, where the run's own model makes the session that suits it;
    /// tests inject a controllable fake to hold a run in Finalizing so
    /// Discard's ignore-during-Finalizing behaviour can be exercised
    /// deterministically.
    private let makeStreamingSession: (() -> any RecordingStreamingSession)?
    /// Reused, prewarmed haptic generator. A freshly constructed generator
    /// connects to the haptic daemon lazily on its first `impactOccurred()`,
    /// and that connect blocks the *main thread* for seconds under the
    /// concurrent CoreML ANE compile — the cold-launch freeze that swallowed
    /// the record tap and starved every other main-actor task. Prewarmed via
    /// `prepare()` once the model is ready (system idle); the record/stop paths
    /// skip it until then.
    let recordHaptic = UIImpactFeedbackGenerator(style: .medium)
    /// Cached transcription-model readiness for synchronous checks on the hot
    /// path (the authoritative phase lives in the provider actor).
    /// Gates the haptic so a cold first-use connect never blocks recording.
    private(set) var isModelReady = false
    let keyboardChannel: any KeyboardChannelProtocol
    /// Populated asynchronously by `bootstrapHistory()` — the scene construction
    /// path can't block on it, because `FileManager.url(forUbiquityContainerIdentifier:)`
    /// can take seconds on first launch after install. `nil` until the
    /// bootstrap task completes; callers must tolerate the transient gap.
    private(set) var history: (any HistoryStore)?
    /// The container both datasets sync through, watched once. Each dataset
    /// keeps its own reconciler — its own toggle, its own Last Sync Time — and
    /// hears only about the Record Files its own folder holds.
    private let containerWatcher = ContainerWatcher()

    /// Owns the iCloud transport for history. Nil while history is still
    /// bootstrapping, and for as long as the sync toggle is off.
    private(set) var historySync: SyncReconciler?
    /// Owns the iCloud transport for Substitutions. Nil while they are still
    /// bootstrapping, and for as long as the sync toggle is off.
    private(set) var substitutionSync: SyncReconciler?
    private var isHistoryBootstrapRunning = false
    /// Stable Substitution store reference handed out at launch. Backed by a
    /// proxy so the Settings screen and the recording pipeline can read it
    /// immediately, while the real (possibly iCloud-backed) store is resolved
    /// off-main in `bootstrapSubstitutions()`. Mirrors the macOS
    /// `AppDependencies.substitutionStore` shell-first pattern.
    let substitutionStore = SubstitutionStoreProxy()
    private var isSubstitutionBootstrapRunning = false
    let historyCompletionAdapter = HistoryRecordingRunCompletionAdapter()
    /// Which run is current. Its phase is the run's own; only
    /// `RecordingFlowCoordinator+RunControl` changes this.
    var activeRun: ActiveRecordingRun?
    let runPresence: any RecordingRunPresence
    let backgroundTasks: any BackgroundTaskRunner
    /// Takes the history writes that can come before `history` is ready: a
    /// Discarded Conversation, and its later processing.
    let historyWrites: HistoryStoreProxy
    let discardedRunFinalizer: any DiscardedRunFinalizer
    let discardNotes = DiscardNoteCenter()
    /// Text sent to AI processing — retained for the existing Done-page retry action.
    var aiInputText: String = ""
    /// Tracks the in-flight AI retry so rapid taps cancel the previous attempt.
    var aiRetryTask: Task<Void, Never>?
    /// Token for the keyboard command NotificationCenter observer, stored so we can
    /// remove it before re-registering to prevent observer accumulation on scene re-entry.
    var commandObserverToken: (any NSObjectProtocol)?
    var settingsObserverToken: (any NSObjectProtocol)?
    @ObservationIgnored private var engineLossTask: Task<Void, Never>?

    init(
        presence: any MicPresence & RecordingRunPresence,
        keyboardChannel: (any KeyboardChannelProtocol)? = nil,
        recordingEngine: (any RecordingEngine)? = nil,
        transcriptionProvider: (any StreamingTranscriptionProvider)? = nil,
        hotMicSession: HotMicSession? = nil,
        backgroundTasks: (any BackgroundTaskRunner)? = nil,
        historyWrites: HistoryStoreProxy? = nil,
        discardedRunFinalizer: (any DiscardedRunFinalizer)? = nil,
        makeStreamingSession: (() -> any RecordingStreamingSession)? = nil
    ) {
        let engine = recordingEngine ?? AudioRecorder()
        let keyboardChannel = keyboardChannel ?? KeyboardChannel.live
        let providers = TranscriptionProviderRegistry()
        if let transcriptionProvider {
            providers.adopt(transcriptionProvider)
        }
        self.recordingEngine = engine
        self.providers = providers
        self.transcriptionLibrary = TranscriptionLibrary(
            models: TranscriptionProviderRegistry.offeredModels,
            provider: { providers.provider(for: $0) }
        )
        self.keyboardChannel = keyboardChannel
        self.hotMicSession = hotMicSession ?? HotMicSession(engine: engine, presence: presence, keyboard: keyboardChannel)
        self.runPresence = presence
        let backgroundTasks = backgroundTasks ?? UIKitBackgroundTaskRunner()
        let historyWrites = historyWrites ?? HistoryStoreProxy()
        self.backgroundTasks = backgroundTasks
        self.historyWrites = historyWrites
        self.discardedRunFinalizer = discardedRunFinalizer
            ?? HistoryDiscardedRunFinalizer(history: historyWrites, backgroundTasks: backgroundTasks)
        self.makeStreamingSession = makeStreamingSession
        let losses = engine.engineLosses()
        engineLossTask = Task { [weak self] in
            for await loss in losses {
                await self?.captureLost(loss)
            }
        }
    }

    deinit {
        engineLossTask?.cancel()
    }

    /// The provider for the Default Transcription Model as it stands right now.
    /// Read per recording rather than held, so a Default changed between two
    /// recordings takes effect on the second without the app being relaunched.
    private var defaultProvider: any StreamingTranscriptionProvider {
        providers.provider(for: TranscriptionSettings.defaultModel)
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
    var isRecording: Bool { recordingEngine.isRecording }
    var isHotSessionActive: Bool { hotMicSession.isAlive }
    var audioLevels: [Float] { recordingEngine.audioLevels }

    // MARK: - Hot Session Lifecycle

    /// Foreground lifecycle hook. A live Hot Mic Session gets its heartbeat and
    /// idle deadline renewed, but cold launch does not start audio preparation.
    func renewHotSessionIfAlive() async {
        await hotMicSession.renewIfAlive()
    }

    /// Scene-activation hook. Mic Presence is for reading VCDR's state from
    /// another app, so it comes down while VCDR itself is on screen — then the
    /// live session gets its heartbeat and idle deadline renewed.
    func handleForegroundActivation() async {
        runPresence.sceneChanged(foreground: true)
        await hotMicSession.renewIfAlive()
    }

    /// Scene-background hook. Requested here rather than once suspended: the
    /// app is still executing at this transition, so the card can go back up.
    func handleBackgroundTransition() {
        runPresence.sceneChanged(foreground: false)
    }

    /// Opens the Local Store off the main actor and installs the `@Observable`
    /// store from its Sendable snapshot (cheap: no I/O on the main actor).
    /// Nothing on this path asks iCloud anything — that is the whole point of
    /// ADR-0010: the launch read is a local database open, and the iCloud
    /// container is linked afterwards as a transport.
    ///
    /// Opening the database is still a blocking file operation, so it runs on
    /// a GCD thread via `withThrowingBlockingTask`, NOT on a `Task.detached`
    /// (cooperative pool): a blocking syscall there pins one of the pool's few
    /// threads for its whole duration and starves other launch work — notably
    /// model init (see ADR-0002 / ADR-0005 / `BlockingWork`).
    func bootstrapHistory() async {
        Logger.app.info("[LaunchProbe] bootstrapHistory entry main=\(Thread.isMainThread)")
        guard history == nil, !isHistoryBootstrapRunning else {
            Logger.app.info("[LaunchProbe] bootstrapHistory already-bootstrapped")
            return
        }
        isHistoryBootstrapRunning = true
        defer { isHistoryBootstrapRunning = false }
        let defaults = SharedConstants.sharedDefaults
        Logger.app.info("[LaunchProbe] bootstrapHistory before database open (GCD)")
        let snapshot: LocalHistoryStore.Snapshot
        do {
            snapshot = try await withThrowingBlockingTask(qos: .userInitiated) {
                try LocalHistoryStore.loadSnapshot()
            }
        } catch {
            Logger.app.error("[LaunchProbe] bootstrapHistory database unavailable: \(error)")
            return
        }
        Logger.app.info("[LaunchProbe] bootstrapHistory after database open main=\(Thread.isMainThread)")
        let history = LocalHistoryStore(snapshot: snapshot)
        self.history = history
        historyCompletionAdapter.setHistory(history)
        historyWrites.setRealStore(history)
        LaunchTelemetry.mark(.historyReadable)
        // The record files are the sync transport, not the read path: the
        // reconciler resolves the iCloud container and merges it in behind a
        // history list that already answers.
        historySync = SyncReconciler.startIfEnabled(
            store: history,
            dataset: HistorySync.dataset,
            defaults: defaults,
            watcher: containerWatcher
        )
        Logger.app.info("[LaunchProbe] bootstrapHistory exit main=\(Thread.isMainThread)")
        Task { await RetiredAssistantHistory.remove(from: history) }
    }

    /// Deferred Substitutions bootstrap, mirroring `bootstrapHistory`: opens the
    /// Local Store off the main actor and installs the real store from its
    /// Sendable snapshot, replaying any edits the user made before it was
    /// ready. The proxy stays the stable reference handed to the UI and the
    /// pipeline throughout.
    ///
    /// Nothing on this path asks iCloud anything — matching a transcript must
    /// never wait on a container (ADR-0010). The reconciler links the record
    /// files behind a list that already answers.
    func bootstrapSubstitutions() async {
        guard !isSubstitutionBootstrapRunning else { return }
        isSubstitutionBootstrapRunning = true
        defer { isSubstitutionBootstrapRunning = false }
        let defaults = SharedConstants.sharedDefaults
        let snapshot: LocalSubstitutionStore.Snapshot
        do {
            snapshot = try await withThrowingBlockingTask(qos: .userInitiated) {
                try LocalSubstitutionStore.loadSnapshot()
            }
        } catch {
            Logger.app.error("Substitution store unavailable: \(error)")
            return
        }
        let store = LocalSubstitutionStore(snapshot: snapshot)
        substitutionStore.setRealStore(store)
        substitutionSync = SyncReconciler.startIfEnabled(
            store: store,
            dataset: SubstitutionSync.dataset,
            defaults: defaults,
            watcher: containerWatcher
        )
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
        if case .capturing? = activeRunPhase { return }

        let initStart = ContinuousClock.now
        Logger.app.info("[InitTiming] initializeModel entered")
        publishReadinessPresentation(for: predictedVerdict)
        // Initial label; pollTask below replaces this on the first iteration
        // with phase-true text once the provider's `initPhase` advances.
        initProgress = ModelPreparationPhase.initialLabel

        let provider = defaultProvider
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
            var lastPhase: ModelPreparationPhase?
            var phaseStart = ContinuousClock.now
            var lastWrittenText = ""
            while !Task.isCancelled {
                let phase = await provider.initPhase
                if phase != lastPhase {
                    Logger.app.info("[LaunchProbe] pollTask phase=\(String(describing: phase)) main=\(Thread.isMainThread)")
                    phaseStart = ContinuousClock.now
                    lastPhase = phase
                    if phase == .ready { return }
                }

                let elapsedSeconds = Int((ContinuousClock.now - phaseStart).components.seconds)
                let text = phase.label(elapsedSeconds: elapsedSeconds)
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
                LaunchTelemetry.mark(.recordPathArmed)
            }
            Logger.app.info("[LaunchProbe] before \(provider.model.rawValue) prepareAtLaunch await main=\(Thread.isMainThread)")
            try await provider.prepareAtLaunch(
                priority: priority,
                predictedVerdict: predictedVerdict
            ) { [weak self] in
                Logger.app.info("[LaunchProbe] before engine prewarm barrier main=\(Thread.isMainThread)")
                await self?.waitForPrewarmBarrier(
                    prewarmTask,
                    predictedVerdict: predictedVerdict,
                    timeout: prewarmBarrierTimeout
                )
            }
            Logger.app.info("[InitTiming] \(provider.model.rawValue) launch preparation done at +\(ContinuousClock.now - initStart)")

            pollTask.cancel()
            readinessState = .ready
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
            if let outcome = await provider.launchLoadOutcome {
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
            readinessState = .error("Model initialization failed: \(error.localizedDescription)")
            if state == .initializing || state == .ready {
                state = readinessState
            }
            Logger.app.error("Model init failed: \(error)")
        }
    }

    private func publishReadinessPresentation(for predictedVerdict: LaunchVerdict) {
        switch predictedVerdict {
        case .coldDownload:
            isModelWarming = false
            readinessState = .initializing
            state = .initializing
        case .coldSpecialize, .warm:
            isModelWarming = true
            readinessState = .ready
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

    func makeRecordingRun(origin: RecordingRunOrigin) -> RecordingRun {
        // The Prompt Mode as it stands now, because the model that transcribes
        // has to be chosen before a word is spoken — a mode flipped mid-recording
        // reaches the processing that follows, not the model already decoding.
        resyncSettingsFromSharedDefaults()
        let transcription = TranscriptionSettings.effectiveTranscription(for: selectedPromptMode)
        return RecordingRun(
            audioRecorder: recordingEngine,
            streaming: makeStreamingSession?() ?? providers.provider(for: transcription.model).makeLiveSession(
                settings: transcription.settings,
                spellingHints: SpellingHints(substitutionStore.substitutions)
            ),
            transcriptProcessor: makeTranscriptProcessor(),
            completionAdapters: completionAdapters(for: origin),
            decodeInFlight: discardedRunFinalizer.decodeInFlight,
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
            },
            onPhaseChange: { [weak self] run, previous in
                self?.recordingRun(run, movedFrom: previous)
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
        selectedPromptMode = SettingOverrides.effectiveAIMode()
        currentTextStyle = SettingOverrides.effectiveTextStyle()
    }

    // MARK: - Idle Timer

    /// Prevents the screen from auto-locking while recording is active.
    /// Must be re-applied after scene phase transitions (iOS can reset it).
    func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
        Logger.app.info("Idle timer \(disabled ? "disabled" : "enabled")")
    }
}
