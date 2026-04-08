#if DEBUG

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Debug Tab View

struct DebugTabView: View {
    let session: CaptureSession
    let audioRecorder: AudioRecorder
    let isTranscriptionReady: Bool

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
                testRunner = DebugTestRunner(session: session)
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
                if let url = audioRecorder.testAudioFileURL {
                    Text(url.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Clear") {
                        audioRecorder.testAudioFileURL = nil
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
                    audioRecorder.testAudioFileURL = url
                }
            }

            LabeledContent("Coordinator State") {
                Text(stateLabel)
                    .foregroundStyle(stateColor)
            }

            LabeledContent("Model Ready") {
                Text(isTranscriptionReady ? "Yes" : "No")
                    .foregroundStyle(isTranscriptionReady ? .green : .orange)
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
        audioRecorder.testAudioFileURL != nil && isTranscriptionReady
    }

    private var stateLabel: String {
        switch session.status.phase {
        case .idle: "Idle"
        case .preparingToRecord: "Preparing..."
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .awaitingPreview: "Awaiting Preview"
        case .executing: "Executing"
        case .error(let msg): "Error: \(msg)"
        }
    }

    private var stateColor: Color {
        switch session.status.phase {
        case .idle: .green
        case .recording: .red
        case .preparingToRecord, .transcribing, .executing: .orange
        case .awaitingPreview: .blue
        case .error: .red
        }
    }
}

#endif
