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
    ///
    /// Mirror of the underlying `AVAudioEngine.isRunning`. Can drift out of
    /// sync when iOS stops the engine on us (interruption, background
    /// suspension, audio session deactivation by another process). Entry
    /// points that would early-return on this flag MUST reconcile against
    /// `isEngineLive` first — otherwise the bug manifests as a "hot" session
    /// with no tap callbacks: no waveform, no speech, mic stuck on.
    private(set) var isHot = false
    /// Rolling buffer of recent audio level samples (0.0–1.0), one per meter tick.
    private(set) var audioLevels: [Float] = Array(repeating: 0, count: levelSampleCount)

    private var audioEngine: AVAudioEngine?
    private var audioSessionConfigured = false

    /// Ground truth for "the engine is actually producing audio right now".
    /// `isHot` is our in-memory mirror and can lie after iOS interruptions or
    /// background suspensions; always prefer this for start-path guards.
    private var isEngineLive: Bool {
        audioEngine?.isRunning == true
    }
    /// nonisolated(unsafe) because the audio tap callback reads this from the audio thread.
    /// Safe: only set before starting the engine, cleared after stopping it.
    @ObservationIgnored
    private nonisolated(unsafe) var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Notification observer tokens for audio session interruption and route change.
    @ObservationIgnored
    private var interruptionObservers: [Any] = []

    // MARK: - Audio Input

    /// UserDefaults key for the "Use built-in microphone" toggle. Defaults to
    /// true when absent — the safe choice, since transcription accuracy drops
    /// sharply on Bluetooth HFP audio (16 kHz narrowband) and varies a lot
    /// across wired / USB accessories.
    static let useBuiltInMicOnlyKey = "useBuiltInMicOnly"

    private nonisolated static var useBuiltInMicOnly: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: useBuiltInMicOnlyKey) != nil else { return true }
        return defaults.bool(forKey: useBuiltInMicOnlyKey)
    }

    private nonisolated static func builtInInputPort(session: AVAudioSession) -> AVAudioSessionPortDescription? {
        session.availableInputs?.first(where: { $0.portType == .builtInMic })
    }

    /// Pins the built-in mic on an already-active session when the user has
    /// opted to force it. Called after route changes (e.g. a wired headset is
    /// plugged in mid-recording) so iOS doesn't silently swap inputs. When the
    /// user has turned the toggle off, we let iOS keep whatever input it picked.
    private func applyPreferredInput() {
        guard Self.useBuiltInMicOnly else { return }
        let session = AVAudioSession.sharedInstance()
        guard let builtIn = Self.builtInInputPort(session: session) else { return }
        do {
            try session.setPreferredInput(builtIn)
            Logger.recording.info("Set preferred input to built-in mic")
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
    /// Honours the "Use built-in microphone" toggle. When ON (the default) we
    /// deliberately omit `.allowBluetoothHFP`: HFP audio is 16 kHz narrowband,
    /// which tanks Parakeet's accuracy. Without the option AirPods simply
    /// don't appear as an input route, so iOS can't silently override our
    /// preferred input to them in `.playAndRecord` mode — which it does even
    /// when `setPreferredInput` points at the built-in mic, because the HFP
    /// link is bidirectional and iOS routes input along with output. When the
    /// toggle is OFF we include `.allowBluetoothHFP` so AirPods / BT headsets
    /// can be picked up, and we skip pinning the built-in mic so iOS is free
    /// to route to whatever accessory the user has connected.
    func prepareAudioSession() async {
        guard !audioSessionConfigured else { return }
        // AVAudioSession configuration is thread-safe — run off main thread
        // to avoid blocking UI during setCategory/setActive (~50-200ms).
        let success = await Task.detached {
            let session = AVAudioSession.sharedInstance()
            let forceBuiltIn = Self.useBuiltInMicOnly
            do {
                var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
                if !forceBuiltIn {
                    options.insert(.allowBluetoothHFP)
                }
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                // Set the preferred input BEFORE setActive so iOS honours it
                // while picking the initial route. A post-activation call is
                // just a hint iOS may ignore.
                if forceBuiltIn, let builtIn = Self.builtInInputPort(session: session) {
                    try? session.setPreferredInput(builtIn)
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
    /// Safe to call repeatedly; no-op when already hot AND the engine is
    /// actually running. If `isHot` is set but the engine has been stopped
    /// by iOS (interruption, background suspension), the session is torn
    /// down and rebuilt so the caller gets a working engine back.
    /// - Returns: true if the engine is running after the call.
    func startHotSession() async -> Bool {
        if isHot {
            if isEngineLive {
                Logger.recording.debug("startHotSession: already hot and engine live — no-op")
                return true
            }
            // Stale: flag says hot but iOS has stopped the engine (interruption,
            // background suspension, session deactivation by another app).
            // Tear everything down so the rebuild below starts from scratch.
            Logger.recording.warning("startHotSession: stale hot flag (engine not running) — tearing down before rebuild")
            endHotSession()
        }

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

        guard await startEngine() else {
            Logger.recording.error("startHotSession: startEngine() failed")
            return false
        }
        isHot = true
        Logger.recording.info("Hot audio session started (engine.isRunning=\(self.isEngineLive))")
        return true
    }

    /// Begins forwarding captured audio buffers to `onBuffer`.
    /// Starts a hot session on demand if one isn't already running, so deep
    /// links and other cold-start paths still work without a separate call.
    /// - Parameter onBuffer: Called on the audio render thread with each
    ///   captured buffer. Must be lightweight — enqueue for processing elsewhere.
    /// - Returns: true if capture started successfully.
    func startCapture(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async -> Bool {
        // Reconcile against the real engine state before trusting `isHot`.
        // A stale `isHot` here is what produces the silent-failure bug: we
        // wire up `bufferHandler` and flip `isRecording = true` against a
        // dead engine, so no buffers ever arrive — no waveform, no speech,
        // mic indicator stuck on until the user kills the app.
        if isHot, !isEngineLive {
            Logger.recording.warning("startCapture: isHot=true but engine not running — rebuilding")
            endHotSession()
        }
        if !isHot {
            guard await startHotSession() else {
                Logger.recording.error("startCapture: startHotSession() failed")
                return false
            }
        }
        guard isEngineLive else {
            Logger.recording.error("startCapture: engine still not running after startHotSession — giving up")
            return false
        }
        bufferHandler = onBuffer
        isRecording = true
        Logger.recording.info("Capture started (engine.isRunning=\(self.isEngineLive))")
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
        let wasRunning = isEngineLive
        guard let engine = audioEngine else {
            if isHot {
                Logger.recording.warning("endHotSession: isHot was true but audioEngine was nil — clearing stale flag")
            }
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

        Logger.recording.info("Hot audio session ended (engine.isRunning was \(wasRunning))")
    }

    /// Deactivates the audio session and cleans up observers.
    /// Used by `restartEngine()` as a last resort when the new engine fails
    /// to start after a route change, so the session isn't left half-alive.
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
            // iOS stops the engine for us during interruption. Clear our mirror
            // state immediately so the next start path rebuilds from scratch
            // instead of no-op'ing on a dead engine. If we skipped this, the
            // user would see a "hot" session with no audio flowing.
            Logger.recording.warning("Audio session interrupted — clearing hot session state (was isHot=\(self.isHot), isRecording=\(self.isRecording), engine.isRunning=\(self.isEngineLive))")
            if let engine = audioEngine {
                engine.inputNode.removeTap(onBus: 0)
            }
            audioEngine = nil
            bufferHandler = nil
            isHot = false
            isRecording = false

        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            // No auto-resume: we tore down on `.began` so there's nothing to
            // resume into. The next record tap will rebuild cleanly via
            // `startCapture` → `startHotSession`.
            Logger.recording.info("Audio interruption ended (shouldResume=\(options.contains(.shouldResume))) — next record tap will rebuild")

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
