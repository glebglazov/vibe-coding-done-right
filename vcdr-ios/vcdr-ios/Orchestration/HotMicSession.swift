import Foundation
import OSLog

// MARK: - Seams

/// What `HotMicSession` drives on the warm audio engine. `AudioRecorder` is the
/// production adapter; tests use an in-memory fake. The session *drives* the
/// engine through this seam but never *owns* it — the recording path keeps
/// talking to `AudioRecorder` directly.
@MainActor
protocol WarmEngine: AnyObject {
    var isHot: Bool { get }
    var isRecording: Bool { get }
    var hasMicrophonePermission: Bool { get }
    func requestMicrophonePermission() async -> Bool
    func prepareAudioSession() async
    func prepareEngine() async
    func startHotSession() async -> Bool
    /// Fully releases the warm engine and audio session. Throws on a *partial*
    /// release (e.g. the audio session won't deactivate) after the engine-side
    /// teardown has already completed. The Hot Mic Session withdraws readiness
    /// regardless — see `teardown()`.
    func endHotSession() throws
}

/// Production recording + hot-mic engine. `AudioRecorder` is the adapter;
/// tests inject a spy that implements this seam and `RecordingAudioCapturing`.
@MainActor
protocol RecordingEngine: AnyObject, WarmEngine, RecordingAudioCapturing {
    var audioLevels: [Float] { get }
}

extension AudioRecorder: RecordingEngine {}

/// The lock-screen / Dynamic Island presence shown while the engine is warm,
/// giving the un-suppressable system mic indicator app identity.
/// `HotMicActivityController` is the production adapter; tests use a spy.
@MainActor
protocol MicPresence {
    /// Shows the presence. `deadline`, when non-nil, is the *Presence Deadline*:
    /// the wall-clock instant past which readiness must no longer be advertised.
    /// The adapter only reflects this deadline (e.g. as a Live Activity stale
    /// date) — it never computes timeout policy itself; that lives in the Hot
    /// Mic Session. `nil` means no inactivity deadline (`.always`, or while a
    /// recording is in progress).
    func start(deadline: Date?) async
    func stop() async
}

/// Suspends for a duration unless cancelled. Production sleeps on the real
/// clock; tests advance virtual time so idle-timeout transitions are
/// deterministic without real waits.
@MainActor
protocol HotMicClock {
    func sleep(for duration: Duration) async
}

struct SystemHotMicClock: HotMicClock {
    func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

extension HotMicActivityController: MicPresence {}

// MARK: - HotMicSession

/// The *Hot Mic Session*: the lifecycle of the app's warm audio engine. Owns the
/// heartbeat that tells the Keyboard Channel the app is reachable, the Live
/// Activity presence beside the system mic indicator, and the inactivity-timeout
/// state machine that tears the session down. It is a policy driver — it brings
/// the engine up and down through the `WarmEngine` seam but does not own the
/// engine itself.
///
/// All dependencies are in-process: each is injected so the timeout machine and
/// the `.never` / `.always` / finite policy behaviour are testable through this
/// interface with a fake clock and spies.
@MainActor
final class HotMicSession {
    private let engine: WarmEngine
    private let presence: MicPresence
    private let keyboard: any KeyboardChannelProtocol
    private let clock: HotMicClock
    private let policy: () -> HotSessionTimeout
    private let now: () -> Date

    /// Fires when the user has been idle for the configured timeout, tearing the
    /// session down. Cancelled while recording so long recordings never time
    /// out, and re-armed after every stop.
    private var idleTask: Task<Void, Never>?
    /// Wall-clock deadline for the current idle window. Persists across
    /// foreground/background transitions so the timer isn't reset each time
    /// the app returns to the foreground. Cleared when recording starts,
    /// when the session tears down, or when the policy changes.
    private var idleDeadline: Date?
    /// Periodic heartbeat loop. Runs only while the session is alive — if the app
    /// suspends, it pauses and the last-written timestamp ages out, signalling
    /// "dead" to the keyboard.
    private var heartbeatTask: Task<Void, Never>?
    /// Token for the UserDefaults-change observer that re-evaluates the live
    /// timer the moment the user picks a different timeout value.
    private var timeoutObserverToken: (any NSObjectProtocol)?

    /// Cadence for the app-alive heartbeat. Small enough that the keyboard's
    /// freshness threshold can be ~3x this without false negatives, large
    /// enough to keep write overhead negligible.
    private static let heartbeatInterval: Duration = .seconds(5)

    /// Single source of truth: the session is alive ⇔ the engine is running.
    var isAlive: Bool { engine.isHot }

    deinit {
        idleTask?.cancel()
        heartbeatTask?.cancel()
        if let timeoutObserverToken {
            NotificationCenter.default.removeObserver(timeoutObserverToken)
        }
    }

    /// Production dependencies default to the live adapters. They're passed as
    /// optionals so the defaults can be built inside this `@MainActor` init —
    /// default-argument expressions evaluate in a nonisolated context and so
    /// can't construct main-actor-isolated values directly.
    init(
        engine: WarmEngine,
        presence: MicPresence? = nil,
        keyboard: (any KeyboardChannelProtocol)? = nil,
        clock: HotMicClock? = nil,
        policy: (() -> HotSessionTimeout)? = nil,
        now: (() -> Date)? = nil
    ) {
        self.engine = engine
        self.presence = presence ?? HotMicActivityController()
        self.keyboard = keyboard ?? KeyboardChannel.live
        self.clock = clock ?? SystemHotMicClock()
        self.policy = policy ?? { HotSessionTimeout.current() }
        self.now = now ?? { Date() }
        installTimeoutObserver()
    }

    // MARK: - Interface

    /// Opportunistically prepares audio after Transcription Readiness without
    /// prompting. Explicit Record intent and opting into a warm timeout policy
    /// are the only paths allowed to request microphone permission.
    func prewarmIfPermitted() async {
        guard engine.hasMicrophonePermission else {
            Logger.app.info("HotMicSession.prewarmIfPermitted: skipping without microphone permission")
            return
        }
        await engine.prepareAudioSession()
        await engine.prepareEngine()
    }

    /// Brings the full session up per policy: warms the engine, lights the
    /// heartbeat and presence, and arms the inactivity timer. Idempotent — safe
    /// to call on every scene-active. Under `.never` it ensures nothing stays
    /// warm (tearing down if a prior policy left the engine hot).
    func start() async {
        let timeout = policy()
        guard timeout != .never else {
            if engine.isHot, !engine.isRecording { teardown() }
            return
        }
        guard await engine.startHotSession() else {
            Logger.app.error("HotMicSession.start: startHotSession() returned false")
            return
        }
        startHeartbeat()
        armIdleTimer(timeout)
    }

    /// Renews an already-authorized warm session during launch or foreground
    /// activation. Automatic lifecycle work must never trigger the system
    /// microphone permission prompt.
    func startIfPermitted() async {
        guard engine.hasMicrophonePermission else {
            Logger.app.info("HotMicSession.startIfPermitted: skipping without microphone permission")
            return
        }
        await start()
    }

    /// Re-arms lifecycle state for an engine that is already warm. Scene
    /// activation uses this narrow path so cold launch does not start audio
    /// work before Transcription Readiness.
    func renewIfAlive() async {
        guard engine.isHot else { return }
        await start()
    }

    /// Record intent has been acknowledged and the Recording Run is Arming.
    /// Protect an existing Hot Mic Session from expiring while the engine is
    /// starting, but do not create fresh Mic Presence for a cold engine.
    func recordIntentStarted() {
        guard engine.isHot else { return }
        idleTask?.cancel()
        idleTask = nil
    }

    /// Arming ended before Capturing. Resume the prior idle window if one was
    /// already alive; this is not Post-Capture Warmth and must not earn a fresh
    /// timeout.
    func recordIntentCancelledBeforeCapture() {
        armIdleTimer(policy())
    }

    /// Capturing has begun. Cancel the inactivity teardown so long recordings
    /// never time out, and make sure heartbeat and presence are lit — the cold
    /// record path warmed the engine via `startCapture` without going through
    /// `start()`.
    func recordingStarted() {
        guard engine.isHot else { return }
        idleTask?.cancel()
        idleTask = nil
        idleDeadline = nil
        startHeartbeat()
        // No Presence Deadline while recording — a long recording must not let
        // readiness go stale mid-capture; the timer re-arms on stop.
        Task { [presence] in await presence.start(deadline: nil) }
    }

    /// A recording has ended. Re-arm the inactivity timer per policy.
    func recordingStopped() {
        idleDeadline = nil  // fresh countdown from when recording actually stopped
        armIdleTimer(policy(), allowWhileRecording: true)
    }

    /// The timeout setting changed — re-evaluate the live timer immediately
    /// instead of waiting for the next stop.
    func policyChanged() async {
        idleDeadline = nil  // recalculate from now with the new duration
        let timeout = policy()
        guard engine.isHot else { return }
        armIdleTimer(timeout)
    }

    // MARK: - Idle-timeout state machine

    /// Starts, restarts, or clears the inactivity timer to match the current
    /// policy and engine state — the single place the idle-timeout machine
    /// lives.
    ///
    /// - `.never`: tear the session down now if idle (no timer scheduled).
    /// - `.always`: no timer — the session lives for the app lifetime (including
    ///   background, where the audio entitlement keeps it alive).
    /// - finite: sleep until the wall-clock deadline, then tear down if still idle.
    ///
    /// The deadline is a `Date` rather than a raw duration so that foreground
    /// re-entries (which call `start()` → `armIdleTimer`) use the *remaining*
    /// time instead of restarting the full window. Callers that represent a
    /// genuine new idle period (e.g. `recordingStopped`) clear `idleDeadline`
    /// before calling here; callers that are simply re-syncing state (e.g.
    /// `start()` on foreground return) leave it intact so the original expiry
    /// is honoured.
    ///
    /// If the engine isn't actually hot there is nothing to keep alive, so the
    /// heartbeat and presence are torn down too rather than left orphaned.
    private func armIdleTimer(_ timeout: HotSessionTimeout, allowWhileRecording: Bool = false) {
        idleTask?.cancel()
        idleTask = nil

        guard engine.isHot else {
            teardown()
            return
        }

        switch timeout {
        case .never:
            idleDeadline = nil
            if !engine.isRecording { teardown() }
            return
        case .always:
            // No inactivity Presence Deadline — readiness lives for the app
            // lifetime, so the presence carries no stale date.
            idleDeadline = nil
            Task { [presence] in await presence.start(deadline: nil) }
            return
        default:
            break
        }

        guard allowWhileRecording || !engine.isRecording else { return }

        let currentTime = now()
        if idleDeadline == nil {
            idleDeadline = currentTime.addingTimeInterval(TimeInterval(timeout.rawValue))
        }
        let deadline = idleDeadline!
        let remaining = deadline.timeIntervalSince(currentTime)

        guard remaining > 0 else {
            idleDeadline = nil
            teardown()
            Logger.app.info("Hot session expired while backgrounded — tearing down on foreground")
            return
        }

        // Hand the presence the same wall-clock deadline as the idle timer, so
        // readiness stops being advertised around the promised window even if
        // the app is backgrounded or suspended and the in-process timer below
        // never fires.
        Task { [presence, deadline] in await presence.start(deadline: deadline) }

        idleTask = Task { [weak self, clock] in
            await clock.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            guard self.engine.isHot, !self.engine.isRecording else { return }
            self.idleDeadline = nil
            self.teardown()
            Logger.app.info("Hot session auto-ended after \(timeout.rawValue)s inactivity")
        }
    }

    /// Brings the whole session down atomically: stops the engine, clears the
    /// heartbeat (so the keyboard falls back to its Deep-Link Fallback path), and
    /// ends the presence. Idempotent.
    ///
    /// Readiness Fail-Closed: audio release can report a partial failure (e.g.
    /// the audio session refuses to deactivate), but the user-visible readiness
    /// signals must come down regardless — VCDR must never keep advertising a
    /// warm mic it can no longer honor. So the Heartbeat and Mic Presence are
    /// cleared whether or not `endHotSession()` succeeds; a failed release is
    /// surfaced through diagnostics, not allowed to leave readiness visible.
    private func teardown() {
        idleTask?.cancel()
        idleTask = nil
        idleDeadline = nil
        do {
            try engine.endHotSession()
        } catch {
            Logger.app.error(
                "HotMicSession.teardown: audio release failed (\(error.localizedDescription)); withdrawing readiness anyway"
            )
        }
        stopHeartbeat()
        Task { [presence] in await presence.stop() }
    }

    // MARK: - Heartbeat

    /// Writes the current timestamp to the shared heartbeat key and starts a
    /// background loop refreshing it every `heartbeatInterval`. Safe to call
    /// repeatedly — only one loop runs at a time.
    private func startHeartbeat() {
        keyboard.writeHeartbeat(alive: true)
        guard heartbeatTask == nil else { return }
        // The periodic refresh sleeps on the real clock — the injected clock is
        // reserved for the idle-timeout machine, the part tests need to drive
        // deterministically. The freshness contract only cares about the
        // initial `alive: true` write (above) and the `alive: false` on stop.
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled, let self else { return }
                self.keyboard.writeHeartbeat(alive: true)
            }
        }
    }

    /// Cancels the periodic heartbeat and clears the shared timestamp so the
    /// keyboard falls back to the URL-launch path on its next Start tap.
    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        keyboard.writeHeartbeat(alive: false)
    }

    // MARK: - Policy observer

    /// Observes UserDefaults changes so a picker flip in Settings restarts the
    /// live timer with the new duration instead of waiting for the next stop.
    private func installTimeoutObserver() {
        timeoutObserverToken = NotificationCenter.default.addObserver(
            forName: HotSessionTimeout.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.policyChanged()
            }
        }
    }
}
