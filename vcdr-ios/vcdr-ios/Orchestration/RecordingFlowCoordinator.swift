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
    /// Initialized from `AIProcessingSettings.activeInDictation` at session start.
    var aiActiveThisSession: Bool = AIProcessingSettings.activeInDictation
    /// Per-session prompt mode — initialized from settings default, changeable during recording.
    var selectedPromptMode: AIPromptMode = AIProcessingSettings.defaultMode
    /// Per-session text style — initialized from settings default, changeable during recording.
    var currentTextStyle: TextStyle = StyleSettings.defaultStyle

    private let audioRecorder = AudioRecorder()

    private var streamingManager: (any StreamingAsrManager)?
    /// Background task that waits for model loading so the streaming engine is ready
    /// to process audio. Buffers are appended immediately; processing begins once
    /// loadModels() completes.
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
        initProgress = "Loading model..."

        do {
            // Pre-warm audio session concurrently with streaming model loading.
            // Audio prep (~50-200ms) runs off the main thread; model loading
            // downloads + compiles CoreML models on first launch, cached thereafter.
            async let audioPrep: Void = audioRecorder.prepareAudioSession()

            let manager = StreamingModelVariant.parakeetEou160ms.createManager()
            self.streamingManager = manager
            try await manager.loadModels()
            await audioPrep

            // Don't overwrite state if recording started while we were initializing
            if state == .initializing {
                state = .ready
            }
            initProgress = "Ready"
            Logger.app.info("Streaming model initialized")
        } catch {
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
        selectedPromptMode = AIProcessingSettings.defaultMode
        currentTextStyle = StyleSettings.defaultStyle
        aiProcessingStatus = .idle

        // Show "LISTENING" immediately — before any async work.
        // If audio fails to start, state reverts to .error below.
        state = .recording
        writeState(.recording)
        setIdleTimerDisabled(true)

        // Reuse pre-warmed manager from initializeModel(), or create a fresh one.
        let streaming: any StreamingAsrManager
        if let existing = streamingManager {
            streaming = existing
        } else {
            let manager = StreamingModelVariant.parakeetEou160ms.createManager()
            self.streamingManager = manager
            streaming = manager
        }

        // Set up live transcript callback — fires during processBufferedAudio().
        liveTranscript = ""
        await streaming.setPartialTranscriptCallback { [weak self] text in
            Task { @MainActor [weak self] in
                self?.liveTranscript = text.trimmingCharacters(in: .whitespaces)
            }
        }

        // Ensure models are loaded — instant if pre-warmed, otherwise downloads + compiles.
        // Overlaps with audio engine startup below.
        streamingSetupTask = Task {
            try await streaming.loadModels()
        }

        // Start audio engine — buffers forward to the streaming manager.
        // appendAudio queues the buffer; processBufferedAudio runs inference.
        let started = await audioRecorder.startRecording { buffer in
            Task {
                try? await streaming.appendAudio(buffer)
                try? await streaming.processBufferedAudio()
            }
        }

        guard started else {
            self.streamingManager = nil
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
        audioRecorder.stopRecording()
        setIdleTimerDisabled(false)

        guard let streaming = streamingManager else {
            streamingSetupTask?.cancel()
            streamingSetupTask = nil
            state = .error("No streaming session")
            writeState(.idle)
            return
        }

        // Wait for model loading if still in progress.
        // Audio has stopped, so no new buffers arrive — processing will
        // drain all queued buffers once loadModels() completes.
        if let task = streamingSetupTask {
            transcribingMessage = "Loading model — your recording will be processed shortly"
            state = .transcribing
            writeState(.transcribing)
            do {
                try await task.value
            } catch {
                try? await streaming.reset()
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

        // Show local result immediately unless AI processing will replace it
        if !useAI && !cleanedLive.isEmpty {
            state = .complete(TextPostProcessor.applyTerminator(to: cleanedLive))
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
            // Stage 1: Filler removal only — terminator applied after external processing
            let cleanedText = TextPostProcessor.removeFillers(from: rawText)
            Logger.app.info("Streaming transcription complete: \(cleanedText.prefix(50))...")

            guard !cleanedText.isEmpty else {
                state = .error("No speech detected")
                transcribingMessage = ""
                if sendToKeyboard {
                    writeState(.emptyResult)
                } else {
                    writeState(.idle)
                }
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                }
                try? await streaming.reset()
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
            let styledText = StyleTransformer.transform(processedText, using: currentTextStyle.style.staticRules)
            
            // Stage 4: Apply terminator (spacing)
            let resultText = TextPostProcessor.applyTerminator(to: styledText, style: currentTextStyle.style)

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
            if cleanedLive.isEmpty {
                state = .error("Transcription failed: \(error.localizedDescription)")
            }
            writeState(.idle)
            transcribingMessage = ""
            Logger.app.error("Streaming transcription failed: \(error)")
        }

        // Reset manager for next recording (keeps models loaded)
        try? await streaming.reset()

        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
        }
    }

    func reset() {
        state = .ready
        writeState(.idle)
        setIdleTimerDisabled(false)
        liveTranscript = ""
        launchedViaDeepLink = false
        aiProcessingStatus = .idle
        aiActiveThisSession = AIProcessingSettings.activeInDictation
        selectedPromptMode = AIProcessingSettings.defaultMode
        currentTextStyle = StyleSettings.defaultStyle
        aiInputText = ""
        streamingSetupTask?.cancel()
        streamingSetupTask = nil
        if let streaming = streamingManager {
            Task { try? await streaming.reset() }
        }
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
        let wrappedText = "<dictation>\(localText)</dictation>"
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
            Logger.app.info("AI processing completed in \(elapsed)")
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
                Logger.app.info("AFM fallback completed in \(elapsed)")
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
            // Re-apply style transformation and terminator on retry
            let styledText = StyleTransformer.transform(aiResult, using: currentTextStyle.style.staticRules)
            state = .complete(TextPostProcessor.applyTerminator(to: styledText, style: currentTextStyle.style))
        }
    }

    func cleanupStaleResults() {
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.commandKey)
        writeState(.idle)
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
