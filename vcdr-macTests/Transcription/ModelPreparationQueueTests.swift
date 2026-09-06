import Foundation
import Testing
@testable import vcdr_mac

@Suite("Model preparations take turns")
struct ModelPreparationQueueTests {

    @Test("Two models asked to prepare at the same time prepare one after the other")
    func preparesOneAtATime() async {
        let queue = ModelPreparationQueue()
        let log = PreparationLog()

        let first = preparation("first", urgency: .unawaited, on: queue, log: log)
        #expect(await log.eventually("first started"))

        let second = preparation("second", urgency: .unawaited, on: queue, log: log)
        #expect(await log.eventually("second held back"))
        #expect(await log.never("second started"))

        await log.release("first")
        #expect(await log.eventually("second started"))
        #expect(await log.entries == ["first started", "second held back", "first finished", "second started"])

        await log.release("second")
        _ = await first.result
        _ = await second.result
    }

    @Test("The model a recording is waiting on goes ahead of one nothing is waiting on")
    func awaitedPreparationOvertakes() async {
        let queue = ModelPreparationQueue()
        let log = PreparationLog()

        let running = preparation("running", urgency: .unawaited, on: queue, log: log)
        #expect(await log.eventually("running started"))
        let warming = preparation("warming", urgency: .unawaited, on: queue, log: log)
        #expect(await log.eventually("warming held back"))
        let recording = preparation("recording", urgency: .awaited, on: queue, log: log)
        #expect(await log.eventually("recording held back"))

        await log.release("running")

        #expect(await log.eventually("recording started"))
        #expect(await log.never("warming started"))

        await log.release("recording")
        #expect(await log.eventually("warming started"))
        await log.release("warming")
        _ = await running.result
        _ = await warming.result
        _ = await recording.result
    }

    @Test("A preparation that fails does not strand the ones queued behind it")
    func failureReleasesTheQueue() async {
        let queue = ModelPreparationQueue()
        let log = PreparationLog()

        let failing = preparation("failing", urgency: .unawaited, on: queue, log: log, ending: .failure)
        #expect(await log.eventually("failing started"))
        let next = preparation("next", urgency: .unawaited, on: queue, log: log)
        #expect(await log.eventually("next held back"))

        await log.release("failing")

        let outcome = await failing.result
        #expect(throws: TranscriptionError.self) { try outcome.get() }
        #expect(await log.eventually("next started"))
        await log.release("next")
        _ = await next.result
    }

    /// A preparation that starts, holds itself open until the test lets it go,
    /// and writes down every step it takes — the shape a real provider's
    /// download and load have, without the model.
    private func preparation(
        _ name: String,
        urgency: PreparationUrgency,
        on queue: ModelPreparationQueue,
        log: PreparationLog,
        ending: PreparationEnding = .success
    ) -> Task<Void, Error> {
        Task {
            try await queue.takingTurn(
                urgency: urgency,
                whileHeldBack: { await log.record("\(name) held back") }
            ) {
                await log.record("\(name) started")
                await log.waitForRelease(of: name)
                if case .failure = ending {
                    throw TranscriptionError.initializationFailed(.offline)
                }
                await log.record("\(name) finished")
            }
        }
    }
}

private enum PreparationEnding {
    case success
    case failure
}

/// What the preparations did and when, and the lever that ends each of them.
private actor PreparationLog {
    private(set) var entries: [String] = []
    private var released: Set<String> = []

    private static let settleTime: Duration = .milliseconds(200)
    private static let pollInterval: Duration = .milliseconds(10)
    private static let timeout: Duration = .seconds(2)

    func record(_ entry: String) {
        entries.append(entry)
    }

    func release(_ name: String) {
        released.insert(name)
    }

    func waitForRelease(of name: String) async {
        while !released.contains(name) {
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    func eventually(_ entry: String) async -> Bool {
        let start = ContinuousClock.now
        while start.duration(to: .now) < Self.timeout {
            if entries.contains(entry) { return true }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return false
    }

    /// That a step has not been taken, given long enough that it would have
    /// been — a queue that let two through at once fails here.
    func never(_ entry: String) async -> Bool {
        try? await Task.sleep(for: Self.settleTime)
        return !entries.contains(entry)
    }
}
