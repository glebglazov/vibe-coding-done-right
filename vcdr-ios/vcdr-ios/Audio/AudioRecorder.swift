import Foundation
import AVFoundation
import OSLog

@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
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

    /// Applies the user's preferred audio input (stored in UserDefaults) to the audio session.
    /// Falls back to the system default if the saved input is no longer available.
    private func applyPreferredInput() {
        let session = AVAudioSession.sharedInstance()
        guard let savedUID = UserDefaults.standard.string(forKey: Self.preferredInputUIDKey),
              let match = session.availableInputs?.first(where: { $0.uid == savedUID })
        else {
            // No preference or saved device unavailable — use system default
            return
        }
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
    func prepareAudioSession() async {
        guard !audioSessionConfigured else { return }
        // AVAudioSession configuration is thread-safe — run off main thread
        // to avoid blocking UI during setCategory/setActive (~50-200ms).
        let success = await Task.detached {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
                return true
            } catch {
                Logger.recording.warning("Failed to pre-configure audio session: \(error)")
                return false
            }
        }.value

        guard success else { return }
        audioSessionConfigured = true
        applyPreferredInput()
        setupInterruptionObservers()
        Logger.recording.info("Audio session pre-configured")
    }

    /// Starts recording via AVAudioEngine. Buffers are forwarded to `onBuffer` on the audio thread.
    /// - Parameter onBuffer: Called on the audio render thread with each captured buffer.
    ///   Must be lightweight — enqueue for processing elsewhere.
    /// - Returns: true if recording started successfully.
    func startRecording(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async -> Bool {
        guard await requestMicrophonePermission() else {
            Logger.recording.warning("Microphone permission denied")
            return false
        }

        if !audioSessionConfigured {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
                audioSessionConfigured = true
                applyPreferredInput()
                setupInterruptionObservers()
            } catch {
                Logger.recording.error("Failed to configure audio session: \(error)")
                return false
            }
        }

        bufferHandler = onBuffer

        guard startEngine() else {
            // Engine failed to start — deactivate the session we just activated
            // so it doesn't interfere with other apps' audio.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionConfigured = false
            return false
        }
        return true
    }

    // MARK: - Engine Lifecycle

    /// Creates a new AVAudioEngine, installs the buffer tap, and starts it.
    /// Returns true on success. Assumes `bufferHandler` is already set.
    private func startEngine() -> Bool {
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

        do {
            try engine.start()
            audioEngine = engine
            isRecording = true
            Logger.recording.info("Audio engine started (format: \(format))")
            return true
        } catch {
            Logger.recording.error("Failed to start audio engine: \(error)")
            inputNode.removeTap(onBus: 0)
            return false
        }
    }

    /// Tears down the current engine and starts a fresh one on the new audio route.
    /// Called when the audio route changes mid-recording (e.g. AirPods connect/disconnect).
    private func restartEngine() {
        guard let oldEngine = audioEngine else { return }

        oldEngine.inputNode.removeTap(onBus: 0)
        oldEngine.stop()
        audioEngine = nil

        applyPreferredInput()

        if startEngine() {
            Logger.recording.info("Audio engine restarted after route change")
        } else {
            isRecording = false
            deactivateSession()
            Logger.recording.error("Failed to restart audio engine after route change")
        }
    }

    /// Stops recording and cleans up the audio engine.
    /// The audio session stays active so subsequent recordings start faster.
    /// Call `deactivateSession()` when the app goes to background.
    func stopRecording() {
        guard let engine = audioEngine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        bufferHandler = nil
        isRecording = false
        audioLevels = Array(repeating: 0, count: Self.levelSampleCount)

        Logger.recording.info("Recording stopped (session stays active)")
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

        guard isRecording else { return }

        switch reason {
        case .newDeviceAvailable:
            // New device connected (e.g. AirPods) — iOS auto-switches to it.
            // Restart engine to re-apply preferred input and pick up the new format.
            restartEngine()
        case .oldDeviceUnavailable:
            // Device disconnected (e.g. AirPods removed) — input node is stale.
            // Restart engine so recording continues through the new route.
            restartEngine()
        case .override, .routeConfigurationChange:
            // System or app changed the route — restart to stay in sync.
            restartEngine()
        default:
            break
        }
    }
}
