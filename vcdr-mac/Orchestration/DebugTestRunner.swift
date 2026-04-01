#if DEBUG

import Foundation

// MARK: - Test Runner

@Observable
@MainActor
final class DebugTestRunner {

    // MARK: - Constants

    private static let statePollingInterval: Duration = .milliseconds(50)
    private static let interCycleDelay: Duration = .milliseconds(200)
    private static let cycleTimeout: Duration = .seconds(60)
    private static let testRecordingDuration: Duration = .milliseconds(100)

    // MARK: - Types

    enum Status: Equatable {
        case idle
        case running(scenario: String, iteration: Int, total: Int)
        case completed(iterations: Int, errors: Int)
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let elapsed: Duration
        let message: String
        let isError: Bool
    }

    // MARK: - State

    private(set) var status: Status = .idle
    private(set) var logEntries: [LogEntry] = []

    private let coordinator: RecordingCoordinator
    private var runTask: Task<Void, Never>?
    private var runStart: ContinuousClock.Instant = .now

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    init(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Controls

    func stop() {
        runTask?.cancel()
        runTask = nil
        coordinator.cancelRecording()
        status = .idle
        log("Stopped by user")
    }

    func clearLog() {
        logEntries = []
    }

    // MARK: - Scenarios

    func runSingleCycle() {
        run(name: "Single Cycle", total: 1) { [weak self] in
            guard let self else { return 0 }
            return await executeCycle(index: 0) ? 0 : 1
        }
    }

    func runStressLoop(iterations: Int) {
        run(name: "Stress Loop", total: iterations) { [weak self] in
            guard let self else { return 0 }
            var errors = 0
            for i in 0..<iterations {
                try Task.checkCancellation()
                status = .running(scenario: "Stress Loop", iteration: i + 1, total: iterations)
                if !(await executeCycle(index: i)) { errors += 1 }
                try? await Task.sleep(for: Self.interCycleDelay)
            }
            return errors
        }
    }

    func runCancelStorm(iterations: Int) {
        run(name: "Cancel Storm", total: iterations) { [weak self] in
            guard let self else { return 0 }
            var errors = 0
            for i in 0..<iterations {
                try Task.checkCancellation()
                status = .running(scenario: "Cancel Storm", iteration: i + 1, total: iterations)
                log("Cancel \(i + 1)/\(iterations)")
                coordinator.toggleRecording()
                let delay = Duration.milliseconds(Int.random(in: 10...200))
                try await Task.sleep(for: delay)
                coordinator.cancelRecording()
                if !(await waitForIdle()) {
                    log("Failed to reach idle (state: \(coordinator.state))", isError: true)
                    errors += 1
                }
                try? await Task.sleep(for: Self.interCycleDelay)
            }
            return errors
        }
    }

    // MARK: - Internals

    private func run(name: String, total: Int, body: @escaping @MainActor () async throws -> Int) {
        runTask?.cancel()
        logEntries = []
        runStart = .now
        status = .running(scenario: name, iteration: 1, total: total)
        log("Starting \(name)")

        runTask = Task { @MainActor in
            do {
                let errors = try await body()
                log("\(name) finished — \(total - errors)/\(total) passed")
                status = .completed(iterations: total, errors: errors)
            } catch is CancellationError {
                coordinator.cancelRecording()
                log("\(name) cancelled")
                status = .idle
            } catch {
                coordinator.cancelRecording()
                log("\(name) failed: \(error)", isError: true)
                status = .idle
            }
            runTask = nil
        }
    }

    private func executeCycle(index: Int) async -> Bool {
        let label = "Cycle \(index + 1)"
        log("\(label): starting")
        let cycleStart = ContinuousClock.now

        coordinator.toggleRecording()
        guard await waitForState({ $0 == .recording }) else {
            log("\(label): failed to reach recording (state: \(coordinator.state))", isError: true)
            _ = await waitForIdle()
            return false
        }

        try? await Task.sleep(for: Self.testRecordingDuration)

        coordinator.toggleRecording()

        guard await waitForIdle() else {
            log("\(label): timeout (state: \(coordinator.state))", isError: true)
            coordinator.cancelRecording()
            _ = await waitForIdle()
            return false
        }

        if case .error(let msg) = coordinator.state {
            log("\(label): error — \(msg)", isError: true)
            return false
        }

        let elapsed = cycleStart.duration(to: .now)
        log("\(label): done (\(elapsed.debugFormatted))")
        return true
    }

    private func waitForState(_ condition: @escaping (RecordingCoordinator.State) -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while start.duration(to: .now) < Self.cycleTimeout {
            if condition(coordinator.state) { return true }
            try? await Task.sleep(for: Self.statePollingInterval)
        }
        return false
    }

    private func waitForIdle() async -> Bool {
        await waitForState { state in
            if case .idle = state { return true }
            if case .error = state { return true }
            return false
        }
    }

    private func log(_ message: String, isError: Bool = false) {
        let elapsed = runStart.duration(to: .now)
        logEntries.append(LogEntry(elapsed: elapsed, message: message, isError: isError))
    }
}

// MARK: - Duration Formatting

extension Duration {
    var debugFormatted: String {
        let totalSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return String(format: "%7.3fs", totalSeconds)
    }
}

#endif
