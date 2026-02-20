import SwiftUI

struct TranscriptionTabView: View {
    let dependencies: AppDependencies

    var body: some View {
        Form {
            Section("Models") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Parakeet v3")
                            .font(.headline)
                        Text("Multilingual speech-to-text (CoreML)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    ModelStatusBadge(
                        isReady: dependencies.isTranscriptionReady,
                        statusText: dependencies.initializationStatus
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcription")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }
}

private struct ModelStatusBadge: View {
    let isReady: Bool
    let statusText: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(badgeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(badgeColor.opacity(0.1))
        .cornerRadius(12)
    }

    private var badgeColor: Color {
        if isReady { return .green }
        if statusText.hasPrefix("Failed") { return .red }
        return .gray
    }

    private var badgeText: String {
        if isReady { return "Ready" }
        if statusText.hasPrefix("Failed") { return "Error" }
        return statusText
    }
}
