import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("AudioEngineSlot")
struct AudioEngineSlotTests {
    @Test("a build that lands after a teardown is discarded, not kept")
    func buildAfterReleaseIsDiscarded() async {
        let slot = AudioEngineSlot<FakeSlotEngine>()
        let build = EngineBuildGate()

        let prepared = Task { await slot.prepared(building: build.wait) }
        await waitUntil { build.isWaiting }
        slot.release()
        let engine = build.finish()

        #expect(await prepared.value == nil)
        #expect(slot.engine == nil)
        #expect(engine.wasDiscarded)
    }

    @Test("a start that lands after a teardown stops its engine")
    func startAfterReleaseStopsTheEngine() async {
        let slot = AudioEngineSlot<FakeSlotEngine>()
        let engine = FakeSlotEngine()
        let startGate = EngineStartGate()

        let started = Task {
            await slot.start(building: { engine }, starting: startGate.wait)
        }
        await waitUntil { startGate.isWaiting }
        slot.release()
        startGate.finish(started: true)

        #expect(await started.value == false)
        #expect(!slot.isRunning)
        #expect(!engine.isRunning)
    }

    @Test("callers during one build share one engine")
    func concurrentCallersShareOneBuild() async {
        let slot = AudioEngineSlot<FakeSlotEngine>()
        let build = EngineBuildGate()

        let first = Task { await slot.prepared(building: build.wait) }
        await waitUntil { build.isWaiting }
        let second = Task { await slot.prepared(building: { FakeSlotEngine() }) }
        await Task.yield()
        let engine = build.finish()

        #expect(await first.value === engine)
        #expect(await second.value === engine)
        #expect(slot.engine === engine)
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        await Task.yield()
    }
}

private nonisolated final class FakeSlotEngine: SlottableAudioEngine {
    private(set) var isRunning = false
    private(set) var wasDiscarded = false

    func run() { isRunning = true }

    func discard() {
        wasDiscarded = true
        isRunning = false
    }
}

/// Holds an engine build open until the test lets it land.
@MainActor
private final class EngineBuildGate {
    private var continuation: CheckedContinuation<FakeSlotEngine?, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async -> FakeSlotEngine? {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() -> FakeSlotEngine {
        let engine = FakeSlotEngine()
        continuation?.resume(returning: engine)
        continuation = nil
        return engine
    }
}

/// Holds `engine.start()` open until the test lets it return.
@MainActor
private final class EngineStartGate {
    private var pending: (engine: FakeSlotEngine, continuation: CheckedContinuation<Bool, Never>)?
    var isWaiting: Bool { pending != nil }

    func wait(_ engine: FakeSlotEngine) async -> Bool {
        await withCheckedContinuation { pending = (engine, $0) }
    }

    func finish(started: Bool) {
        guard let pending else { return }
        if started { pending.engine.run() }
        pending.continuation.resume(returning: started)
        self.pending = nil
    }
}
