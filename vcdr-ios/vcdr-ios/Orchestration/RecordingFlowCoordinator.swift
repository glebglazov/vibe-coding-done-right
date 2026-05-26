import Foundation
import FluidAudio
import OSLog
import UIKit

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

    private(set) var state: State = .idle
    private(set) var initProgress: String = "Preparing"
    /// Live transcription text updated in real-time during recording
    private(set) var liveTranscript: String = ""
    /// Shown in the transcribing state — describes what the app is waiting on
    private(set) var transcribingMessage: String = ""
    /// When true, the current recording was started via deep link from keyboard.
    /// Exposed for the view to show/hide the back button.
    private(set) var launchedViaDeepLink = false
    /// When true, the app was foregrounded by the keyboard's stop-deep-link
    /// fallback (`vcdr-ios://stop`). Drives the Done-page "Swipe to paste"
    /// hint, which is only meaningful in that path — every other way of
    /// landing on the Done page leaves the user already where they want
    /// the text to appear, or with no host app to swipe back to.
    private(set) var stoppedViaDeepLink = false
    /// Status of the AI post-processing request
    private(set) var aiProcessingStatus: AIProcessingStatus = .idle
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

    private let audioRecorder: AudioRecorder
    /// Owns the *Hot Mic Session* lifecycle — warm engine, heartbeat, Live
    /// Activity presence, and the inactivity-timeout state machine. This
    /// coordinator drives it via lifecycle notifications (`prewarm`, `start`,
    /// `recordingStarted` / `recordingStopped`, `policyChanged`) and never
    /// touches the engine's warmth directly.
    private let hotMicSession: HotMicSession
    private let transcriptionProvider = ParakeetProvider()
    private let keyboardChannel = KeyboardChannel.live
    /// Populated asynchronously by `bootstrapHistory()` — the scene construction
    /// path can't block on it, because `FileManager.url(forUbiquityContainerIdentifier:)`
    /// can take seconds on first launch after install. `nil` until the
    /// bootstrap task completes; callers must tolerate the transient gap.
    private(set) var history: (any HistoryStore)?
    private var recordingSession: RecordingSession?
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
    /// Text sent to AI processing — needed for retry
    private var aiInputText: String = ""
    /// Text selections captured by the keyboard extension during recording (assistant mode only).
    /// Populated from captures published through the Keyboard Channel.
    private var capturedTexts: [String] = []
    /// Tracks the in-flight AI retry so rapid taps cancel the previous attempt.
    private var aiRetryTask: Task<Void, Never>?
    /// Token for the keyboard command NotificationCenter observer, stored so we can
    /// remove it before re-registering to prevent observer accumulation on scene re-entry.
    private var commandObserverToken: (any NSObjectProtocol)?
    private var settingsObserverToken: (any NSObjectProtocol)?

    init() {
        let recorder = AudioRecorder()
        audioRecorder = recorder
        hotMicSession = HotMicSession(engine: recorder)
    }

    // MARK: - Constants
    private static let initPollInterval: Duration = .milliseconds(200)
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
    /// Idempotent — safe to call on every scene-active. The `.never` /
    /// `.always` / finite policy, the heartbeat, the Live Activity presence,
    /// and the idle-timeout teardown all live inside `HotMicSession`.
    ///
    /// Skipped while the model is still initializing or after an init failure:
    /// during `.initializing` the bootstrap (`hotMicSession.prewarm()`) is the
    /// authoritative path that warms the engine, and heartbeat/presence only
    /// make sense after init completes.
    func startHotSessionIfNeeded() async {
        switch state {
        case .initializing, .error:
            Logger.app.info("startHotSessionIfNeeded: skipping — state is \(String(describing: self.state))")
            return
        default:
            break
        }
        await hotMicSession.start()
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
        guard history == nil else {
            Logger.app.info("[LaunchProbe] bootstrapHistory already-bootstrapped")
            return
        }
        let defaults = SharedConstants.sharedDefaults
        let syncEnabled = HistoryStoreFactory.effectiveSyncEnabled(defaults: defaults)
        Logger.app.info("[LaunchProbe] bootstrapHistory before reconcile detached")
        await Task.detached(priority: .userInitiated) {
            Logger.app.info("[LaunchProbe] bootstrapHistory reconcile detached body main=\(Thread.isMainThread)")
            HistoryMigrator.reconcileAtLaunch(syncEnabled: syncEnabled)
            Logger.app.info("[LaunchProbe] bootstrapHistory reconcile detached body done main=\(Thread.isMainThread)")
        }.value
        Logger.app.info("[LaunchProbe] bootstrapHistory after reconcile main=\(Thread.isMainThread)")
        history = HistoryStoreFactory.make(defaults: defaults)
        Logger.app.info("[LaunchProbe] bootstrapHistory exit main=\(Thread.isMainThread)")
    }

    func initializeModel() async {
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
            // Permission + session + engine pre-warmed concurrently with model
            // init. On fresh-install first launch the iOS audio HAL cold-start
            // (`inputNode.outputFormat` queries) can block 30-40s; serializing
            // prewarm before compile would make that a visible prefix instead
            // of overlapping with the ~15s encoder load. Concurrent execution
            // makes the total wall-clock = max(audioPrep, modelInit), and the
            // AudioRecorder dedups guarantee a record tap landing mid-prewarm
            // joins the in-flight task rather than spawning a duplicate body.
            async let audioPrep: Void = hotMicSession.prewarm()
            Logger.app.info("[LaunchProbe] before transcriptionProvider.initialize await main=\(Thread.isMainThread)")
            try await transcriptionProvider.initialize()
            Logger.app.info("[LaunchProbe] after transcriptionProvider.initialize main=\(Thread.isMainThread)")
            Logger.app.info("[InitTiming] transcriptionProvider.initialize() done at +\(ContinuousClock.now - initStart)")
            await audioPrep
            Logger.app.info("[InitTiming] audio prewarm done at +\(ContinuousClock.now - initStart)")

            pollTask.cancel()
            // Don't overwrite state if recording started while we were initializing
            if state == .initializing {
                state = .ready
            }
            initProgress = "Ready"
            Logger.app.info("[InitTiming] initializeModel complete at +\(ContinuousClock.now - initStart)")

            // Light the hot mic session per the user's timeout policy. The
            // default is `.never` — no warm engine until an actual recording —
            // so this is a no-op until the user opts into a finite or `.always`
            // window. When they do, the engine stays running (foreground and
            // background, under UIBackgroundModes=audio) so every record tap,
            // including keyboard-driven taps over the Darwin command channel,
            // has zero audio startup cost. HotMicSession owns the timeout-policy
            // observer, so a Settings change re-evaluates the timer on its own.
            await startHotSessionIfNeeded()
        } catch {
            pollTask.cancel()
            if state == .initializing {
                state = .error("Model initialization failed: \(error.localizedDescription)")
            }
            Logger.app.error("Model init failed: \(error)")
        }
    }

    /// Sets state to `.recording` synchronously so the view shows "LISTENING"
    /// on the very first frame after a deep link opens the app.
    /// Called from `onOpenURL` before the async recording flow begins.
    func prepareForDeepLinkRecording() {
        guard state != .recording && state != .transcribing else { return }
        state = .recording
        launchedViaDeepLink = true
        stoppedViaDeepLink = false
    }

    /// Called when a deep link arrives. Starts recording immediately (user stays in VCDR app).
    /// Audio capture begins right away; model initialization is awaited in the background.
    func handleRecordDeepLink() async {
        switch state {
        case .recording where audioRecorder.isRecording:
            // Already recording, ignore duplicate deep link
            break
        case .transcribing:
            break
        default:
            await startRecording(fromDeepLink: true)
        }
    }

    /// Called when the keyboard's stop fallback opens `vcdr-ios://stop`. Drives
    /// the same `stopAndTranscribe(sendToKeyboard:)` path the Darwin command
    /// would have, plus flags the run as deep-linked so the Done page shows
    /// the swipe-to-paste hint. The `sendToKeyboard: true` write is what flips
    /// the keyboard's stuck "transcribing" pill to either bundled text (auto-
    /// pasted on next viewWillAppear) or an empty-result flash.
    func handleStopDeepLink() async {
        guard audioRecorder.isRecording else {
            // Cold-launch / orphaned path: nothing was recording, audio
            // buffers are gone. Surface emptyResult so the keyboard's 15s
            // polling doesn't time out staring at "transcribing". Skip when
            // a stop is already mid-flight or just finished — that pipeline
            // will publish its own result.
            switch state {
            case .transcribing, .complete:
                break
            default:
                writeState(.emptyResult)
            }
            return
        }
        launchedViaDeepLink = true
        stoppedViaDeepLink = true
        await stopAndTranscribe(sendToKeyboard: true)
    }

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
        guard !audioRecorder.isRecording, !isStartingRecording, recordingSession == nil else {
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

        // Create streaming manager immediately — no models needed for construction.
        // Its internal AsyncStream buffers audio until start() begins consuming.
        let streaming = StreamingAsrManager(config: .streaming)

        // Begin model init + streaming setup in a detached task to avoid
        // competing with MainActor for scheduling. Audio buffers accumulate
        // in the AsyncStream until start() launches the recognition task,
        // which then drains all queued buffers.
        let setupTask = Task.detached { [transcriptionProvider] in
            try await transcriptionProvider.initialize()
            guard let models = await transcriptionProvider.loadedModels else {
                throw TranscriptionError.providerUnavailable
            }
            try await streaming.start(models: models, source: .microphone)
        }
        let sessionContext = RecordingSessionContext(
            conversationID: UUID(),
            streaming: streaming,
            setupTask: setupTask
        )
        recordingSession = .starting(sessionContext)
        Logger.app.info("[RecordTiming] session setup task created at +\(ContinuousClock.now - recordStart)")

        // Start consuming transcription updates (sets updateContinuation on the actor)
        liveTranscript = ""
        sessionContext.updateTask = startConsumingUpdates(from: streaming)

        // We're about to record: cancel any pending hot-session teardown and
        // light the heartbeat + presence now. The cold path warms the engine
        // via `startCapture` below without ever going through `start()`, so the
        // session needs telling regardless of how it got hot.
        hotMicSession.recordingStarted()

        // Start audio capture — engine was kept hot between recordings so the
        // start cost here is ~0 when the session was already warm.
        let started = await audioRecorder.startCapture { buffer in
            Task { await streaming.streamAudio(buffer) }
        }
        Logger.app.info("[RecordTiming] audioRecorder.startCapture returned at +\(ContinuousClock.now - recordStart)")

        guard case .starting(let activeContext) = recordingSession, activeContext === sessionContext else {
            if started {
                audioRecorder.stopCapture()
            }
            sessionContext.cancel()
            finishRecordingStart(false)
            return
        }

        guard started else {
            sessionContext.cancel()
            recordingSession = nil
            state = .error("Failed to start recording — check microphone permission")
            // The engine never came up, so tear down the heartbeat/presence we
            // optimistically lit above rather than leaving them orphaned.
            hotMicSession.recordingStopped()
            finishRecordingStart(false)
            return
        }

        recordingSession = .recording(sessionContext)
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
        // Stop consuming buffers but keep the engine running so the next
        // recording is instant. The inactivity timer (rescheduled below)
        // tears it down if the user doesn't come back within the window.
        audioRecorder.stopCapture()
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

        let sessionContext: RecordingSessionContext
        switch recordingSession {
        case .recording(let context):
            sessionContext = context
        case .stopping:
            Logger.app.info("[RecordTiming] stopAndTranscribe ignored — already stopping")
            return
        case .starting, .none:
            state = .error("Recording was interrupted before audio started")
            writeState(.idle)
            return
        }
        recordingSession = .stopping(sessionContext)
        sessionContext.updateTask?.cancel()
        let streaming = sessionContext.streaming

        // Wait for model init + streaming start if still in progress.
        // Audio has stopped, so no new buffers arrive — the recognition task
        // will process all queued buffers once it starts.
        let waitStart = ContinuousClock.now
        transcribingMessage = "Loading model — your recording is safe"
        state = .transcribing
        writeState(.transcribing)
        // Tick the message every second so the wait feels bounded rather
        // than frozen. Cancelled below regardless of success/failure.
        let elapsedTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let elapsed = Int((ContinuousClock.now - waitStart).components.seconds)
                self.transcribingMessage = "Loading model · \(elapsed)s — your recording is safe"
            }
        }
        do {
            try await sessionContext.setupTask.value
        } catch {
            elapsedTicker.cancel()
            await streaming.cancel()
            state = .error("Transcription unavailable: \(error.localizedDescription)")
            writeState(.idle)
            recordingSession = nil
            transcribingMessage = ""
            return
        }
        elapsedTicker.cancel()
        transcribingMessage = ""

        // Refresh mode/style from shared defaults — keyboard may have flipped
        // mid-recording. Live-flip semantics: latest user intent wins.
        resyncSettingsFromSharedDefaults()
        let useAI = selectedPromptMode != .verbatim && AIProcessingSettings.hasAICapability

        // Stage 1: Filler removal only — terminator is applied after external processing
        let cleanedLive = TextPostProcessor.removeFillers(from: liveTranscript)

        // Clear auxiliary properties BEFORE changing state so SwiftUI never
        // renders the new view tree with stale values from the recording phase.
        liveTranscript = ""

        // Show local result immediately unless AI processing will replace it.
        // Verbatim (no AI) still gets the static style transform — the pill
        // the user toggled during recording has to affect the output. The
        // finalizer honors the assistant exception, so the transient display
        // now matches the final result for every mode.
        if !useAI && !cleanedLive.isEmpty {
            state = .complete(TranscriptFinalizer.finalize(cleanedLive, mode: selectedPromptMode, style: currentTextStyle))
        } else {
            transcribingMessage = useAI ? "Enhancing with AI..." : ""
            state = .transcribing
        }
        writeState(.transcribing)

        // Request background execution time so the AI HTTP request isn't
        // throttled when the user has switched to the keyboard app.
        let bgTaskID = sendToKeyboard
            ? UIApplication.shared.beginBackgroundTask()
            : .invalid

        // Finalize streaming — may refine the last few words.
        do {
            let rawText = try await streaming.finish()
            // Stage 1: Filler removal only — terminator applied after external processing
            let cleanedText = TextPostProcessor.removeFillers(from: rawText)
            Logger.app.info("Streaming transcription complete: \(cleanedText.prefix(50))...")

            guard !cleanedText.isEmpty else {
                transcribingMessage = ""
                state = .error("No speech detected")
                if sendToKeyboard {
                    writeState(.emptyResult)
                } else {
                    writeState(.idle)
                }
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                }
                recordingSession = nil
                return
            }

            // Stage 2: External processing (AI)
            let processedText: String
            if useAI {
                processedText = await waitForAIProcessing(localText: cleanedText)
            } else {
                processedText = cleanedText
            }
            
            // Stage 3+4: Style transformation + terminator, via the finalizer.
            // Assistant output is delivered as-is (its phrasing is intentional);
            // verbatim/dictation get the static style rules. Re-sync before
            // finalizing — user may have flipped mode/style during AI processing.
            resyncSettingsFromSharedDefaults()
            let resultText = TranscriptFinalizer.finalize(processedText, mode: selectedPromptMode, style: currentTextStyle)

            transcribingMessage = ""
            state = .complete(resultText)

            if sendToKeyboard {
                // Deliver text via state bundling — piggybacking on the stateKey
                // is reliable cross-process whereas dedicated keys have sync delays.
                // Must precede history disk I/O: keyboard polls stateKey on main
                // runloop, any MainActor block here stalls cross-process delivery.
                writeState(.idle, bundledText: resultText)
            } else {
                writeState(.idle)
            }

            recordHistory(
                conversationID: sessionContext.conversationID,
                transcript: cleanedText,
                processed: useAI ? processedText : nil,
                finalText: resultText,
                captures: capturedTexts
            )
        } catch {
            transcribingMessage = ""
            if cleanedLive.isEmpty {
                state = .error("Transcription failed: \(error.localizedDescription)")
            }
            writeState(.idle)
            Logger.app.error("Streaming transcription failed: \(error)")
        }

        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
        }
        recordingSession = nil
    }

    // MARK: - Cross-process settings sync

    /// Re-reads mode/style from shared defaults right before a pipeline
    /// decision. Guards against cross-process staleness: the keyboard may
    /// have flipped mode since the last Darwin `settingsChanged` notif
    /// landed, and `handleSettingsChanged`'s MainActor task may still be
    /// queued. `synchronize()` forces the current process to pull the latest
    /// cross-process writes. Cheap (µs) — safe to call on hot paths.
    private func resyncSettingsFromSharedDefaults() {
        SharedConstants.sharedDefaults.synchronize()
        selectedPromptMode = SessionSettings.effectiveAIMode()
        currentTextStyle = SessionSettings.effectiveTextStyle()
    }

    // MARK: - History

    /// Records the completed conversation to shared history storage.
    /// `processed` is nil when AI was not used; `finalText` is the styled/
    /// terminated text actually delivered to the user.
    private func recordHistory(
        conversationID: UUID,
        transcript: String,
        processed: String?,
        finalText: String,
        captures: [String]
    ) {
        let primarySegment = InputSegment(text: transcript)
        let captureSegments = captures
            .filter { !$0.isEmpty }
            .map { InputSegment(capture: CapturedContext(text: $0, source: .selection)) }
        let segments = [primarySegment] + captureSegments
        let label = historyLabel()
        // `history` is nil only during the brief window between app launch
        // and `bootstrapHistory()` completing — well before the user can
        // finish a recording in practice. Optional-chain so an edge-case race
        // drops the write rather than crashing.
        history?.record(
            conversationID: conversationID,
            inputSegments: segments,
            output: processed != nil ? finalText : nil,
            label: label
        )
    }

    /// Display label for the history entry — mirrors the current AI mode
    /// and text style when the user enabled AI for this recording.
    private func historyLabel() -> String? {
        guard selectedPromptMode != .verbatim else { return nil }
        let mode = selectedPromptMode.rawValue.capitalized
        return selectedPromptMode.appliesStyles
            ? "\(mode) · \(currentTextStyle.rawValue.capitalized)"
            : mode
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
        aiInputText = ""
        capturedTexts = []
        recordingSession?.context.cancel()
        recordingSession = nil
        if isStartingRecording {
            finishRecordingStart(false)
        }
        aiRetryTask?.cancel()
        aiRetryTask = nil
        // Re-arm the inactivity timer so a reset counts as fresh activity
        // rather than leaving a stale teardown scheduled from the prior flow.
        hotMicSession.recordingStopped()
    }

    // MARK: - AI Processing

    /// Runs the AI cascade behind the provider seam. `FallbackProvider` owns
    /// retry + timeout + primary→AFM fallback; this method builds the input,
    /// maps the outcome onto `aiProcessingStatus`, and substitutes local text
    /// on timeout/error.
    private func waitForAIProcessing(localText: String) async -> String {
        // Cross-process staleness guard — pick up any keyboard-side flip that
        // landed between stop-decision and AI dispatch.
        resyncSettingsFromSharedDefaults()

        aiInputText = localText
        aiProcessingStatus = .processing

        let mode = selectedPromptMode
        let systemPrompt = BuiltInPrompts.prompt(for: mode)
        let input = buildAIInput(localText, mode: mode)
        let provider = AIProviderFactory.make(for: mode)

        Logger.ai.info("AI input [mode=\(mode.rawValue), style=\(self.currentTextStyle.rawValue), provider=\(provider.displayName)]: \(input)")
        Logger.ai.debug("AI system prompt: \(systemPrompt.prefix(100))...")

        let startTime = ContinuousClock.now
        do {
            let result = try await provider.process(text: input, systemPrompt: systemPrompt)
            aiProcessingStatus = .completed
            Logger.ai.info("AI output [\(ContinuousClock.now - startTime)]: \(result)")
            return result
        } catch is FallbackProvider.AITimedOut {
            aiProcessingStatus = .timedOut
            Logger.app.warning("AI processing timed out after \(ContinuousClock.now - startTime)")
            return localText
        } catch {
            aiProcessingStatus = .error(error.localizedDescription)
            Logger.app.error("AI processing failed: \(error)")
            return localText
        }
    }

    /// Wraps the local transcript in the `<dictation>` envelope the prompts
    /// expect, appending captured selections as `<capture>` context for
    /// assistant mode (matching the macOS XML format the prompt expects).
    private func buildAIInput(_ localText: String, mode: AIPromptMode) -> String {
        var wrapped = "<dictation>\(localText)</dictation>"
        guard mode == .assistant else { return wrapped }
        for (index, capture) in capturedTexts.enumerated() where !capture.isEmpty {
            wrapped += "\n\n<capture id=\"\(index + 1)\">\(capture)</capture>"
            Logger.ai.info("Capture \(index + 1) included in AI input (\(capture.count) chars)")
        }
        return wrapped
    }

    /// Retries the AI processing request with the previously sent text.
    /// Replays the full chain: primary provider (with retries) + AFM fallback.
    func retryAIProcessing() {
        guard !aiInputText.isEmpty else { return }
        aiRetryTask?.cancel()
        aiRetryTask = Task {
            let aiResult = await waitForAIProcessing(localText: aiInputText)
            guard !Task.isCancelled else { return }
            // Pick up any style/mode change the user made during the retry, then
            // finalize. Assistant output is excluded; everything else (including
            // verbatim if the user flipped AI off mid-retry) gets the style rules.
            resyncSettingsFromSharedDefaults()
            state = .complete(TranscriptFinalizer.finalize(aiResult, mode: selectedPromptMode, style: currentTextStyle))
        }
    }

    func cleanupStaleResults() {
        keyboardChannel.clearCommand()
        writeState(.idle)
    }

    // MARK: - Streaming Updates

    /// Minimum interval between UI updates for live transcript text.
    /// Coalesces rapid bursts (e.g. after model init drains queued audio)
    /// into at most one SwiftUI render per frame, keeping the waveform smooth.
    private static let transcriptUpdateInterval: Duration = .milliseconds(16)

    private func startConsumingUpdates(from streaming: StreamingAsrManager) -> Task<Void, Never> {
        Task {
            let updates = await streaming.transcriptionUpdates
            var lastUpdateTime: ContinuousClock.Instant = .now
            for await _ in updates {
                guard !Task.isCancelled else { break }

                // Throttle: skip intermediate updates that arrive faster than
                // one per display frame. The next update will pick up the
                // latest transcript, so no text is lost — only redundant
                // renders are avoided.
                let now = ContinuousClock.now
                guard now - lastUpdateTime >= Self.transcriptUpdateInterval else { continue }
                lastUpdateTime = now

                let confirmed = await streaming.confirmedTranscript
                let volatile = await streaming.volatileTranscript
                let full = confirmed.isEmpty ? volatile : "\(confirmed) \(volatile)"
                liveTranscript = full.trimmingCharacters(in: .whitespaces)
            }
        }
    }

    // MARK: - Idle Timer

    /// Prevents the screen from auto-locking while recording is active.
    /// Must be re-applied after scene phase transitions (iOS can reset it).
    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
        Logger.app.info("Idle timer \(disabled ? "disabled" : "enabled")")
    }

    // MARK: - State Publishing

    /// Writes recording state to App Group so the keyboard extension can read it.
    /// When `bundledText` is provided, the value is written as `"idle|text"` so the
    /// keyboard can reliably receive the transcription via the same key that syncs state.
    private func writeState(_ recordingState: RecordingState, bundledText: String? = nil) {
        Self.writeStateRaw(recordingState, bundledText: bundledText)
    }

    /// Non-MainActor version so callers can dispatch disk-flush + Darwin post
    /// off the critical path. Shared UserDefaults + DarwinNotificationCenter
    /// are thread-safe. Performs no instance state reads.
    nonisolated func writeStateAsync(_ recordingState: RecordingState, bundledText: String? = nil) async {
        Self.writeStateRaw(recordingState, bundledText: bundledText)
    }

    private nonisolated static func writeStateRaw(_ recordingState: RecordingState, bundledText: String? = nil) {
        let channel = KeyboardChannel.live
        if let bundledText, recordingState == .idle {
            channel.publishBundledResult(bundledText)
            return
        }
        channel.publish(KeyboardChannel.RecordingState(recordingState))
    }

    // MARK: - Keyboard Commands

    /// Listens for commands from the keyboard extension via Darwin notifications.
    /// Safe to call multiple times — removes the previous observer before re-registering.
    func setupCommandListener() {
        // Remove previous observer if present (e.g. on scene re-entry)
        if let token = commandObserverToken {
            NotificationCenter.default.removeObserver(token)
            commandObserverToken = nil
        }

        DarwinNotificationCenter.observe(
            KeyboardChannel.commandNotificationName,
            localName: .darwinCommand
        )
        commandObserverToken = NotificationCenter.default.addObserver(
            forName: .darwinCommand,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.handleCommand()
            }
        }

        // Listen for settings changes from the keyboard extension
        if let token = settingsObserverToken {
            NotificationCenter.default.removeObserver(token)
            settingsObserverToken = nil
        }
        DarwinNotificationCenter.observe(
            SharedConstants.settingsNotificationName,
            localName: .darwinSettingsChanged
        )
        settingsObserverToken = NotificationCenter.default.addObserver(
            forName: .darwinSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleSettingsChanged()
            }
        }
    }

    private func handleSettingsChanged() {
        SharedConstants.sharedDefaults.synchronize()
        selectedPromptMode = SessionSettings.effectiveAIMode()
        currentTextStyle = SessionSettings.effectiveTextStyle()
    }

    /// Re-reads session/default state from shared storage. Called after the
    /// cold-launch boot sequence runs (migration + session clear) so any state
    /// that landed after `@State` initialized the coordinator is picked up.
    func refreshSettingsFromStorage() {
        handleSettingsChanged()
    }

    private func handleCommand() async {
        guard let command = keyboardChannel.readAndClearCommand() else { return }

        switch command {
        case .startRecording:
            Logger.app.info("Received start command from keyboard")
            await startRecording(fromDeepLink: true)
        case .stopRecording:
            Logger.app.info("Received stop command from keyboard")
            await stopAndTranscribe(sendToKeyboard: true)
        }
    }
}

private extension KeyboardChannel.RecordingState {
    init(_ state: RecordingState) {
        switch state {
        case .idle: self = .idle
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .emptyResult: self = .emptyResult
        }
    }
}
