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
        await AVAudioApplication.requestRecordPermission()
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
                setupInterruptionObservers()
            } catch {
                Logger.recording.error("Failed to configure audio session: \(error)")
                return false
            }
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        bufferHandler = onBuffer

        inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) {
            [weak self] buffer, _ in
            guard let self else { return }

            // Compute level from raw samples (runs on audio thread)
            let level = Self.computeLevel(from: buffer)
            Task { @MainActor [weak self] in
                self?.appendLevel(level)
            }

            // Forward buffer to streaming transcription
            self.bufferHandler?(buffer)
        }

        do {
            try engine.start()
            audioEngine = engine
            isRecording = true
            Logger.recording.info("Recording started via AVAudioEngine (format: \(format))")
            return true
        } catch {
            Logger.recording.error("Failed to start audio engine: \(error)")
            inputNode.removeTap(onBus: 0)
            audioSessionConfigured = false
            return false
        }
    }

    /// Stops recording and cleans up the audio engine.
    func stopRecording() {
        guard let engine = audioEngine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        bufferHandler = nil
        isRecording = false
        audioLevels = Array(repeating: 0, count: Self.levelSampleCount)

        // Deactivate audio session so other apps (e.g. Music) resume playback
        if audioSessionConfigured {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Logger.recording.warning("Failed to deactivate audio session: \(error)")
            }
            audioSessionConfigured = false
        }
        removeInterruptionObservers()

        Logger.recording.info("Recording stopped")
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
                try? AVAudioSession.sharedInstance().setActive(true)
                try? audioEngine?.start()
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

        if reason == .oldDeviceUnavailable {
            // Headphones unplugged — audio route changed to speaker.
            // Recording continues through the new route.
            Logger.recording.info("Audio route changed — old device unavailable")
        }
    }
}
