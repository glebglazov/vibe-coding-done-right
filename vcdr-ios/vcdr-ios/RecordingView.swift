import SwiftUI

struct RecordingView: View {
    @Bindable var coordinator: RecordingFlowCoordinator
    @State private var showCopiedConfirmation = false
    @State private var isPulsing = false

    // MARK: - Constants
    private static let copiedConfirmationDuration: Duration = .seconds(3)

    var body: some View {
        VStack(spacing: 0) {
            // Pulsating hint pinned to top, right below the iOS "< Back to [App]" link
            if case .complete = coordinator.state {
                HStack {
                    Label("Tap above to return", systemImage: "arrow.up")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.blue, in: Capsule())
                        .scaleEffect(isPulsing ? 1.05 : 1.0)
                        .opacity(isPulsing ? 1.0 : 0.85)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
                        .onAppear { isPulsing = true }
                    Spacer()
                }
                .padding(.leading, 4)
                .padding(.top, 4)
            }

            Spacer()

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
                        showCopiedConfirmation = true
                        Task {
                            try? await Task.sleep(for: Self.copiedConfirmationDuration)
                            showCopiedConfirmation = false
                        }
                    } label: {
                        Label(showCopiedConfirmation ? "Copied!" : "Copy",
                              systemImage: showCopiedConfirmation ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .tint(showCopiedConfirmation ? .green : nil)
                    .animation(.easeInOut, value: showCopiedConfirmation)
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

            Spacer()
        }
    }
}
