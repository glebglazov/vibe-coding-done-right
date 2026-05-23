import Foundation
import AVFoundation
import OSLog

@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    /// True while the audio engine is running with the tap installed — ready
    /// to accept a `bufferHandler` and flip `isRecording` without another
    /// `engine.start()` round-trip. Derived from `AVAudioEngine.isRunning`
    /// so it cannot drift from reality: iOS can stop the engine on us
    /// (interruption, background suspension, audio session deactivation by
    /// another process) and this property immediately reflects that, so any
    /// start-path check against it is always truthful.
    var isHot: Bool { audioEngine?.isRunning == true }
    /// Rolling buffer of recent audio level samples (0.0–1.0), one per meter tick.
    private(set) var audioLevels: [Float] = Array(repeating: 0, count: levelSampleCount)

    private var audioEngine: AVAudioEngine?
    private var audioSessionConfigured = false
    /// In-flight setup tasks. Concurrent callers join the same Task instead of
    /// running duplicate AVAudioSession / engine setup bodies. Without these,
    /// scene-active + prewarm + a record tap landing in the same launch window
    /// can fire three parallel `setActive(true)` calls, which iOS serializes
    /// internally — turning a 100ms config into a 10+ second stall.
    @ObservationIgnored
    private var prepareSessionTask: Task<Bool, Never>?
    @ObservationIgnored
    private var prepareEngineTask: Task<AVAudioEngine?, Never>?
    @ObservationIgnored
    private var startHotSessionTask: Task<Bool, Never>?
    /// nonisolated(unsafe) because the audio tap callback reads this from the audio thread.
    /// Safe: only set before starting the engine, cleared after stopping it.
    @ObservationIgnored
    private nonisolated(unsafe) var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// One-shot diagnostic: logs once when the first audio buffer arrives from
    /// the input tap. If recording shows zero waveform / zero timer, the
    /// absence of this log line tells us the engine never actually fired the
    /// render callback (engine.start succeeded but HAL didn't deliver audio).
    @ObservationIgnored
    private nonisolated(unsafe) var hasLoggedFirstBuffer = false
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
    private nonisolated static let tapBufferSize: AVAudioFrameCount = 4096
    /// Floor value to avoid log10(0) when computing level from silent audio
    private nonisolated static let silenceFloor: Float = 1e-7
    /// dB range mapped to 0.0–1.0 linear scale (matches AVAudioRecorder.averagePower range)
    private nonisolated static let dbRange: Float = 60

    func requestMicrophonePermission() async -> Bool {
        Logger.app.info("[LaunchProbe] requestMicrophonePermission entry main=\(Thread.isMainThread)")
        // Fast path: skip the async hop when permission is already granted
        if AVAudioApplication.shared.recordPermission == .granted {
            Logger.app.info("[LaunchProbe] requestMicrophonePermission already-granted")
            return true
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        Logger.app.info("[LaunchProbe] requestMicrophonePermission resolved granted=\(granted) main=\(Thread.isMainThread)")
        return granted
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
        Logger.app.info("[LaunchProbe] prepareAudioSession entry main=\(Thread.isMainThread)")
        guard !audioSessionConfigured else {
            Logger.app.info("[LaunchProbe] prepareAudioSession already-configured")
            return
        }
        if let inflight = prepareSessionTask {
            Logger.app.info("[LaunchProbe] prepareAudioSession joining in-flight")
            _ = await inflight.value
            return
        }
        // AVAudioSession configuration is thread-safe — run off main thread
        // to avoid blocking UI during setCategory/setActive (~50-200ms).
        // The Task itself flips audioSessionConfigured before completing so
        // a joining caller observes the property already set on resume.
        let task = Task<Bool, Never> { [weak self] in
            let success = await Task.detached(priority: .userInitiated) { () -> Bool in
                Logger.app.info("[LaunchProbe] prepareAudioSession detached body start main=\(Thread.isMainThread)")
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
                    Logger.app.info("[LaunchProbe] prepareAudioSession detached body end main=\(Thread.isMainThread)")
                    return true
                } catch {
                    Logger.recording.warning("Failed to pre-configure audio session: \(error)")
                    return false
                }
            }.value
            if success, let self {
                self.audioSessionConfigured = true
                self.setupInterruptionObservers()
                Logger.recording.info("Audio session pre-configured")
            }
            return success
        }
        prepareSessionTask = task
        _ = await task.value
        prepareSessionTask = nil
        Logger.app.info("[LaunchProbe] prepareAudioSession exit main=\(Thread.isMainThread)")
    }

    /// Pre-allocates audio engine resources so that `startRecording` is fast.
    /// Call after `prepareAudioSession()` completes. The engine is created and
    /// prepared (resources allocated) but NOT started — no microphone indicator
    /// appears until `startRecording` is called.
    ///
    /// Construction, `outputFormat`, `installTap`, and `prepare()` each touch
    /// the audio unit and together cost a few hundred ms on first launch.
    /// They run off the main actor so the PREPARING UI stays responsive.
    func prepareEngine() async {
        Logger.app.info("[LaunchProbe] prepareEngine entry main=\(Thread.isMainThread)")
        guard audioSessionConfigured, audioEngine == nil else {
            Logger.app.info("[LaunchProbe] prepareEngine skip configured=\(self.audioSessionConfigured) hasEngine=\(self.audioEngine != nil)")
            return
        }
        if let inflight = prepareEngineTask {
            Logger.app.info("[LaunchProbe] prepareEngine joining in-flight")
            _ = await inflight.value
            return
        }

        let task = Task<AVAudioEngine?, Never> { [weak self] in
            let engine = await Task.detached(priority: .userInitiated) { [weak self] () -> AVAudioEngine in
                Logger.app.info("[LaunchProbe] prepareEngine detached body start main=\(Thread.isMainThread)")
                let engine = AVAudioEngine()
                Logger.app.info("[LaunchProbe] prepareEngine after AVAudioEngine() main=\(Thread.isMainThread)")
                let inputNode = engine.inputNode
                let format = inputNode.outputFormat(forBus: 0)
                Logger.app.info("[LaunchProbe] prepareEngine after outputFormat main=\(Thread.isMainThread)")

                inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) {
                    buffer, _ in
                    guard let self else { return }

                    if !self.hasLoggedFirstBuffer {
                        self.hasLoggedFirstBuffer = true
                        Logger.app.info("[LaunchProbe] first audio buffer from tap (prepareEngine) handler=\(self.bufferHandler != nil)")
                    }

                    let level = Self.computeLevel(from: buffer)
                    Task { @MainActor [weak self] in
                        self?.appendLevel(level)
                    }

                    self.bufferHandler?(buffer)
                }
                Logger.app.info("[LaunchProbe] prepareEngine after installTap main=\(Thread.isMainThread)")

                engine.prepare()
                Logger.app.info("[LaunchProbe] prepareEngine after engine.prepare main=\(Thread.isMainThread)")
                Logger.recording.info("Audio engine prepared (format: \(format))")
                return engine
            }.value
            self?.audioEngine = engine
            return engine
        }
        prepareEngineTask = task
        _ = await task.value
        prepareEngineTask = nil
        Logger.app.info("[LaunchProbe] prepareEngine exit main=\(Thread.isMainThread)")
    }

    /// Brings the audio engine online and keeps it running with the tap
    /// installed so the very next `startCapture` is instantaneous.
    /// `bufferHandler` remains nil — buffers are discarded until capture begins,
    /// so no audio is written anywhere, but the system mic indicator is visible.
    /// Safe to call repeatedly; a no-op once the engine is running. Because
    /// `isHot` is derived from `AVAudioEngine.isRunning`, the early-return
    /// below can never skip past a dead engine.
    /// - Returns: true if the engine is running after the call.
    func startHotSession() async -> Bool {
        if isHot {
            Logger.recording.debug("startHotSession: engine already running — no-op")
            return true
        }
        if let inflight = startHotSessionTask {
            Logger.recording.debug("startHotSession: joining in-flight")
            return await inflight.value
        }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self._performStartHotSession()
        }
        startHotSessionTask = task
        let result = await task.value
        startHotSessionTask = nil
        return result
    }

    private func _performStartHotSession() async -> Bool {
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
        } else {
            // Session was configured before, but after idle timeout or
            // interruption it may be inactive or the route may have changed
            // while we had no engine running. Re-activate and pin the input
            // so the engine starts on a clean, active session.
            do {
                try await Task.detached(priority: .userInitiated) {
                    try AVAudioSession.sharedInstance().setActive(true)
                }.value
            } catch {
                Logger.recording.warning("Failed to re-activate audio session: \(error)")
                audioSessionConfigured = false
                await prepareAudioSession()
                guard audioSessionConfigured else {
                    Logger.recording.error("Failed to configure audio session for hot session")
                    return false
                }
            }
        }

        applyPreferredInput()

        guard await startEngine() else {
            Logger.recording.error("startHotSession: startEngine() failed")
            return false
        }
        Logger.recording.info("Hot audio session started (isHot=\(self.isHot))")
        return true
    }

    /// Begins forwarding captured audio buffers to `onBuffer`.
    /// Starts a hot session on demand if one isn't already running, so deep
    /// links and other cold-start paths still work without a separate call.
    /// - Parameter onBuffer: Called on the audio render thread with each
    ///   captured buffer. Must be lightweight — enqueue for processing elsewhere.
    /// - Returns: true if capture started successfully.
    func startCapture(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async -> Bool {
        Logger.app.info("[LaunchProbe] startCapture entry isHot=\(self.isHot)")
        if !isHot {
            guard await startHotSession() else {
                Logger.recording.error("startCapture: startHotSession() failed")
                return false
            }
        }
        bufferHandler = onBuffer
        isRecording = true
        Logger.recording.info("Capture started (isHot=\(self.isHot)) engineRunning=\(self.audioEngine?.isRunning == true)")
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
        Logger.app.info("[LaunchProbe] startEngine entry preExistingEngine=\(self.audioEngine != nil)")
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

        Logger.app.info("[LaunchProbe] startEngine creating fresh engine")
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        Logger.app.info("[LaunchProbe] startEngine after outputFormat fresh format=\(format)")

        inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) {
            [weak self] buffer, _ in
            guard let self else { return }

            if !self.hasLoggedFirstBuffer {
                self.hasLoggedFirstBuffer = true
                Logger.app.info("[LaunchProbe] first audio buffer from tap (startEngine fresh) handler=\(self.bufferHandler != nil)")
            }

            let level = Self.computeLevel(from: buffer)
            Task { @MainActor [weak self] in
                self?.appendLevel(level)
            }

            self.bufferHandler?(buffer)
        }
        Logger.app.info("[LaunchProbe] startEngine after installTap fresh")

        if await Self.startEngineOffMain(engine) {
            audioEngine = engine
            Logger.recording.info("Audio engine started (format: \(format))")
            return true
        }
        inputNode.removeTap(onBus: 0)
        Logger.recording.error("startEngine: fresh engine failed to start")
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
        let wasRunning = isHot
        guard let engine = audioEngine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        bufferHandler = nil
        isRecording = false
        audioLevels = Array(repeating: 0, count: Self.levelSampleCount)

        Logger.recording.info("Hot audio session ended (engine was running: \(wasRunning))")
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
            // iOS stops the engine for us during interruption and deactivates
            // the audio session. Drop our reference AND reset the configured
            // flag so the next start path re-activates the session cleanly.
            Logger.recording.warning("Audio session interrupted — dropping engine reference (was isHot=\(self.isHot), isRecording=\(self.isRecording))")
            if let engine = audioEngine {
                engine.inputNode.removeTap(onBus: 0)
            }
            audioEngine = nil
            bufferHandler = nil
            isRecording = false
            audioSessionConfigured = false

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
