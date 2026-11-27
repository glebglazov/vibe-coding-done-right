import Foundation
import AVFoundation
import OSLog

@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    /// True while the audio engine is running with the tap installed — ready
    /// to open a capture and flip `isRecording` without another
    /// `engine.start()` round-trip. Derived from `AVAudioEngine.isRunning`
    /// so it cannot drift from reality: iOS can stop the engine on us
    /// (interruption, background suspension, audio session deactivation by
    /// another process) and this property immediately reflects that, so any
    /// start-path check against it is always truthful.
    var isHot: Bool { engineSlot.isRunning }
    /// Rolling buffer of recent audio level samples (0.0–1.0), one per meter tick.
    private(set) var audioLevels: [Float] = Array(repeating: 0, count: levelSampleCount)

    @ObservationIgnored
    private let engineSlot = AudioEngineSlot<AVAudioEngine>()
    /// Where the tap hands buffers, and which run holds the capture.
    @ObservationIgnored
    private let captureSink = CaptureSink()
    @ObservationIgnored
    private let engineLossFeed = EngineLossFeed()
    private var audioSessionConfigured = false
    /// In-flight setup tasks. Concurrent callers join the same Task instead of
    /// running duplicate AVAudioSession / engine setup bodies. Without these,
    /// scene-active + prewarm + a record tap landing in the same launch window
    /// can fire three parallel `setActive(true)` calls, which iOS serializes
    /// internally — turning a 100ms config into a 10+ second stall.
    @ObservationIgnored
    private var prepareSessionTask: Task<Bool, Never>?
    @ObservationIgnored
    private var startHotSessionTask: Task<Bool, Never>?
    /// Moves on at every `endHotSession`. A hot start remembers the epoch it
    /// began in and gives up after any await that a teardown overtook, so a
    /// Record that follows a teardown never joins, or inherits the failure
    /// of, a start that teardown already made stale.
    @ObservationIgnored
    private var hotSessionEpoch: UInt64 = 0
    /// Route notifications can arrive in bursts while an engine restart is
    /// suspended in audio setup. Keep one worker alive and collapse any burst
    /// into at most one follow-up restart against the latest route.
    @ObservationIgnored
    private var routeRestartTask: Task<Void, Never>?
    @ObservationIgnored
    private var routeRestartPending = false
    /// Notification observer tokens for audio session interruption and route change.
    @ObservationIgnored
    private var interruptionObservers: [Any] = []

    // MARK: - Audio Input

    /// UserDefaults key for the "Use built-in microphone" toggle. Defaults to
    /// true when absent — the safe choice, since transcription accuracy drops
    /// sharply on Bluetooth HFP audio (16 kHz narrowband) and varies a lot
    /// across wired / USB accessories.
    static let useBuiltInMicOnlyKey = "useBuiltInMicOnly"

    var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    private nonisolated static var useBuiltInMicOnly: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: useBuiltInMicOnlyKey) != nil else { return true }
        return defaults.bool(forKey: useBuiltInMicOnlyKey)
    }

    private nonisolated static func builtInInputPort(session: AVAudioSession) -> AVAudioSessionPortDescription? {
        session.availableInputs?.first(where: { $0.portType == .builtInMic })
    }

    /// Applies our recording category + options to the session. Factored out so
    /// the first-time configure AND every re-activate go through the same path.
    /// A bare `setActive(true)` after the session went inactive (idle timeout /
    /// interruption) does NOT reliably re-assert the category options, and a
    /// dropped `.mixWithOthers` flips us from "mix with other audio" to
    /// "interrupt other audio" — which silences the user's music. Because we
    /// also never told the other app it could resume, the music then stays
    /// paused until VCDR is force-quit. Re-applying the category on every
    /// activation closes that hole.
    private nonisolated static func applyRecordingCategory(to session: AVAudioSession) throws {
        let forceBuiltIn = useBuiltInMicOnly
        // `.mixWithOthers`: record without interrupting the user's music.
        // `.allowBluetoothA2DP`: KEEP AirPods / BT headphones as the OUTPUT route
        //   while `.playAndRecord` is active. Without it, iOS drops A2DP on
        //   activation and forces output to the earpiece/speaker — which is why
        //   opening the app yanked music off the user's AirPods onto the phone
        //   speaker. A2DP output-only coexists fine with a built-in-mic INPUT;
        //   the "A2DP can't record" duplex limit only applies if we also wanted
        //   the BT device's mic (HFP), which we don't when forcing built-in.
        // `.defaultToSpeaker` is deliberately OMITTED: it fires a `categoryChange`
        //   route event on every (re)activation and is a documented aggravator
        //   that can stop other apps' audio even with `.mixWithOthers`. The quiet-
        //   earpiece case (no headphones) is handled by a transient speaker
        //   override in `activateMixingSession`.
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothA2DP]
        if !forceBuiltIn {
            options.insert(.allowBluetoothHFP)
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        // Set the preferred input BEFORE setActive so iOS honours it while
        // picking the route. A post-activation call is just a hint iOS may ignore.
        if forceBuiltIn, let builtIn = builtInInputPort(session: session) {
            try? session.setPreferredInput(builtIn)
        }
    }

    /// Activates our session so it MIXES with (never interrupts) other apps'
    /// audio, then logs the resolved session state so we can confirm
    /// `.mixWithOthers` actually took effect and whether activation is what
    /// silences other audio. Output is bumped to the speaker (transiently — not
    /// via the `.defaultToSpeaker` category flag) only when forcing the built-in
    /// mic AND no external output is attached, so mixed music doesn't get stuck
    /// on the quiet earpiece. With headphones / AirPods present the route is
    /// left untouched so we don't yank the user's audio onto the phone speaker.
    private nonisolated static func activateMixingSession() throws {
        let session = AVAudioSession.sharedInstance()
        let otherBefore = session.isOtherAudioPlaying
        try applyRecordingCategory(to: session)
        try session.setActive(true)
        // `.playAndRecord` parks shared output on the quiet earpiece when nothing
        // external is attached. Bump it to the speaker so mixed audio stays
        // audible — but ONLY when there's no headphones / Bluetooth / AirPlay
        // output, or we'd steal the user's music off their AirPods onto the phone
        // speaker (and kick off a route-change → engine-restart cycle).
        if useBuiltInMicOnly, !hasExternalOutput(session) {
            try? session.overrideOutputAudioPort(.speaker)
        }
        let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        Logger.recording.info(
            "Session active: mix=\(session.categoryOptions.contains(.mixWithOthers)) opts=\(session.categoryOptions.rawValue) otherBefore=\(otherBefore) otherNow=\(session.isOtherAudioPlaying) silenceHint=\(session.secondaryAudioShouldBeSilencedHint) out=\(outputs)"
        )
    }

    /// True when the current output route is something other than the built-in
    /// speaker/earpiece — headphones, Bluetooth, USB, CarPlay, AirPlay, HDMI.
    /// Used to decide whether forcing the speaker would steal the user's audio
    /// from an external device they're actually listening on. Denylist (not
    /// allowlist) so future external port types default to "leave it alone".
    private nonisolated static func hasExternalOutput(_ session: AVAudioSession) -> Bool {
        session.currentRoute.outputs.contains { output in
            switch output.portType {
            case .builtInSpeaker, .builtInReceiver:
                return false
            default:
                return true
            }
        }
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
            // `setActive` blocks on mediaserverd — keep it off the cooperative
            // pool so it can't stall the main actor during launch.
            let success = await withBlockingTask(qos: .userInitiated) { () -> Bool in
                Logger.app.info("[LaunchProbe] prepareAudioSession detached body start main=\(Thread.isMainThread)")
                do {
                    try Self.activateMixingSession()
                    Logger.app.info("[LaunchProbe] prepareAudioSession detached body end main=\(Thread.isMainThread)")
                    return true
                } catch {
                    Logger.recording.warning("Failed to pre-configure audio session: \(error)")
                    return false
                }
            }
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
        _ = await engineSlot.prepared { [weak self] in await self?.buildEngine() }
        Logger.app.info("[LaunchProbe] prepareEngine exit main=\(Thread.isMainThread)")
    }

    /// Builds one prepared engine: tap installed and `prepare()`d, but NOT
    /// started, so no microphone indicator lights (vcdr-ios ADR-0001). Only
    /// `engineSlot` calls it, so concurrent callers — the launch prewarm and
    /// the record path — join one build and exactly ONE engine is assigned.
    /// A second engine would overwrite, and ARC-deallocate, the live one
    /// mid-recording. Do NOT re-split this into per-path builds.
    private func buildEngine() async -> AVAudioEngine? {
        guard audioSessionConfigured else {
            Logger.app.info("[LaunchProbe] buildEngine skip: session not configured")
            return nil
        }
        // First `inputNode` access lazily inits the input audio unit, a
        // blocking HAL call that can take many seconds cold. Off the
        // cooperative pool so it can't freeze the shell (gesture-gate timeout).
        return await withBlockingTask(qos: .userInitiated) { [weak self, captureSink] () -> AVAudioEngine in
            Logger.app.info("[LaunchProbe] buildEngine body start main=\(Thread.isMainThread)")
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) { buffer, _ in
                let level = AudioLevelMeter.level(of: buffer)
                Task { @MainActor [weak self] in
                    self?.appendLevel(level)
                }
                captureSink.deliver(buffer, level: level)
            }
            engine.prepare()
            Logger.recording.info("Audio engine prepared (format: \(format))")
            return engine
        }
    }

    /// Brings the audio engine online and keeps it running with the tap
    /// installed so the very next `startCapture` is instantaneous.
    /// No capture is open — buffers are discarded until capture begins,
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

        let epoch = hotSessionEpoch
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self._performStartHotSession(epoch: epoch)
        }
        startHotSessionTask = task
        let result = await task.value
        if startHotSessionTask == task { startHotSessionTask = nil }
        return result
    }

    /// False once a teardown has overtaken the start that began in `epoch`.
    /// Gives the session back when no newer start is using it, so a late
    /// activation does not leave the microphone on with no run and no timer.
    private func isCurrent(_ epoch: UInt64) -> Bool {
        guard epoch != hotSessionEpoch else { return true }
        Logger.recording.info("startHotSession: a teardown overtook this start — giving up")
        if startHotSessionTask == nil { deactivateSession() }
        return false
    }

    private func _performStartHotSession(epoch: UInt64) async -> Bool {
        guard await requestMicrophonePermission() else {
            Logger.recording.warning("Microphone permission denied")
            return false
        }
        guard isCurrent(epoch) else { return false }

        if !audioSessionConfigured {
            await prepareAudioSession()
            guard isCurrent(epoch) else { return false }
            guard audioSessionConfigured else {
                Logger.recording.error("Failed to configure audio session for hot session")
                return false
            }
        } else {
            // Session was configured before, but after idle timeout or
            // interruption it may be inactive or the route may have changed
            // while we had no engine running. Re-apply the category (so
            // `.mixWithOthers` can't have been silently dropped) and re-activate
            // so the engine starts on a clean, mixing, active session.
            do {
                try await withThrowingBlockingTask(qos: .userInitiated) {
                    try Self.activateMixingSession()
                }
                guard isCurrent(epoch) else { return false }
            } catch {
                Logger.recording.warning("Failed to re-activate audio session: \(error)")
                audioSessionConfigured = false
                await prepareAudioSession()
                guard isCurrent(epoch) else { return false }
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

    /// Begins forwarding captured audio buffers to `onBuffer` for `run`.
    /// Starts a hot session on demand if one isn't already running, so deep
    /// links and other cold-start paths still work without a separate call.
    /// - Parameter onBuffer: Called on the audio render thread with each
    ///   captured buffer. Must be lightweight — enqueue for processing elsewhere.
    /// - Returns: the run's capture lease, or nil when the engine did not come
    ///   up or `stopCapture(for: run)` revoked the claim while it was starting.
    func startCapture(
        for run: RunID,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async -> CaptureLease? {
        Logger.app.info("[LaunchProbe] startCapture entry isHot=\(self.isHot)")
        captureSink.claim(for: run)
        if !isHot, !(await startHotSession()) {
            Logger.recording.error("startCapture: startHotSession() failed")
            _ = captureSink.close(for: run)
            return nil
        }
        guard isHot, let lease = captureSink.open(for: run, handler: onBuffer) else {
            Logger.recording.warning("startCapture: the run let go of the capture while the engine started")
            _ = captureSink.close(for: run)
            return nil
        }
        isRecording = true
        Logger.recording.info("Capture started (isHot=\(self.isHot))")
        return lease
    }

    // MARK: - Engine Lifecycle

    /// Starts the audio engine, reusing the prepared one when there is one.
    /// The blocking `engine.start()` runs on a background QoS queue so it
    /// does not stall MainActor. Does NOT open a capture — hot-session
    /// startup runs with no run holding the capture.
    private func startEngine() async -> Bool {
        let started = await engineSlot.start(
            building: { [weak self] in await self?.buildEngine() },
            starting: Self.startEngineOffMain
        )
        if started { Logger.recording.info("Audio engine started") }
        return started
    }

    /// Runs `engine.start()` on a `.userInitiated` background task so MainActor
    /// stays free. AVAudioEngine.start() is thread-safe per Apple's audio framework docs.
    private nonisolated static func startEngineOffMain(_ engine: AVAudioEngine) async -> Bool {
        // `engine.start()` blocks on the audio HAL — keep it off the cooperative
        // pool so it can't stall the main actor under concurrent CoreML load.
        await withBlockingTask(qos: .userInitiated) {
            do {
                try engine.start()
                return true
            } catch {
                Logger.recording.error("engine.start failed: \(error)")
                return false
            }
        }
    }

    /// Tears down the current engine and starts a fresh one on the new audio route.
    /// Called when the audio route changes while the hot session is up (which
    /// includes any active recording).
    private func restartEngine() async {
        guard engineSlot.engine != nil else { return }
        engineSlot.release()

        applyPreferredInput()

        if await startEngine() {
            Logger.recording.info("Audio engine restarted after route change")
        } else {
            Logger.recording.error("Failed to restart audio engine after route change")
            loseEngine(reason: "The microphone stopped after an audio route change")
            deactivateSession()
        }
    }

    /// The engine stopped without a teardown. The run it cut, and the Hot
    /// Mic Session, hear of it through `engineLosses()`.
    private func loseEngine(reason: String) {
        let cut = captureSink.closeAll()
        isRecording = false
        audioLevels = Array(repeating: 0, count: Self.levelSampleCount)
        engineLossFeed.send(EngineLoss(lease: cut, reason: reason))
    }

    /// Every engine loss from now on. Each call returns its own stream.
    func engineLosses() -> AsyncStream<EngineLoss> {
        engineLossFeed.stream()
    }

    private func requestRouteRestart() {
        if routeRestartTask != nil {
            routeRestartPending = true
            return
        }

        routeRestartTask = Task { [weak self] in
            await self?.runRouteRestartWorker()
        }
    }

    private func runRouteRestartWorker() async {
        repeat {
            routeRestartPending = false
            await restartEngine()
        } while routeRestartPending
        routeRestartTask = nil
    }

    /// Stops consuming audio buffers but leaves the engine running so the
    /// next capture starts immediately. Use `endHotSession()` to fully
    /// release the microphone.
    /// No-op for a run that holds no capture; revokes the claim of a run
    /// whose capture is still starting.
    func stopCapture(for run: RunID) {
        guard let tally = captureSink.close(for: run) else { return }
        isRecording = false
        audioLevels = Array(repeating: 0, count: Self.levelSampleCount)
        // Emitted on every run, not only failing ones: an empty transcript is
        // only readable against the shape of runs that worked. Zero buffers
        // means the tap never fired; buffers with a near-zero peak means the
        // mic delivered silence; a healthy peak here moves the suspicion
        // downstream, to what the transcriber consumed.
        Logger.recording.info("Capture stopped (hot session alive) — \(tally.summary)")
    }

    /// Fully ends the hot session: removes the tap, stops the engine, drops the
    /// mic indicator, and deactivates the audio session so other audio apps can
    /// take over. We deactivate with `.notifyOthersOnDeactivation` so a media
    /// app we interrupted — or one the user wants to start while we sit idle —
    /// resumes instead of staying paused until VCDR is force-quit. The next
    /// record tap re-prepares the session, paying ~50-200ms activation, an
    /// acceptable cost for not holding system audio hostage between recordings.
    /// Throws if the audio session could not be deactivated. The engine-side
    /// teardown (tap removal, engine stop, state reset) always completes first,
    /// so a thrown error means a *partial* release: the mic indicator is down
    /// but the session deactivation didn't take. `HotMicSession` treats this as
    /// fail-closed — it withdraws readiness regardless and logs the trouble.
    func endHotSession() throws {
        let wasRunning = isHot

        hotSessionEpoch += 1
        startHotSessionTask = nil
        engineSlot.release()
        _ = captureSink.closeAll()
        isRecording = false
        audioLevels = Array(repeating: 0, count: Self.levelSampleCount)

        let releaseError = deactivateSession()

        Logger.recording.info("Hot audio session ended (engine was running: \(wasRunning))")

        if let releaseError { throw releaseError }
    }

    /// Deactivates the audio session and cleans up observers, returning the
    /// failure (if any) so callers can decide whether a partial release matters.
    /// `restartEngine()` uses it best-effort and ignores the result; `endHotSession()`
    /// propagates it so the Hot Mic Session can fail closed.
    @discardableResult
    func deactivateSession() -> (any Error)? {
        guard audioSessionConfigured else { return nil }
        var releaseError: (any Error)?
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Logger.recording.warning("Failed to deactivate audio session: \(error)")
            releaseError = error
        }
        audioSessionConfigured = false
        removeInterruptionObservers()
        Logger.recording.info("Audio session deactivated")
        return releaseError
    }

    // MARK: - Level Metering

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
            // the audio session. Drop our engine AND reset the configured
            // flag so the next start path re-activates the session cleanly.
            Logger.recording.warning("Audio session interrupted — dropping engine reference (was isHot=\(self.isHot), isRecording=\(self.isRecording))")
            engineSlot.release()
            audioSessionConfigured = false
            loseEngine(reason: "Audio was interrupted")

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
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange:
            // Device/route change — restart engine to re-apply input and pick up new format.
            requestRouteRestart()
        case .override:
            // Produced by our own speaker override in activateMixingSession().
            // Restarting for it creates a self-sustaining route-change loop.
            Logger.recording.debug("Ignoring speaker-output override route notification")
        default:
            break
        }
    }
}
