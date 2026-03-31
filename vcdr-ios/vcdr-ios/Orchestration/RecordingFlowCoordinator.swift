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
    private(set) var initProgress: String = "Preparing..."
    /// Live transcription text updated in real-time during recording
    private(set) var liveTranscript: String = ""
    /// Shown in the transcribing state — describes what the app is waiting on
    private(set) var transcribingMessage: String = ""
    /// When true, the current recording was started via deep link from keyboard.
    /// Exposed for the view to show/hide the back button.
    private(set) var launchedViaDeepLink = false
    /// Status of the AI post-processing request
    private(set) var aiProcessingStatus: AIProcessingStatus = .idle
    /// Per-session override — allows disabling AI processing without changing global settings.
    /// Initialized from `AIProcessingSettings.activeInDictation` at session start.
    var aiActiveThisSession: Bool = AIProcessingSettings.activeInDictation

    private let audioRecorder = AudioRecorder()
    private let transcriptionProvider = ParakeetProvider()

    private var streamingManager: StreamingAsrManager?
    private var updateTask: Task<Void, Never>?
    /// Background task that waits for model initialization and starts the streaming
    /// transcription engine. Audio buffers queue in StreamingAsrManager's AsyncStream
    /// until this task completes and the recognition task begins consuming them.
    private var streamingSetupTask: Task<Void, Error>?
    /// Text sent to AI processing — needed for retry
    private var aiInputText: String = ""
    /// Tracks the in-flight AI retry so rapid taps cancel the previous attempt.
    private var aiRetryTask: Task<Void, Never>?
    /// Token for the keyboard command NotificationCenter observer, stored so we can
    /// remove it before re-registering to prevent observer accumulation on scene re-entry.
    private var commandObserverToken: (any NSObjectProtocol)?

    // MARK: - Constants
    private static let initPollInterval: Duration = .milliseconds(200)
    /// Time to wait before showing "AI unavailable" notice
    private static let aiProcessingTimeout: Duration = .seconds(5)

    var isRecording: Bool { audioRecorder.isRecording }
    var audioLevels: [Float] { audioRecorder.audioLevels }

    func initializeModel() async {
        // If recording already started, model init is handled by streamingSetupTask
        guard state != .recording else { return }

        state = .initializing
        initProgress = "Downloading model..."

        let pollTask = Task {
            while !Task.isCancelled {
                let phase = await transcriptionProvider.initPhase
                switch phase {
                case .notStarted: initProgress = "Preparing..."
                case .downloading: initProgress = "Downloading model..."
                case .compiling: initProgress = "Compiling model..."
                case .ready: return
                }
                try? await Task.sleep(for: Self.initPollInterval)
            }
        }

        do {
            try await transcriptionProvider.initialize()
            pollTask.cancel()
            // Don't overwrite state if recording started while we were initializing
            if state == .initializing {
                state = .ready
            }
            initProgress = "Ready"
            Logger.app.info("Parakeet model initialized")
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
        guard !audioRecorder.isRecording else { return }

        launchedViaDeepLink = fromDeepLink
        aiActiveThisSession = AIProcessingSettings.activeInDictation
        aiProcessingStatus = .idle

        // Show "LISTENING" immediately — before any async work.
        // If audio fails to start, state reverts to .error below.
        state = .recording
        writeState(.recording)
        setIdleTimerDisabled(true)

        // Create streaming manager immediately — no models needed for construction.
        // Its internal AsyncStream buffers audio until start() begins consuming.
        let streaming = StreamingAsrManager(config: .streaming)
        self.streamingManager = streaming

        // Start consuming transcription updates (sets updateContinuation on the actor)
        liveTranscript = ""
        startConsumingUpdates(from: streaming)

        // Start audio engine immediately — buffers forward to the streaming manager
        let started = await audioRecorder.startRecording { buffer in
            Task { await streaming.streamAudio(buffer) }
        }

        guard started else {
            self.streamingManager = nil
            updateTask?.cancel()
            state = .error("Failed to start recording — check microphone permission")
            return
        }

        // Initialize model and start streaming transcription in the background.
        // Audio buffers accumulate in the AsyncStream until start() launches
        // the recognition task, which then drains all queued buffers.
        streamingSetupTask = Task { @MainActor in
            try await self.transcriptionProvider.initialize()
            guard let models = await self.transcriptionProvider.loadedModels else {
                throw TranscriptionError.providerUnavailable
            }
            try await streaming.start(models: models, source: .microphone)
        }
    }

    /// Stops recording and shows the result immediately from the live transcript.
    /// Finalizes streaming in the background and updates the result if it differs.
    /// - Parameter sendToKeyboard: When true, the transcription result is delivered to the keyboard extension via state bundling.
    func stopAndTranscribe(sendToKeyboard: Bool = false) async {
        audioRecorder.stopRecording()
        setIdleTimerDisabled(false)
        updateTask?.cancel()

        guard let streaming = streamingManager else {
            streamingSetupTask?.cancel()
            streamingSetupTask = nil
            state = .error("No streaming session")
            writeState(.idle)
            return
        }

        // Wait for model init + streaming start if still in progress.
        // Audio has stopped, so no new buffers arrive — the recognition task
        // will process all queued buffers once it starts.
        if let task = streamingSetupTask {
            transcribingMessage = "Compiling model — your recording will be processed shortly"
            state = .transcribing
            writeState(.transcribing)
            do {
                try await task.value
            } catch {
                await streaming.cancel()
                state = .error("Transcription unavailable: \(error.localizedDescription)")
                writeState(.idle)
                streamingManager = nil
                streamingSetupTask = nil
                transcribingMessage = ""
                return
            }
            streamingSetupTask = nil
            transcribingMessage = ""
        }

        let useAI = aiActiveThisSession && AIProcessingSettings.isConfigured

        // Show local result immediately unless AI processing will replace it
        let immediateText = TextPostProcessor.process(liveTranscript)
        if !useAI && !immediateText.isEmpty {
            state = .complete(immediateText)
        } else {
            state = .transcribing
            transcribingMessage = useAI ? "Enhancing with AI..." : ""
        }
        writeState(.transcribing)
        liveTranscript = ""

        // Request background execution time so the AI HTTP request isn't
        // throttled when the user has switched to the keyboard app.
        let bgTaskID = sendToKeyboard
            ? UIApplication.shared.beginBackgroundTask()
            : .invalid

        // Finalize streaming — may refine the last few words.
        do {
            let rawText = try await streaming.finish()
            let finalText = TextPostProcessor.process(rawText)
            Logger.app.info("Streaming transcription complete: \(finalText.prefix(50))...")

            // Wait for AI processing, or use local result
            let resultText: String
            if useAI {
                resultText = await waitForAIProcessing(localText: finalText)
            } else {
                resultText = finalText
            }

            state = .complete(resultText)
            transcribingMessage = ""

            if sendToKeyboard {
                // Deliver text via state bundling — piggybacking on the stateKey
                // is reliable cross-process whereas dedicated keys have sync delays.
                writeState(.idle, bundledText: resultText)
            } else {
                writeState(.idle)
            }
        } catch {
            if immediateText.isEmpty {
                state = .error("Transcription failed: \(error.localizedDescription)")
            }
            writeState(.idle)
            transcribingMessage = ""
            Logger.app.error("Streaming transcription failed: \(error)")
        }

        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
        }
        streamingManager = nil
    }

    func reset() {
        state = .ready
        writeState(.idle)
        setIdleTimerDisabled(false)
        liveTranscript = ""
        launchedViaDeepLink = false
        aiProcessingStatus = .idle
        aiActiveThisSession = AIProcessingSettings.activeInDictation
        aiInputText = ""
        updateTask?.cancel()
        streamingSetupTask?.cancel()
        streamingSetupTask = nil
        streamingManager = nil
        aiRetryTask?.cancel()
        aiRetryTask = nil
    }

    // MARK: - AI Processing

    /// Races the AI API request against a timeout.
    /// Returns AI-enhanced text if available within the timeout, otherwise the local text.
    private func waitForAIProcessing(localText: String) async -> String {
        aiInputText = localText
        aiProcessingStatus = .processing
        let provider = AIProcessingSettings.provider
        let apiKey = AIProcessingSettings.activeApiKey
        let systemPrompt = BuiltInPrompts.dictation
        let timeout = Self.aiProcessingTimeout
        let startTime = ContinuousClock.now

        enum RaceResult: Sendable {
            case ai(String)
            case aiError(String)
            case timeout
        }

        let (stream, streamContinuation) = AsyncStream.makeStream(of: RaceResult.self)

        let wrappedText = "<dictation>\(localText)</dictation>"

        // Run HTTP request off the main actor so it isn't serialized
        let aiTask = Task.detached { [streamContinuation] in
            do {
                let text = try await AIClient.process(
                    text: wrappedText, systemPrompt: systemPrompt,
                    provider: provider, apiKey: apiKey
                )
                streamContinuation.yield(.ai(text))
            } catch is CancellationError {
                // Cancelled — timeout won, no need to yield
            } catch {
                streamContinuation.yield(.aiError(error.localizedDescription))
            }
        }

        let timeoutTask = Task.detached { [streamContinuation] in
            do {
                try await Task.sleep(for: timeout)
                streamContinuation.yield(.timeout)
            } catch {
                // Cancelled — AI won, no need to yield
            }
        }

        // First result wins
        var raceResult: RaceResult = .timeout
        for await result in stream {
            raceResult = result
            break
        }

        aiTask.cancel()
        timeoutTask.cancel()
        streamContinuation.finish()

        let elapsed = ContinuousClock.now - startTime

        switch raceResult {
        case .ai(let text):
            aiProcessingStatus = .completed
            state = .complete(text)
            Logger.app.info("AI processing completed in \(elapsed)")
            return text
        case .aiError(let message):
            aiProcessingStatus = .error(message)
            Logger.app.error("AI processing failed after \(elapsed): \(message)")
            return localText
        case .timeout:
            aiProcessingStatus = .timedOut
            Logger.app.warning("AI processing timed out after \(elapsed)")
            return localText
        }
    }

    /// Retries the AI processing request with the previously sent text.
    /// Cancels any in-flight retry before starting a new one.
    func retryAIProcessing() {
        guard !aiInputText.isEmpty else { return }
        aiRetryTask?.cancel()
        aiRetryTask = Task {
            let result = await waitForAIProcessing(localText: aiInputText)
            guard !Task.isCancelled else { return }
            state = .complete(result)
        }
    }

    func cleanupStaleResults() {
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.commandKey)
        writeState(.idle)
    }

    // MARK: - Streaming Updates

    private func startConsumingUpdates(from streaming: StreamingAsrManager) {
        updateTask?.cancel()
        updateTask = Task {
            let updates = await streaming.transcriptionUpdates
            for await _ in updates {
                guard !Task.isCancelled else { break }
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
        let value: String
        if let bundledText, recordingState == .idle {
            value = "\(RecordingState.idle.rawValue)|\(bundledText)"
        } else {
            value = recordingState.rawValue
        }
        SharedConstants.sharedDefaults.set(value, forKey: SharedConstants.stateKey)
        DarwinNotificationCenter.post(SharedConstants.stateNotificationName)
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
            SharedConstants.commandNotificationName,
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
    }

    private func handleCommand() async {
        guard let rawCommand = SharedConstants.sharedDefaults.string(
            forKey: SharedConstants.commandKey),
              let command = RecordingCommand(rawValue: rawCommand)
        else { return }

        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.commandKey)

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
