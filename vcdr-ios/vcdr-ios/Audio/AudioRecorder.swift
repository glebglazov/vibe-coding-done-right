import Foundation
import AVFoundation
import OSLog

@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    /// True while the engine is running and the tap is installed — ready to
    /// accept a `bufferHandler` and flip `isRecording` without another
    /// `engine.start()` round-trip. Stays true between recordings inside a
    /// hot session and is torn down by `endHotSession()` on inactivity.
    private(set) var isHot = false
    /// Rolling buffer of recent audio level samples (0.0–1.0), one per meter tick.
    private(set) var audioLevels: [Float] = Array(repeating: 0, count: levelSampleCount)

    private var audioEngine: AVAudioEngine?
    private var audioSessionConfigured = false
    /// nonisolated(unsafe) because the audio tap callback reads this from the audio thread.
    /// Safe: only set before starting the engine, cleared after stopping it.
    @ObservationIgnored
    private nonisolated(unsafe) var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Notification observer tokens for audio session interruption and route change.
    @ObservationIgnored
    private var interruptionObservers: [Any] = []

    // MARK: - Audio Input

    /// UserDefaults key for the preferred audio input port UID
    static let preferredInputUIDKey = "preferredAudioInputUID"

    /// Returns the list of available audio input ports on the current device.
    /// Requires an active audio session — returns an empty array if unavailable.
    var availableInputs: [AVAudioSessionPortDescription] {
        AVAudioSession.sharedInstance().availableInputs ?? []
    }

    /// Returns the user's saved preferred input port if it's currently available,
    /// or nil to mean "let iOS pick the default" (which is the built-in mic now
    /// that the session category no longer permits Bluetooth HFP).
    private nonisolated static func preferredInputPort(session: AVAudioSession) -> AVAudioSessionPortDescription? {
        let savedUID = UserDefaults.standard.string(forKey: preferredInputUIDKey) ?? ""
        guard !savedUID.isEmpty else { return nil }
        return session.availableInputs?.first(where: { $0.uid == savedUID })
    }

    /// Applies the user's preferred audio input to an already-active session.
    /// Used after route changes (e.g. a wired headset is plugged in mid-recording).
    /// For the initial session setup the preferred input is set before `setActive`
    /// inside ``prepareAudioSession`` — iOS treats post-activation calls as a
    /// hint it may ignore.
    private func applyPreferredInput() {
        let session = AVAudioSession.sharedInstance()
        guard let match = Self.preferredInputPort(session: session) else { return }
        do {
            try session.setPreferredInput(match)
            Logger.recording.info("Set preferred input to \(match.portName)")
        } catch {
            Logger.recording.warning("Failed to set preferred input: \(error)")
        }
    }

    // MARK: - Constants

    /// Number of audio level samples kept for the waveform display
    static let levelSampleCount = 20
    /// How fast the displayed level drops when audio quiets down (0 = instant, 1 = no decay)
    private nonisolated static let levelDecayFactor: Float = 0.3
    /// Buffer size for the audio engine tap — 4096 frames at hardware sample rate
    /// gives ~85ms per buffer at 48kHz, a good balance between latency and overhead
    private static let tapBufferSize: AVAudioFrameCount = 4096
    /// Floor value to avoid log10(0) when computing level from silent audio
    private nonisolated static let silenceFloor: Float = 1e-7
    /// dB range mapped to 0.0–1.0 linear scale (matches AVAudioRecorder.averagePower range)
    private nonisolated static let dbRange: Float = 60

    func requestMicrophonePermission() async -> Bool {
        // Fast path: skip the async hop when permission is already granted
        if AVAudioApplication.shared.recordPermission == .granted {
            return true
        }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Pre-configures the AVAudioSession so it's ready when recording starts.
    /// Safe to call multiple times — skipped if already configured.
    /// Blocking AVAudioSession calls run off the main thread to avoid stalling the UI.
    ///
    /// We deliberately do NOT pass `.allowBluetoothHFP`: HFP audio is 16 kHz
    /// narrowband, which tanks Parakeet's accuracy. Without the option AirPods
    /// simply don't appear as an input route, so iOS can't silently override
    /// our preferred input to them in `.playAndRecord` mode — which it does
    /// even when `setPreferredInput` points at the built-in mic, because the
    /// HFP link is bidirectional and iOS routes input along with output.
    func prepareAudioSession() async {
        guard !audioSessionConfigured else { return }
        // AVAudioSession configuration is thread-safe — run off main thread
        // to avoid blocking UI during setCategory/setActive (~50-200ms).
        let success = await Task.detached {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                // Set the preferred input BEFORE setActive so iOS honours it
                // while picking the initial route. A post-activation call is
                // just a hint iOS may ignore.
                if let preferred = Self.preferredInputPort(session: session) {
                    try? session.setPreferredInput(preferred)
                }
                try session.setActive(true)
                return true
            } catch {
                Logger.recording.warning("Failed to pre-configure audio session: \(error)")
                return false
            }
        }.value

        guard success else { return }
        audioSessionConfigured = true
        setupInterruptionObservers()
        Logger.recording.info("Audio session pre-configured")
    }

    /// Pre-allocates audio engine resources so that `startRecording` is fast.
    /// Call after `prepareAudioSession()` completes. The engine is created and
    /// prepared (resources allocated) but NOT started — no microphone indicator
    /// appears until `startRecording` is called.
    func prepareEngine() {
        guard audioSessionConfigured, audioEngine == nil else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) {
            [weak self] buffer, _ in
            guard let self else { return }

            let level = Self.computeLevel(from: buffer)
            Task { @MainActor [weak self] in
                self?.appendLevel(level)
            }

            self.bufferHandler?(buffer)
        }

        engine.prepare()
        audioEngine = engine
        Logger.recording.info("Audio engine prepared (format: \(format))")
    }

    /// Brings the audio engine online and keeps it running with the tap
    /// installed so the very next `startCapture` is instantaneous.
    /// `bufferHandler` remains nil — buffers are discarded until capture begins,
    /// so no audio is written anywhere, but the system mic indicator is visible.
    /// Safe to call repeatedly; no-op when already hot.
    /// - Returns: true if the engine is running after the call.
    func startHotSession() async -> Bool {
        if isHot { return true }

        guard await requestMicrophonePermission() else {
            Logger.recording.warning("Microphone permission denied")
            return false
        }

        if !audioSessionConfigured {
            await prepareAudioSession()
            guard audioSessionConfigured else {
                Logger.recording.error("Failed to configure audio session for hot session")
                return false
            }
        }

        guard await startEngine() else { return false }
        isHot = true
        Logger.recording.info("Hot audio session started")
        return true
    }

    /// Begins forwarding captured audio buffers to `onBuffer`.
    /// Starts a hot session on demand if one isn't already running, so deep
    /// links and other cold-start paths still work without a separate call.
    /// - Parameter onBuffer: Called on the audio render thread with each
    ///   captured buffer. Must be lightweight — enqueue for processing elsewhere.
    /// - Returns: true if capture started successfully.
    func startCapture(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async -> Bool {
        if !isHot {
            guard await startHotSession() else { return false }
        }
        bufferHandler = onBuffer
        isRecording = true
        return true
    }

    // MARK: - Engine Lifecycle

    /// Starts the audio engine. Reuses a pre-prepared engine if available,
    /// otherwise creates one from scratch. The blocking `engine.start()` call
    /// runs on a background QoS queue so it does not stall MainActor —
    /// `engine.start()` can take 100-500ms, or several seconds under CoreML load.
    /// Returns true on success. Does NOT flip `isRecording` — that's the
    /// caller's decision, since hot-session startup runs with no buffer handler.
    private func startEngine() async -> Bool {
        // Reuse pre-prepared engine — tap is already installed, resources allocated.
        if let engine = audioEngine, !engine.isRunning {
            if await Self.startEngineOffMain(engine) {
                let format = engine.inputNode.outputFormat(forBus: 0)
                Logger.recording.info("Audio engine started (pre-prepared, format: \(format))")
                return true
            }
            Logger.recording.warning("Pre-prepared engine failed to start, creating fresh engine")
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
            // Fall through to create fresh engine
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) {
            [weak self] buffer, _ in
            guard let self else { return }

            let level = Self.computeLevel(from: buffer)
            Task { @MainActor [weak self] in
                self?.appendLevel(level)
            }

            self.bufferHandler?(buffer)
        }

        if await Self.startEngineOffMain(engine) {
            audioEngine = engine
            Logger.recording.info("Audio engine started (format: \(format))")
            return true
        }
        inputNode.removeTap(onBus: 0)
        return false
    }

    /// Runs `engine.start()` on a `.userInitiated` background task so MainActor
    /// stays free. AVAudioEngine.start() is thread-safe per Apple's audio framework docs.
    private nonisolated static func startEngineOffMain(_ engine: AVAudioEngine) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            do {
                try engine.start()
                return true
            } catch {
                Logger.recording.error("engine.start failed: \(error)")
                return false
            }
        }.value
    }

    /// Tears down the current engine and starts a fresh one on the new audio route.
    /// Called when the audio route changes while the hot session is up (which
    /// includes any active recording).
    private func restartEngine() async {
        guard let oldEngine = audioEngine else { return }

        oldEngine.inputNode.removeTap(onBus: 0)
        oldEngine.stop()
        audioEngine = nil

        applyPreferredInput()

        if await startEngine() {
            Logger.recording.info("Audio engine restarted after route change")
        } else {
            isRecording = false
            isHot = false
            deactivateSession()
            Logger.recording.error("Failed to restart audio engine after route change")
        }
    }

    /// Stops consuming audio buffers but leaves the engine running so the
    /// next capture starts immediately. Use `endHotSession()` to fully
    /// release the microphone.
    func stopCapture() {
        bufferHandler = nil
        isRecording = false
        audioLevels = Array(repeating: 0, count: Self.levelSampleCount)
        Logger.recording.info("Capture stopped (hot session alive)")
    }

    /// Fully ends the hot session: removes the tap, stops the engine, drops
    /// the mic indicator. The audio session itself stays active so the next
    /// cold start only pays engine startup, not session activation.
    func endHotSession() {
        guard let engine = audioEngine else {
            isHot = false
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        bufferHandler = nil
        isRecording = false
        isHot = false
        audioLevels = Array(repeating: 0, count: Self.levelSampleCount)

        Logger.recording.info("Hot audio session ended")
    }

    /// Deactivates the audio session and cleans up observers.
    /// Called when the app goes to background so other audio apps can resume.
    func deactivateSession() {
        guard audioSessionConfigured else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Logger.recording.warning("Failed to deactivate audio session: \(error)")
        }
        audioSessionConfigured = false
        removeInterruptionObservers()
        Logger.recording.info("Audio session deactivated")
    }

    // MARK: - Level Metering

    /// Computes a normalized audio level (0.0–1.0) from raw PCM buffer samples.
    private nonisolated static func computeLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength))

        // RMS (Root Mean Square) for average loudness
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        let rms = sqrt(sumOfSquares / Float(samples.count))

        // Convert to dB-like scale, then normalize to 0–1
        let dB = 20 * log10(max(rms, silenceFloor))
        let linear = max(0, (dB + dbRange) / dbRange)
        // Square root curve expands the speech range into a wider visual range
        return sqrt(linear)
    }

    private func appendLevel(_ level: Float) {
        let previous = audioLevels.last ?? 0
        let smoothed = level >= previous
            ? level
            : previous * Self.levelDecayFactor + level * (1 - Self.levelDecayFactor)
        audioLevels.removeFirst()
        audioLevels.append(smoothed)
    }

    // MARK: - Audio Session Interruption Handling

    private func setupInterruptionObservers() {
        let center = NotificationCenter.default

        let interruptionToken = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Extract values before crossing isolation boundary to avoid Sendable warnings
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }

        let routeChangeToken = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reasonValue: reasonValue)
            }
        }

        interruptionObservers = [interruptionToken, routeChangeToken]
    }

    private func removeInterruptionObservers() {
        for observer in interruptionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        interruptionObservers = []
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard
            let typeValue,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            Logger.recording.info("Audio session interrupted (e.g., phone call)")

        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)

            if options.contains(.shouldResume) {
                Logger.recording.info("Audio interruption ended — resuming")
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try audioEngine?.start()
                } catch {
                    Logger.recording.error("Failed to resume after interruption: \(error)")
                }
            } else {
                Logger.recording.warning("Audio interruption ended — system says do not resume")
            }

        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard
            let reasonValue,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        Logger.recording.info("Audio route changed — reason: \(reasonValue)")

        // Restart on any active engine (hot-but-not-recording or recording),
        // so the next capture doesn't start on a stale device/format.
        guard isHot else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
            // Device/route change — restart engine to re-apply input and pick up new format.
            Task { await restartEngine() }
        default:
            break
        }
    }
}
