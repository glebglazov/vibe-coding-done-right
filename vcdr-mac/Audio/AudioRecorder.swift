import Foundation
import AVFoundation
import CoreAudio
import OSLog

/// Why `startRecording` did not start a recording. Named so the hotkey path can
/// tell the one cause the user can fix — a missing permission — from every
/// other way the microphone can fail to come up.
enum RecordingStartFailure: Error, Equatable {
    case microphonePermissionDenied
    case unknown

    /// What the user reads on the capture pill.
    var message: String {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is off. Grant it in System Settings → Privacy & Security → Microphone."
        case .unknown:
            "The microphone could not be started. Try again in a moment."
        }
    }
}

@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    /// Rolling buffer of recent audio level samples (0.0–1.0), one per meter tick.
    /// Oldest sample at index 0, newest at the end. Used by the waveform visualizer
    /// so each bar reflects a different point in time.
    private(set) var audioLevels: [Float] = Array(repeating: 0, count: levelSampleCount)

    private var audioRecorder: AVAudioRecorder?
    /// nonisolated(unsafe) allows deinit cleanup. Safe because deinit runs
    /// only when no other references exist, so no concurrent access is possible.
    private nonisolated(unsafe) var levelTimer: Timer?
    private var recordingStartTime: ContinuousClock.Instant?

    #if DEBUG
    /// When set, startRecording() copies this file instead of using the real microphone.
    var testAudioFileURL: URL?
    /// When set, startRecording() fails immediately with this reason instead of
    /// touching AVCaptureDevice — lets tests exercise a failed start (including
    /// permission denial) without a real TCC grant in the test host.
    var testStartFailure: RecordingStartFailure?
    private var testRecordingURL: URL?
    #endif

    /// The system default input device before we changed it, restored on stop.
    /// Prevents the Bluetooth A2DP→HFP codec switch when the user selects
    /// a non-Bluetooth mic (e.g. built-in MacBook mic) in the app's settings.
    private var previousDefaultInputDevice: AudioDeviceID?

    // MARK: - Constants

    /// Number of audio level samples kept for the waveform display
    static let levelSampleCount = 5
    /// How fast the displayed level drops when audio quiets down (0 = instant, 1 = no decay)
    private static let levelDecayFactor: Float = 0.3
    /// Parakeet's native sample rate — all recordings use this to avoid resampling
    private static let sampleRate: Double = 16000
    /// Minimum frames Parakeet can process (1 second at 16kHz)
    private static let minimumFrameCount: AVAudioFrameCount = 16000
    /// Duration threshold below which silence padding is needed
    private static let minimumRecordingDuration: Duration = .seconds(1)
    /// Mono channel for voice recording
    private static let channelCount = 1
    /// 16-bit PCM depth for Parakeet compatibility
    private static let bitDepth = 16
    /// How often audio levels are sampled for the waveform display
    private static let levelTimerInterval: TimeInterval = 0.05
    /// AVFoundation reports average power from roughly -N dBFS to 0 dBFS;
    /// this floor is used to normalize the value into a 0.0–1.0 range
    private static let decibelFloor: Float = 60

    nonisolated func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                continuation.resume(returning: true)
            case .denied, .restricted:
                continuation.resume(returning: false)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            @unknown default:
                continuation.resume(returning: false)
            }
        }
    }

    /// Starts recording. If `deviceUID` is provided, temporarily sets the system
    /// default input device to that device so AVAudioRecorder uses it instead of
    /// whatever macOS auto-selected (which may be a Bluetooth mic, triggering
    /// the A2DP→HFP codec switch and degrading output quality).
    func startRecording(deviceUID: String? = nil) async -> Result<Void, RecordingStartFailure> {
        #if DEBUG
        if let failure = testStartFailure {
            return .failure(failure)
        }
        if let testURL = testAudioFileURL {
            return startTestRecording(sourceURL: testURL) ? .success(()) : .failure(.unknown)
        }
        #endif

        guard await requestMicrophonePermission() else {
            Logger.recording.warning("Microphone permission denied")
            return .failure(.microphonePermissionDenied)
        }

        // Route to the preferred input device before AVAudioRecorder activates.
        // CoreAudio device switching is thread-safe, so run it off MainActor
        // to keep the UI responsive during recording start.
        if let deviceUID {
            if let previous = await Self.routeToPreferredInputOffMain(deviceUID: deviceUID) {
                previousDefaultInputDevice = previous
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
        let audioFile = tempDir.appendingPathComponent("vcdr_recording_\(UUID().uuidString).wav")

        // Record at 16kHz mono — Parakeet's native format, no resampling needed
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channelCount,
            AVLinearPCMBitDepthKey: Self.bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: audioFile, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()

            guard audioRecorder?.record() == true else {
                Logger.recording.error("Failed to start recording")
                return .failure(.unknown)
            }

            isRecording = true
            recordingStartTime = .now
            startLevelMonitoring()
            Logger.recording.info("Recording started: \(audioFile.lastPathComponent)")
            return .success(())
        } catch {
            Logger.recording.error("Recording setup failed: \(error)")
            return .failure(.unknown)
        }
    }

    func stopRecording() -> URL? {
        #if DEBUG
        if testRecordingURL != nil {
            return stopTestRecording()
        }
        #endif

        guard let recorder = audioRecorder else { return nil }

        let url = recorder.url
        recorder.stop()
        stopLevelMonitoring()
        restorePreviousInputDevice()

        let wasShort = recordingStartTime.map { $0.duration(to: .now) < Self.minimumRecordingDuration } ?? false

        isRecording = false
        audioLevels = Array(repeating: 0, count: Self.levelSampleCount)
        audioRecorder = nil
        recordingStartTime = nil

        if wasShort {
            padToMinimumDuration(fileURL: url)
        }
        Logger.recording.info("Recording stopped: \(url.lastPathComponent)")
        return url
    }

    // MARK: - Silence Padding

    /// Pads a short recording with silence so Parakeet can process it.
    /// Parakeet requires at least 1 second of audio; quick utterances like
    /// "yes" or "no" may be shorter. Silence is zero-valued PCM samples.
    private func padToMinimumDuration(fileURL: URL) {
        do {
            let inputFile = try AVAudioFile(forReading: fileURL)
            let frameCount = AVAudioFrameCount(inputFile.length)

            guard frameCount < Self.minimumFrameCount else { return }

            let silenceFrames = Self.minimumFrameCount - frameCount
            let format = inputFile.processingFormat

            // Read original audio
            guard let originalBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            try inputFile.read(into: originalBuffer)

            // Create silence buffer (AVAudioPCMBuffer is zero-filled by default)
            guard let silenceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: silenceFrames) else { return }
            silenceBuffer.frameLength = silenceFrames

            // Write original + silence to same URL
            let outputFile = try AVAudioFile(forWriting: fileURL, settings: inputFile.fileFormat.settings)
            try outputFile.write(from: originalBuffer)
            try outputFile.write(from: silenceBuffer)

            Logger.recording.info("Padded short recording from \(frameCount) to \(Self.minimumFrameCount) frames")
        } catch {
            // Non-fatal — let Parakeet attempt transcription on the original file
            Logger.recording.warning("Failed to pad short recording: \(error)")
        }
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: Self.levelTimerInterval, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let averagePower = recorder.averagePower(forChannel: 0)
            let linear = max(0.0, (averagePower + Self.decibelFloor) / Self.decibelFloor)
            // Square root curve expands the speech range (~0.4–0.8 linear)
            // into a wider visual range, making the waveform more responsive
            let curved = sqrt(linear)
            // Fast attack, quick decay: jump to new level immediately when louder,
            // but decay exponentially when quieter so bars drop fast after speech
            let previous = self.audioLevels.last ?? 0
            let smoothed = curved >= previous ? curved : previous * Self.levelDecayFactor + curved * (1 - Self.levelDecayFactor)
            self.audioLevels.removeFirst()
            self.audioLevels.append(smoothed)
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    // MARK: - Input Device Routing

    /// Resolves the UID, reads the current default, and switches the system default
    /// input device — all on a background thread. Returns the previous default so the
    /// caller can stash it for `restorePreviousInputDevice()`. All CoreAudio property
    /// calls used here are thread-safe.
    private nonisolated static func routeToPreferredInputOffMain(deviceUID: String) async -> AudioDeviceID? {
        await Task.detached(priority: .userInitiated) {
            guard let targetDeviceID = CoreAudioHelpers.deviceID(forUID: deviceUID) else {
                Logger.recording.warning("Could not resolve preferred device UID: \(deviceUID)")
                return AudioDeviceID?.none
            }
            let currentDefault = Self.getSystemDefaultInputDevice()
            guard currentDefault != targetDeviceID else {
                return AudioDeviceID?.none
            }
            Self.setSystemDefaultInputDevice(targetDeviceID)
            Logger.recording.info("Switched system input to preferred device (UID: \(deviceUID))")
            return currentDefault
        }.value
    }

    /// Restores the system default input device that was active before recording.
    private func restorePreviousInputDevice() {
        guard let previousDevice = previousDefaultInputDevice else { return }
        Self.setSystemDefaultInputDevice(previousDevice)
        previousDefaultInputDevice = nil
        Logger.recording.info("Restored previous system input device")
    }

    private nonisolated static func getSystemDefaultInputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    private nonisolated static func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) {
        var mutableID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableID
        )
        if status != noErr {
            Logger.recording.warning("Failed to set system input device: \(status)")
        }
    }

    #if DEBUG
    // MARK: - Test Mode

    private func startTestRecording(sourceURL: URL) -> Bool {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("vcdr_test_\(UUID().uuidString).wav")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: tempFile)
        } catch {
            Logger.recording.error("Failed to copy test audio file: \(error)")
            return false
        }
        testRecordingURL = tempFile
        isRecording = true
        recordingStartTime = .now
        Logger.recording.info("Test recording started with: \(sourceURL.lastPathComponent)")
        return true
    }

    private func stopTestRecording() -> URL? {
        let url = testRecordingURL
        testRecordingURL = nil
        isRecording = false
        audioLevels = Array(repeating: 0, count: Self.levelSampleCount)
        recordingStartTime = nil
        Logger.recording.info("Test recording stopped")
        return url
    }
    #endif

    deinit {
        levelTimer?.invalidate()
    }
}
