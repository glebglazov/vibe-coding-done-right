import SwiftUI

struct RecordingView: View {
    @Bindable var coordinator: RecordingFlowCoordinator

    var body: some View {
        VStack(spacing: 32) {
            switch coordinator.state {
            case .idle, .initializing:
                ProgressView()
                Text(coordinator.initProgress)
                    .foregroundStyle(.secondary)

            case .ready:
                Text("Ready to record")
                    .font(.headline)
                Button("Start Recording") {
                    Task { await coordinator.startRecording() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .recording:
                WaveformView(levels: coordinator.audioLevels)
                    .frame(height: 60)
                Text("Recording...")
                    .font(.headline)
                Button("Stop & Transcribe") {
                    Task { await coordinator.stopAndTranscribe() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)

            case .transcribing:
                ProgressView()
                Text("Transcribing...")
                    .foregroundStyle(.secondary)

            case .complete(let text):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text(text)
                    .font(.body)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    Button("New Recording") {
                        Task { await coordinator.startRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                Button("Try Again") { coordinator.reset() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}
