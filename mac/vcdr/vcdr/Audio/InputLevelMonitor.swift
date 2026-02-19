import AVFoundation
import CoreAudio
import OSLog

@Observable
@MainActor
final class InputLevelMonitor {
    private(set) var level: Float = 0.0
    private(set) var isMonitoring = false

    private var audioEngine: AVAudioEngine?

    // MARK: - Constants

    private static let tapBufferSize: AVAudioFrameCount = 1024
    /// Scale factor to map RMS (typically 0.0–0.5) to a visible 0.0–1.0 range
    private static let rmsScaleFactor: Float = 2.0

    // MARK: - Lifecycle

    func start(deviceUID: String?) {
        stop()

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Logger.audio.info("Skipping level monitor — microphone permission not granted")
            return
        }

        let engine = AVAudioEngine()

        if let deviceUID {
            guard let audioDeviceID = coreAudioDeviceID(for: deviceUID) else {
                Logger.audio.warning("Could not resolve device UID: \(deviceUID)")
                return
            }
            setInputDevice(audioDeviceID, on: engine)
        }
        // When deviceUID is nil, AVAudioEngine uses system default automatically

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) { [weak self] buffer, _ in
            let rms = Self.computeRMS(buffer: buffer)
            Task { @MainActor [weak self] in
                self?.level = rms
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            isMonitoring = true
            Logger.audio.info("Level monitoring started (device: \(deviceUID ?? "system default"))")
        } catch {
            Logger.audio.error("Failed to start level monitor: \(error)")
            inputNode.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        isMonitoring = false
        level = 0.0
        Logger.audio.info("Level monitoring stopped")
    }

    // MARK: - RMS Computation

    private static func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0.0 }

        var sum: Float = 0.0
        let samples = channelData[0]
        for i in 0..<frames {
            let sample = samples[i]
            sum += sample * sample
        }
        let rms = sqrtf(sum / Float(frames))
        return min(rms * rmsScaleFactor, 1.0)
    }

    // MARK: - CoreAudio Device Resolution

    /// Translates an AVCaptureDevice uniqueID to a CoreAudio AudioDeviceID
    private func coreAudioDeviceID(for uid: String) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var uidCF = uid as CFString

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status: OSStatus = withUnsafeMutablePointer(to: &uidCF) { uidPtr in
            withUnsafeMutablePointer(to: &deviceID) { devicePtr in
                var translation = AudioValueTranslation(
                    mInputData: uidPtr,
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: devicePtr,
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &size,
                    &translation
                )
            }
        }

        guard status == noErr else {
            Logger.audio.warning("CoreAudio UID translation failed: \(status)")
            return nil
        }
        return deviceID
    }

    /// Sets the input device on the audio engine's input node
    private func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) {
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            Logger.audio.warning("Could not access audio unit on input node")
            return
        }
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Logger.audio.warning("Failed to set input device: \(status)")
        }
    }
}
