import Foundation
import AVFoundation
import CoreAudio
import OSLog

@Observable
final class AudioRecorder: NSObject {
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0.0

    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var recordingStartTime: ContinuousClock.Instant?

    /// The system default input device before we changed it, restored on stop.
    /// Prevents the Bluetooth A2DP→HFP codec switch when the user selects
    /// a non-Bluetooth mic (e.g. built-in MacBook mic) in the app's settings.
    private var previousDefaultInputDevice: AudioDeviceID?

    // MARK: - Constants

    /// Parakeet's native sample rate — all recordings use this to avoid resampling
    private static let sampleRate: Double = 16000
    /// Minimum frames Parakeet can process (1 second at 16kHz)
    private static let minimumFrameCount: AVAudioFrameCount = 16000
    /// Duration threshold below which silence padding is needed
    private static let minimumRecordingDuration: Duration = .seconds(1)

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
    func startRecording(deviceUID: String? = nil) async -> Bool {
        guard await requestMicrophonePermission() else {
            Logger.recording.warning("Microphone permission denied")
            return false
        }

        // Route to the preferred input device before AVAudioRecorder activates
        if let deviceUID {
            routeToPreferredInput(deviceUID: deviceUID)
        }

        let tempDir = FileManager.default.temporaryDirectory
        let audioFile = tempDir.appendingPathComponent("vcdr_recording_\(UUID().uuidString).wav")

        // Record at 16kHz mono — Parakeet's native format, no resampling needed
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: audioFile, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()

            guard audioRecorder?.record() == true else {
                Logger.recording.error("Failed to start recording")
                return false
            }

            isRecording = true
            recordingStartTime = .now
            startLevelMonitoring()
            Logger.recording.info("Recording started: \(audioFile.lastPathComponent)")
            return true
        } catch {
            Logger.recording.error("Recording setup failed: \(error)")
            return false
        }
    }

    func stopRecording() -> URL? {
        guard let recorder = audioRecorder else { return nil }

        let url = recorder.url
        recorder.stop()
        stopLevelMonitoring()
        restorePreviousInputDevice()

        let wasShort = recordingStartTime.map { $0.duration(to: .now) < Self.minimumRecordingDuration } ?? false

        isRecording = false
        audioLevel = 0.0
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
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let averagePower = recorder.averagePower(forChannel: 0)
            self.audioLevel = max(0.0, (averagePower + 60) / 60)
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    // MARK: - Input Device Routing

    /// Saves the current system default input device, then sets it to the
    /// requested device UID. AVAudioRecorder always uses the system default,
    /// so this is the only way to force a specific mic on macOS.
    private func routeToPreferredInput(deviceUID: String) {
        guard let targetDeviceID = CoreAudioHelpers.deviceID(forUID: deviceUID) else {
            Logger.recording.warning("Could not resolve preferred device UID: \(deviceUID)")
            return
        }

        let currentDefault = getSystemDefaultInputDevice()
        if currentDefault != targetDeviceID {
            previousDefaultInputDevice = currentDefault
            setSystemDefaultInputDevice(targetDeviceID)
            Logger.recording.info("Switched system input to preferred device (UID: \(deviceUID))")
        }
    }

    /// Restores the system default input device that was active before recording.
    private func restorePreviousInputDevice() {
        guard let previousDevice = previousDefaultInputDevice else { return }
        setSystemDefaultInputDevice(previousDevice)
        previousDefaultInputDevice = nil
        Logger.recording.info("Restored previous system input device")
    }

    private func getSystemDefaultInputDevice() -> AudioDeviceID {
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

    private func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) {
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

    deinit {
        levelTimer?.invalidate()
    }
}
