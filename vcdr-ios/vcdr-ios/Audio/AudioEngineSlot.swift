import AVFoundation
import Foundation
import OSLog

/// What `AudioEngineSlot` needs from an engine. `AVAudioEngine` is the
/// production one; tests use a fake.
nonisolated protocol SlottableAudioEngine: AnyObject {
    var isRunning: Bool { get }
    /// Removes the input tap and stops the engine.
    func discard()
}

extension AVAudioEngine: SlottableAudioEngine {
    nonisolated func discard() {
        inputNode.removeTap(onBus: 0)
        stop()
    }
}

/// The one audio engine the recorder runs.
///
/// Building and starting an engine block for up to seconds off the main
/// actor, and a teardown can land meanwhile. Every build and start remembers
/// the slot's generation, and `release()` moves the generation on, so a build
/// or a start that lands after a teardown discards its engine instead of
/// keeping or running it. Concurrent callers join one in-flight build, so
/// exactly one engine is ever assigned (vcdr-ios ADR-0001).
@MainActor
final class AudioEngineSlot<Engine: SlottableAudioEngine> {
    private(set) var engine: Engine?
    private var generation: UInt64 = 0
    private var building: Task<Engine?, Never>?

    var isRunning: Bool { engine?.isRunning == true }

    /// The slot's engine, built by `build` when there is none. Nil when the
    /// build failed or a `release()` landed while it ran.
    func prepared(building build: @escaping () async -> Engine?) async -> Engine? {
        if let engine { return engine }
        if let building { return await building.value }
        let generation = self.generation
        let task = Task<Engine?, Never> { [weak self] in
            guard let built = await build() else { return nil }
            guard let self, self.generation == generation else {
                Logger.recording.info("Engine build landed after a teardown — discarding it")
                built.discard()
                return nil
            }
            self.engine = built
            return built
        }
        building = task
        let engine = await task.value
        if building == task { building = nil }
        return engine
    }

    /// Brings the slot's engine up, building it when needed. An engine that
    /// fails to start is discarded and rebuilt once, since it may be bound to
    /// a stale route. False when it still fails, or when a `release()` landed
    /// while it started.
    func start(
        building build: @escaping () async -> Engine?,
        starting start: @escaping (Engine) async -> Bool
    ) async -> Bool {
        switch await startOnce(building: build, starting: start) {
        case .running: return true
        case .unavailable: return false
        case .startFailed: break
        }
        Logger.recording.warning("Engine failed to start, rebuilding once")
        release()
        guard case .running = await startOnce(building: build, starting: start) else {
            Logger.recording.error("Rebuilt engine failed to start")
            release()
            return false
        }
        Logger.recording.info("Audio engine started (rebuilt)")
        return true
    }

    /// Drops the engine and invalidates every build and start in flight.
    func release() {
        generation += 1
        building = nil
        engine?.discard()
        engine = nil
    }

    /// `unavailable`: the build failed or a teardown overtook the start.
    private enum StartOutcome { case running, startFailed, unavailable }

    private func startOnce(
        building build: @escaping () async -> Engine?,
        starting start: @escaping (Engine) async -> Bool
    ) async -> StartOutcome {
        let generation = self.generation
        guard let engine = await prepared(building: build) else { return .unavailable }
        if engine.isRunning { return .running }
        let started = await start(engine)
        guard self.generation == generation, self.engine === engine else {
            Logger.recording.info("Engine start landed after a teardown — discarding it")
            if started { engine.discard() }
            return .unavailable
        }
        return started ? .running : .startFailed
    }
}
