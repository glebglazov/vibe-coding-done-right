#if DEBUG

import SwiftUI
import UniformTypeIdentifiers
import OSLog

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

// MARK: - Debug Tab View

struct DebugTabView: View {
    let dependencies: AppDependencies

    @State private var testRunner: DebugTestRunner?
    @State private var showingFilePicker = false
    @State private var loopIterations = 10
    @State private var cancelStormIterations = 50

    // MARK: - Constants

    private static let iterationRange = 1...1000
    private static let logFrameHeight: CGFloat = 250
    private static let elapsedColumnWidth: CGFloat = 70
    private static let iterationFieldWidth: CGFloat = 50

    var body: some View {
        Form {
            configurationSection
            scenariosSection
            logSection
        }
        .formStyle(.grouped)
        .navigationTitle("Debug")
        .onAppear {
            if testRunner == nil {
                testRunner = DebugTestRunner(coordinator: dependencies.coordinator)
            }
        }
    }

    // MARK: - Configuration

    @ViewBuilder
    private var configurationSection: some View {
        Section("Configuration") {
            HStack {
                Text("Test Audio File")
                Spacer()
                if let url = dependencies.audioRecorder.testAudioFileURL {
                    Text(url.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Clear") {
                        dependencies.audioRecorder.testAudioFileURL = nil
                    }
                } else {
                    Text("None selected")
                        .foregroundStyle(.tertiary)
                }
                Button("Select WAV...") {
                    showingFilePicker = true
                }
            }
            .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.wav, .audio]) { result in
                if case .success(let url) = result {
                    _ = url.startAccessingSecurityScopedResource()
                    dependencies.audioRecorder.testAudioFileURL = url
                }
            }

            LabeledContent("Coordinator State") {
                Text(stateLabel)
                    .foregroundStyle(stateColor)
            }

            LabeledContent("Model Ready") {
                Text(dependencies.isTranscriptionReady ? "Yes" : "No")
                    .foregroundStyle(dependencies.isTranscriptionReady ? .green : .orange)
            }

            if !canRun {
                Text("Select a WAV file and wait for the model to load before running scenarios.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Scenarios

    @ViewBuilder
    private var scenariosSection: some View {
        Section("Scenarios") {
            scenarioRow(
                title: "Single Cycle",
                description: "One full recording → transcription cycle"
            ) {
                testRunner?.runSingleCycle()
            }

            scenarioRow(
                title: "Stress Loop",
                description: "Repeat single cycle sequentially",
                iterations: $loopIterations
            ) {
                testRunner?.runStressLoop(iterations: loopIterations)
            }

            scenarioRow(
                title: "Cancel Storm",
                description: "Rapidly start then cancel recordings",
                iterations: $cancelStormIterations
            ) {
                testRunner?.runCancelStorm(iterations: cancelStormIterations)
            }

            statusRow
        }
    }

    @ViewBuilder
    private func scenarioRow(
        title: String,
        description: String,
        iterations: Binding<Int>? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let iterations {
                TextField("", value: iterations, format: .number)
                    .frame(width: Self.iterationFieldWidth)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: iterations, in: Self.iterationRange)
                    .labelsHidden()
            }
            Button("Run", action: action)
                .disabled(!canRun || (testRunner?.isRunning ?? false))
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if let testRunner {
            switch testRunner.status {
            case .idle:
                EmptyView()
            case .running(let scenario, let iteration, let total):
                HStack {
                    ProgressView(value: Double(iteration), total: Double(total))
                    Text("\(scenario): \(iteration)/\(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { testRunner.stop() }
                        .tint(.red)
                }
            case .completed(let iterations, let errors):
                HStack {
                    if errors == 0 {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("All \(iterations) iterations passed")
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("\(iterations - errors)/\(iterations) passed, \(errors) errors")
                    }
                }
            }
        }
    }

    // MARK: - Log

    @ViewBuilder
    private var logSection: some View {
        Section {
            if let entries = testRunner?.logEntries, !entries.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(entries) { entry in
                                HStack(alignment: .top, spacing: 4) {
                                    Text(entry.elapsed.debugFormatted)
                                        .frame(width: Self.elapsedColumnWidth, alignment: .trailing)
                                        .foregroundStyle(.secondary)
                                    Text(entry.message)
                                        .foregroundStyle(entry.isError ? .red : .primary)
                                }
                                .font(.system(.caption, design: .monospaced))
                                .id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(height: Self.logFrameHeight)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: entries.count) {
                        if let last = entries.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            } else {
                Text("Run a scenario to see log output here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            HStack {
                Text("Log")
                Spacer()
                if let testRunner, !testRunner.logEntries.isEmpty {
                    Button("Clear") { testRunner.clearLog() }
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Helpers

    private var canRun: Bool {
        dependencies.audioRecorder.testAudioFileURL != nil && dependencies.isTranscriptionReady
    }

    private var stateLabel: String {
        switch dependencies.coordinator.state {
        case .idle: "Idle"
        case .preparingToRecord: "Preparing..."
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .error(let msg): "Error: \(msg)"
        }
    }

    private var stateColor: Color {
        switch dependencies.coordinator.state {
        case .idle: .green
        case .recording: .red
        case .preparingToRecord, .transcribing: .orange
        case .error: .red
        }
    }
}

// MARK: - Duration Formatting

private extension Duration {
    var debugFormatted: String {
        let totalSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return String(format: "%7.3fs", totalSeconds)
    }
}

#endif
