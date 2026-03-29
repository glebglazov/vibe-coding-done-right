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

    enum CompanionStatus: Equatable {
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
    /// Status of the companion server post-processing request
    private(set) var companionStatus: CompanionStatus = .idle
    /// Per-session override — allows disabling companion without changing global settings.
    /// Initialized from `CompanionSettings.activeInDictation` at session start.
    var companionActiveThisSession: Bool = CompanionSettings.activeInDictation

    private let audioRecorder = AudioRecorder()
    private let transcriptionProvider = ParakeetProvider()

    private var streamingManager: StreamingAsrManager?
    private var updateTask: Task<Void, Never>?
    /// Background task that waits for model initialization and starts the streaming
    /// transcription engine. Audio buffers queue in StreamingAsrManager's AsyncStream
    /// until this task completes and the recognition task begins consuming them.
    private var streamingSetupTask: Task<Void, Error>?
    /// Text sent to companion server — needed for retry
    private var companionInputText: String = ""

    // MARK: - Constants
    private static let initPollInterval: Duration = .milliseconds(200)
    /// Delay before bouncing back to host app — allows audio session to fully activate
    private static let bounceBackDelay: Duration = .milliseconds(300)
    /// Delay after posting transcription result before returning to host app
    private static let returnToHostDelay: Duration = .milliseconds(500)
    /// Time to wait before showing "server unavailable" notice
    private static let companionTimeout: Duration = .seconds(5)

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
        launchedViaDeepLink = fromDeepLink
        companionActiveThisSession = CompanionSettings.activeInDictation
        companionStatus = .idle

        // Show "LISTENING" immediately — before any async work.
        // If audio fails to start, state reverts to .error below.
        state = .recording
        writeState(.recording)

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
    func stopAndTranscribe() async {
        audioRecorder.stopRecording()
        updateTask?.cancel()

        guard let streaming = streamingManager else {
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

        let useCompanion = companionActiveThisSession && CompanionSettings.isConfigured

        // Show local result immediately unless companion will replace it
        let immediateText = TextPostProcessor.process(liveTranscript)
        if !useCompanion && !immediateText.isEmpty {
            state = .complete(immediateText)
        } else {
            state = .transcribing
            transcribingMessage = useCompanion ? "Enhancing with server..." : ""
        }
        writeState(.transcribing)
        liveTranscript = ""

        // Request background execution time for deep-link flow so the companion
        // HTTP request isn't throttled when the user switches to the keyboard app.
        let bgTaskID = launchedViaDeepLink
            ? UIApplication.shared.beginBackgroundTask()
            : .invalid

        // Finalize streaming — may refine the last few words.
        do {
            let rawText = try await streaming.finish()
            let finalText = TextPostProcessor.process(rawText)
            Logger.app.info("Streaming transcription complete: \(finalText.prefix(50))...")

            // Wait up to 5s for companion server, or use local result
            let resultText: String
            if useCompanion {
                resultText = await waitForCompanion(localText: finalText)
            } else {
                resultText = finalText
            }

            state = .complete(resultText)
            writeState(.idle)
            transcribingMessage = ""

            if launchedViaDeepLink {
                SharedConstants.sharedDefaults.set(resultText, forKey: SharedConstants.transcriptionResultKey)
                DarwinNotificationCenter.post(SharedConstants.transcriptionNotificationName)
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
        liveTranscript = ""
        launchedViaDeepLink = false
        companionStatus = .idle
        companionActiveThisSession = CompanionSettings.activeInDictation
        companionInputText = ""
        updateTask?.cancel()
        streamingSetupTask?.cancel()
        streamingSetupTask = nil
        streamingManager = nil
    }

    // MARK: - Companion Processing

    /// Waits up to 5 seconds for the companion server to process text.
    /// Returns server-enhanced text if available within the timeout, otherwise the local text.
    /// Uses detached tasks + AsyncStream to race the server request against the timeout,
    /// ensuring the HTTP request runs off the main actor and returns as soon as it completes.
    private func waitForCompanion(localText: String) async -> String {
        companionInputText = localText
        companionStatus = .processing
        let host = CompanionSettings.host
        let apiKey = CompanionSettings.apiKey
        let timeout = Self.companionTimeout
        let startTime = ContinuousClock.now

        enum RaceResult: Sendable {
            case server(String)
            case serverError(String)
            case timeout
        }

        let (stream, streamContinuation) = AsyncStream.makeStream(of: RaceResult.self)

        // Run HTTP request off the main actor so it isn't serialized
        let serverTask = Task.detached { [streamContinuation] in
            do {
                let text = try await CompanionClient.process(
                    text: localText, host: host, apiKey: apiKey
                )
                streamContinuation.yield(.server(text))
            } catch is CancellationError {
                // Cancelled — timeout won, no need to yield
            } catch {
                streamContinuation.yield(.serverError(error.localizedDescription))
            }
        }

        let timeoutTask = Task.detached { [streamContinuation] in
            do {
                try await Task.sleep(for: timeout)
                streamContinuation.yield(.timeout)
            } catch {
                // Cancelled — server won, no need to yield
            }
        }

        // First result wins
        var raceResult: RaceResult = .timeout
        for await result in stream {
            raceResult = result
            break
        }

        serverTask.cancel()
        timeoutTask.cancel()
        streamContinuation.finish()

        let elapsed = ContinuousClock.now - startTime

        switch raceResult {
        case .server(let text):
            companionStatus = .completed
            state = .complete(text)
            Logger.app.info("Companion processing completed in \(elapsed)")
            return text
        case .serverError(let message):
            companionStatus = .error(message)
            Logger.app.error("Companion processing failed after \(elapsed): \(message)")
            return localText
        case .timeout:
            companionStatus = .timedOut
            Logger.app.warning("Companion server timed out after \(elapsed)")
            return localText
        }
    }

    /// Retries the companion server request with the previously sent text.
    func retryCompanion() {
        guard !companionInputText.isEmpty else { return }
        Task {
            let result = await waitForCompanion(localText: companionInputText)
            state = .complete(result)
        }
    }

    func cleanupStaleResults() {
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.transcriptionResultKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.commandKey)
        SharedConstants.sharedDefaults.set(false, forKey: SharedConstants.audioSessionActiveKey)
        writeState(.idle)
    }

    // MARK: - Streaming Updates

    private func startConsumingUpdates(from streaming: StreamingAsrManager) {
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

    // MARK: - State Publishing

    /// Writes recording state to App Group so the keyboard extension can read it.
    private func writeState(_ recordingState: RecordingState) {
        SharedConstants.sharedDefaults.set(recordingState.rawValue, forKey: SharedConstants.stateKey)
        DarwinNotificationCenter.post(SharedConstants.stateNotificationName)
    }

    // MARK: - Dead Code (kept for potential re-enablement)

    /// Listens for commands from the keyboard extension via Darwin notifications.
    /// Disabled: background recording via keyboard commands is no longer used.
    func setupCommandListener() {
        DarwinNotificationCenter.observe(
            SharedConstants.commandNotificationName,
            localName: .darwinCommand
        )
        NotificationCenter.default.addObserver(
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
            Logger.app.info("Received start command from keyboard (session already active)")
            await startRecording(fromDeepLink: true)
            if case .recording = state {
                // Recording started successfully via keyboard command
            } else {
                SharedConstants.sharedDefaults.set(false, forKey: SharedConstants.audioSessionActiveKey)
                Logger.app.warning("Background recording failed — cleared audio session flag")
            }
        case .stopRecording:
            Logger.app.info("Received stop command from keyboard")
            await stopAndTranscribe()
        }
    }

    /// Returns to the host app using the URL scheme looked up from the bundle ID.
    /// Disabled: user now returns manually via iOS "Back to [App]" link.
    private func returnToHostApp() async {
        guard let hostBundleID = SharedConstants.sharedDefaults.string(
            forKey: SharedConstants.hostBundleIDKey)
        else {
            Logger.app.info("No host bundle ID — user must return manually")
            return
        }

        guard let url = AppURLSchemes.url(forBundleID: hostBundleID) else {
            Logger.app.info("No URL scheme mapping for \(hostBundleID)")
            return
        }

        Logger.app.info("Returning to \(hostBundleID) via \(url.absoluteString)")
        await UIApplication.shared.open(url)
    }

    /// Starts recording and immediately bounces back to the host app.
    /// Disabled: user now stays in VCDR to see real-time transcription.
    private func startRecordingAndBounceBack() async {
        guard await transcriptionProvider.isReady else {
            state = .error("Model not ready")
            return
        }

        launchedViaDeepLink = true
        let started = await audioRecorder.startRecording { _ in }
        if started {
            state = .recording
            writeState(.recording)
            SharedConstants.sharedDefaults.set(true, forKey: SharedConstants.audioSessionActiveKey)
            try? await Task.sleep(for: Self.bounceBackDelay)
            await returnToHostApp()
        } else {
            state = .error("Failed to start recording — check microphone permission")
        }
    }
}
