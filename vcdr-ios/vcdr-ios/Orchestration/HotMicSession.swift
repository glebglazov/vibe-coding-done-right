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
    func requestMicrophonePermission() async -> Bool
    func prepareAudioSession() async
    func prepareEngine() async
    func startHotSession() async -> Bool
    func endHotSession()
}

/// The lock-screen / Dynamic Island presence shown while the engine is warm,
/// giving the un-suppressable system mic indicator app identity.
/// `HotMicActivityController` is the production adapter; tests use a spy.
@MainActor
protocol MicPresence {
    func start(staleDate: Date?, autoEndAfter: Duration?) async
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

extension AudioRecorder: WarmEngine {}
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
    private let keyboard: KeyboardChannel
    private let clock: HotMicClock
    private let policy: () -> HotSessionTimeout

    /// Fires when the user has been idle for the configured timeout, tearing the
    /// session down. Cancelled while recording so long recordings never time
    /// out, and re-armed after every stop.
    private var idleTask: Task<Void, Never>?
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
        keyboard: KeyboardChannel? = nil,
        clock: HotMicClock? = nil,
        policy: (() -> HotSessionTimeout)? = nil
    ) {
        self.engine = engine
        self.presence = presence ?? HotMicActivityController()
        self.keyboard = keyboard ?? .live
        self.clock = clock ?? SystemHotMicClock()
        self.policy = policy ?? { HotSessionTimeout.current() }
        installTimeoutObserver()
    }

    // MARK: - Interface

    /// Gets the engine ready per policy, meant to run concurrently with model
    /// init. Resolves mic permission and pre-allocates the engine so the first
    /// record tap skips the audio-HAL cold-start. Under `.never` it stops there:
    /// the engine is *prepared* but NOT *started*, so no mic indicator appears
    /// until an actual recording — honouring `.never`'s contract. Any other
    /// policy warms the engine. Heartbeat and presence are deliberately left to
    /// `start()`, which the caller defers until after model init.
    func prewarm() async {
        _ = await engine.requestMicrophonePermission()
        await engine.prepareAudioSession()
        await engine.prepareEngine()
        guard policy() != .never else {
            Logger.app.info("HotMicSession.prewarm: timeout is .never — prepared engine, not warming")
            return
        }
        _ = await engine.startHotSession()
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

    /// A recording has begun. Cancel the inactivity teardown so long recordings
    /// never time out, and make sure heartbeat and presence are lit — the cold
    /// record path warms the engine via `startCapture` without going through
    /// `start()`.
    func recordingStarted() {
        idleTask?.cancel()
        idleTask = nil
        startHeartbeat()
        Task { [presence] in await presence.start(staleDate: nil, autoEndAfter: nil) }
    }

    /// A recording has ended. Re-arm the inactivity timer per policy.
    func recordingStopped() {
        armIdleTimer(policy())
    }

    /// The timeout setting changed — re-evaluate the live timer immediately
    /// instead of waiting for the next stop.
    func policyChanged() {
        armIdleTimer(policy())
    }

    // MARK: - Idle-timeout state machine

    /// Starts, restarts, or clears the inactivity timer to match the current
    /// policy and engine state — the single place the idle-timeout machine
    /// lives.
    ///
    /// - `.never`: tear the session down now if idle (no timer scheduled).
    /// - `.always`: no timer — the session lives for the app lifetime (including
    ///   background, where the audio entitlement keeps it alive).
    /// - finite: sleep N seconds, then tear down if still idle.
    ///
    /// If the engine isn't actually hot there is nothing to keep alive, so the
    /// heartbeat and presence are torn down too rather than left orphaned.
    private func armIdleTimer(_ timeout: HotSessionTimeout) {
        idleTask?.cancel()
        idleTask = nil

        guard engine.isHot else {
            teardown()
            return
        }

        switch timeout {
        case .never:
            if !engine.isRecording { teardown() }
            return
        case .always:
            Task { [presence] in await presence.start(staleDate: nil, autoEndAfter: nil) }
            return
        default:
            break
        }

        guard !engine.isRecording else { return }

        let staleDate = Date(timeIntervalSinceNow: timeout.seconds)
        Task { [presence] in
            await presence.start(
                staleDate: staleDate,
                autoEndAfter: .seconds(timeout.rawValue)
            )
        }

        idleTask = Task { [weak self, clock] in
            await clock.sleep(for: .seconds(timeout.rawValue))
            guard !Task.isCancelled, let self else { return }
            guard self.engine.isHot, !self.engine.isRecording else { return }
            self.teardown()
            Logger.app.info("Hot session auto-ended after \(timeout.rawValue)s inactivity")
        }
    }

    /// Brings the whole session down atomically: stops the engine, clears the
    /// heartbeat (so the keyboard falls back to its URL-launch path), and ends
    /// the presence. Idempotent.
    private func teardown() {
        idleTask?.cancel()
        idleTask = nil
        engine.endHotSession()
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
                self?.policyChanged()
            }
        }
    }
}
