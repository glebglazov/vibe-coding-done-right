import Foundation
import FluidAudio
import FoundationModels
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
    /// Initialized from shared defaults (keyboard may have changed them).
    var aiActiveThisSession: Bool = SharedConstants.sharedDefaults.bool(forKey: SharedConstants.aiActiveKey)
    /// Per-session prompt mode — initialized from shared defaults, changeable during recording.
    var selectedPromptMode: AIPromptMode = AIPromptMode(
        rawValue: SharedConstants.sharedDefaults.string(forKey: SharedConstants.aiModeKey) ?? ""
    ) ?? .dictation
    /// Per-session text style — initialized from shared defaults, changeable during recording.
    var currentTextStyle: TextStyle = TextStyle(
        rawValue: SharedConstants.sharedDefaults.string(forKey: SharedConstants.textStyleKey) ?? ""
    ) ?? .casual

    // MARK: - In-Session Settings (sync back to keyboard)

    func toggleAIActive() {
        aiActiveThisSession.toggle()
        syncSettingsToKeyboard()
    }

    func cyclePromptMode() {
        selectedPromptMode = selectedPromptMode.next
        syncSettingsToKeyboard()
    }

    func cycleTextStyle() {
        currentTextStyle = currentTextStyle == .casual ? .formal : .casual
        syncSettingsToKeyboard()
    }

    private func syncSettingsToKeyboard() {
        let sd = SharedConstants.sharedDefaults
        sd.set(aiActiveThisSession, forKey: SharedConstants.aiActiveKey)
        sd.set(selectedPromptMode.rawValue, forKey: SharedConstants.aiModeKey)
        sd.set(currentTextStyle.rawValue, forKey: SharedConstants.textStyleKey)
        sd.synchronize()
        DarwinNotificationCenter.post(SharedConstants.settingsNotificationName)
    }

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
    /// Text selections captured by the keyboard extension during recording (assistant mode only).
    /// Populated from the JSON array in SharedConstants.capturedTextsKey.
    private var capturedTexts: [String] = []
    /// Tracks the in-flight AI retry so rapid taps cancel the previous attempt.
    private var aiRetryTask: Task<Void, Never>?
    /// Token for the keyboard command NotificationCenter observer, stored so we can
    /// remove it before re-registering to prevent observer accumulation on scene re-entry.
    private var commandObserverToken: (any NSObjectProtocol)?
    private var settingsObserverToken: (any NSObjectProtocol)?

    // MARK: - Constants
    private static let initPollInterval: Duration = .milliseconds(200)
    /// Time budget for the primary AI provider (including retries)
    private static let aiProcessingTimeout: Duration = .seconds(5)
    /// Maximum retry attempts for cloud providers within the timeout budget
    private static let maxRetries = 3

    var isRecording: Bool { audioRecorder.isRecording }
    var audioLevels: [Float] { audioRecorder.audioLevels }

    /// Deactivates the audio session when the app goes to background.
    func deactivateAudioSession() {
        audioRecorder.deactivateSession()
    }

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
            // Pre-warm audio session concurrently with model initialization.
            // Audio prep (~50-200ms) runs off the main thread; model init runs
            // on the ParakeetProvider actor. Both proceed in parallel.
            async let audioPrep: Void = audioRecorder.prepareAudioSession()
            try await transcriptionProvider.initialize()
            await audioPrep

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
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        launchedViaDeepLink = fromDeepLink
        let sd = SharedConstants.sharedDefaults
        aiActiveThisSession = sd.bool(forKey: SharedConstants.aiActiveKey)
        selectedPromptMode = AIPromptMode(
            rawValue: sd.string(forKey: SharedConstants.aiModeKey) ?? ""
        ) ?? .dictation
        currentTextStyle = TextStyle(
            rawValue: sd.string(forKey: SharedConstants.textStyleKey) ?? ""
        ) ?? .casual
        // Read initial captures written by the keyboard extension.
        // The keyboard stores a JSON array; additional captures are appended during recording.
        capturedTexts = []
        if let data = sd.data(forKey: SharedConstants.capturedTextsKey),
           let texts = try? JSONDecoder().decode([String].self, from: data) {
            capturedTexts = texts
            Logger.ai.info("Initial captures on start: \(texts.count) item(s)")
        }
        sd.removeObject(forKey: SharedConstants.selectedTextKey)
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

        // Begin model init + streaming setup NOW — overlaps with audio engine startup.
        // Audio buffers accumulate in the AsyncStream until start() launches
        // the recognition task, which then drains all queued buffers.
        streamingSetupTask = Task { @MainActor in
            try await self.transcriptionProvider.initialize()
            guard let models = await self.transcriptionProvider.loadedModels else {
                throw TranscriptionError.providerUnavailable
            }
            try await streaming.start(models: models, source: .microphone)
        }

        // Start audio engine — buffers forward to the streaming manager
        let started = await audioRecorder.startRecording { buffer in
            Task { await streaming.streamAudio(buffer) }
        }

        guard started else {
            self.streamingManager = nil
            updateTask?.cancel()
            streamingSetupTask?.cancel()
            streamingSetupTask = nil
            state = .error("Failed to start recording — check microphone permission")
            return
        }
    }

    /// Stops recording and shows the result immediately from the live transcript.
    /// Finalizes streaming in the background and updates the result if it differs.
    /// - Parameter sendToKeyboard: When true, the transcription result is delivered to the keyboard extension via state bundling.
    func stopAndTranscribe(sendToKeyboard: Bool = false) async {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        audioRecorder.stopRecording()
        setIdleTimerDisabled(false)
        updateTask?.cancel()

        // Re-read the captures array — the keyboard may have added more during recording.
        if sendToKeyboard {
            let sd = SharedConstants.sharedDefaults
            sd.synchronize()
            if let data = sd.data(forKey: SharedConstants.capturedTextsKey),
               let texts = try? JSONDecoder().decode([String].self, from: data),
               !texts.isEmpty {
                capturedTexts = texts
                Logger.ai.info("Final captures on stop: \(texts.count) item(s)")
            }
            sd.removeObject(forKey: SharedConstants.capturedTextsKey)
        }

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

        // Stage 1: Filler removal only — terminator is applied after external processing
        let cleanedLive = TextPostProcessor.removeFillers(from: liveTranscript)

        // Clear auxiliary properties BEFORE changing state so SwiftUI never
        // renders the new view tree with stale values from the recording phase.
        liveTranscript = ""

        // Show local result immediately unless AI processing will replace it
        if !useAI && !cleanedLive.isEmpty {
            state = .complete(TextPostProcessor.applyTerminator(to: cleanedLive))
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
                streamingManager = nil
                return
            }

            // Stage 2: External processing (AI)
            let processedText: String
            if useAI {
                processedText = await waitForAIProcessing(localText: cleanedText)
            } else {
                processedText = cleanedText
            }
            
            // Stage 3: Apply style transformation (capitalization, punctuation)
            // Stage 4: Apply terminator (spacing)
            // Skip style transformations for modes that don't apply styles (e.g., assistant)
            let resultText: String
            if selectedPromptMode.appliesStyles {
                let styledText = StyleTransformer.transform(processedText, using: currentTextStyle.style.staticRules)
                resultText = TextPostProcessor.applyTerminator(to: styledText, style: currentTextStyle.style)
            } else {
                resultText = TextPostProcessor.applyTerminator(to: processedText)
            }

            transcribingMessage = ""
            state = .complete(resultText)

            if sendToKeyboard {
                // Deliver text via state bundling — piggybacking on the stateKey
                // is reliable cross-process whereas dedicated keys have sync delays.
                writeState(.idle, bundledText: resultText)
            } else {
                writeState(.idle)
            }
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
        streamingManager = nil
    }

    func reset() {
        state = .ready
        writeState(.idle)
        setIdleTimerDisabled(false)
        liveTranscript = ""
        launchedViaDeepLink = false
        aiProcessingStatus = .idle
        let sd = SharedConstants.sharedDefaults
        aiActiveThisSession = sd.bool(forKey: SharedConstants.aiActiveKey)
        selectedPromptMode = AIPromptMode(
            rawValue: sd.string(forKey: SharedConstants.aiModeKey) ?? ""
        ) ?? .dictation
        currentTextStyle = TextStyle(
            rawValue: sd.string(forKey: SharedConstants.textStyleKey) ?? ""
        ) ?? .casual
        aiInputText = ""
        capturedTexts = []
        updateTask?.cancel()
        streamingSetupTask?.cancel()
        streamingSetupTask = nil
        streamingManager = nil
        aiRetryTask?.cancel()
        aiRetryTask = nil
    }

    // MARK: - AI Processing

    /// Runs the full AI processing chain: primary provider (with retries) → AFM fallback → local text.
    private func waitForAIProcessing(localText: String) async -> String {
        aiInputText = localText
        aiProcessingStatus = .processing
        let provider = AIProcessingSettings.provider
        let apiKey = AIProcessingSettings.activeApiKey
        let systemPrompt = BuiltInPrompts.prompt(for: selectedPromptMode)
        var wrappedText = "<dictation>\(localText)</dictation>"
        // Append captured selections as <capture> context for assistant mode,
        // matching the macOS XML format the assistant prompt already expects.
        if selectedPromptMode == .assistant {
            for (index, capture) in capturedTexts.enumerated() where !capture.isEmpty {
                wrappedText += "\n\n<capture id=\"\(index + 1)\">\(capture)</capture>"
                Logger.ai.info("Capture \(index + 1) included in AI input (\(capture.count) chars)")
            }
        }

        Logger.ai.info("AI input [mode=\(self.selectedPromptMode.rawValue), style=\(self.currentTextStyle.rawValue), provider=\(provider.displayName)]: \(wrappedText)")
        Logger.ai.debug("AI system prompt: \(systemPrompt.prefix(100))...")

        let deadline = ContinuousClock.now + Self.aiProcessingTimeout
        let startTime = ContinuousClock.now

        // --- Primary provider ---
        let primaryResult = await runPrimaryProvider(
            provider: provider, apiKey: apiKey,
            text: wrappedText, systemPrompt: systemPrompt,
            deadline: deadline
        )

        if let result = primaryResult {
            let elapsed = ContinuousClock.now - startTime
            aiProcessingStatus = .completed
            Logger.ai.info("AI output [\(elapsed)]: \(result)")
            return result
        }

        // --- AFM fallback (only when a cloud provider was primary) ---
        if AIProcessingSettings.afmFallbackEnabled, provider != .apple {
            let fallbackResult = await runAFMFallback(
                text: wrappedText, systemPrompt: systemPrompt
            )
            if let result = fallbackResult {
                let elapsed = ContinuousClock.now - startTime
                aiProcessingStatus = .completed
                Logger.ai.info("AFM fallback output [\(elapsed)]: \(result)")
                return result
            }
        }

        // --- Local text fallback ---
        let elapsed = ContinuousClock.now - startTime
        if aiProcessingStatus == .processing {
            aiProcessingStatus = .timedOut
            Logger.app.warning("AI processing timed out after \(elapsed)")
        }
        return localText
    }

    /// Attempts the primary provider up to `maxRetries` times within the deadline.
    /// Cloud providers retry on error; Apple gets a single attempt.
    /// Returns the AI text on success, or nil on failure/timeout.
    private func runPrimaryProvider(
        provider: AIProvider,
        apiKey: String,
        text: String,
        systemPrompt: String,
        deadline: ContinuousClock.Instant
    ) async -> String? {
        let maxAttempts = provider.requiresAPIKey ? Self.maxRetries : 1

        for attempt in 1...maxAttempts {
            guard ContinuousClock.now < deadline else {
                Logger.app.warning("AI timeout budget exhausted after \(attempt - 1) attempt(s)")
                return nil
            }

            let remaining = deadline - ContinuousClock.now

            do {
                return try await withThrowingTaskGroup(of: String?.self) { group in
                    group.addTask {
                        try await AIClient.process(
                            text: text, systemPrompt: systemPrompt,
                            provider: provider, apiKey: apiKey
                        )
                    }
                    group.addTask {
                        try await Task.sleep(for: remaining)
                        return nil // timeout sentinel
                    }

                    for try await result in group {
                        group.cancelAll()
                        return result
                    }
                    return nil
                }
            } catch is CancellationError {
                return nil
            } catch {
                Logger.app.error("AI attempt \(attempt)/\(maxAttempts) failed: \(error)")
                if attempt == maxAttempts {
                    aiProcessingStatus = .error(error.localizedDescription)
                }
            }
        }
        return nil
    }

    /// Tries Apple Foundation Models once as a fallback. Returns result text or nil.
    /// On `unsupportedLanguageOrLocale`, returns nil silently (local text will be used).
    private func runAFMFallback(text: String, systemPrompt: String) async -> String? {
        guard AIProcessingSettings.isAFMAvailable else { return nil }

        do {
            return try await AFMClient.process(text: text, systemPrompt: systemPrompt)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .unsupportedLanguageOrLocale:
                Logger.app.info("AFM fallback: unsupported language, using local text")
            default:
                Logger.app.error("AFM fallback generation error: \(error)")
            }
            return nil
        } catch {
            Logger.app.error("AFM fallback failed: \(error)")
            return nil
        }
    }

    /// Retries the AI processing request with the previously sent text.
    /// Replays the full chain: primary provider (with retries) + AFM fallback.
    func retryAIProcessing() {
        guard !aiInputText.isEmpty else { return }
        aiRetryTask?.cancel()
        aiRetryTask = Task {
            let aiResult = await waitForAIProcessing(localText: aiInputText)
            guard !Task.isCancelled else { return }
            // Re-apply style transformation and terminator on retry (only for modes that apply styles)
            if selectedPromptMode.appliesStyles {
                let styledText = StyleTransformer.transform(aiResult, using: currentTextStyle.style.staticRules)
                state = .complete(TextPostProcessor.applyTerminator(to: styledText, style: currentTextStyle.style))
            } else {
                state = .complete(TextPostProcessor.applyTerminator(to: aiResult))
            }
        }
    }

    func cleanupStaleResults() {
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.commandKey)
        writeState(.idle)
    }

    // MARK: - Streaming Updates

    /// Minimum interval between UI updates for live transcript text.
    /// Coalesces rapid bursts (e.g. after model init drains queued audio)
    /// into at most one SwiftUI render per frame, keeping the waveform smooth.
    private static let transcriptUpdateInterval: Duration = .milliseconds(16)

    private func startConsumingUpdates(from streaming: StreamingAsrManager) {
        updateTask?.cancel()
        updateTask = Task {
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
        let value: String
        if let bundledText, recordingState == .idle {
            value = "\(RecordingState.idle.rawValue)|\(bundledText)"
        } else {
            value = recordingState.rawValue
        }
        let sd = SharedConstants.sharedDefaults
        sd.set(value, forKey: SharedConstants.stateKey)
        sd.synchronize()
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
        let sd = SharedConstants.sharedDefaults
        sd.synchronize()
        aiActiveThisSession = sd.bool(forKey: SharedConstants.aiActiveKey)
        selectedPromptMode = AIPromptMode(
            rawValue: sd.string(forKey: SharedConstants.aiModeKey) ?? ""
        ) ?? .dictation
        currentTextStyle = TextStyle(
            rawValue: sd.string(forKey: SharedConstants.textStyleKey) ?? ""
        ) ?? .casual
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
