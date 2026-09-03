import SwiftUI

struct TranscriptionTabView: View {
    let settings: AppSettings
    let readiness: ModelReadiness

    var body: some View {
        Form {
            Section("Models") {
                LabeledContent {
                    ModelStatusBadge(readiness: readiness)
                } label: {
                    Text("Parakeet v3")
                    Text("Multilingual speech-to-text (CoreML)")
                }
            }

            Section("Pre-processing") {
                Toggle("Remove filler words (um, uh, etc.)", isOn: Binding(
                    get: { settings.removeFillerWords },
                    set: { settings.removeFillerWords = $0 }
                ))
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
    // MARK: - Constants

    private static let dotSpacing: CGFloat = 6
    private static let dotSize: CGFloat = 8
    private static let badgeHPadding: CGFloat = 10
    private static let badgeVPadding: CGFloat = 4
    private static let badgeCornerRadius: CGFloat = 12

    let readiness: ModelReadiness

    var body: some View {
        HStack(spacing: Self.dotSpacing) {
            Circle()
                .fill(badgeColor)
                .frame(width: Self.dotSize, height: Self.dotSize)
            Text(badgeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Self.badgeHPadding)
        .padding(.vertical, Self.badgeVPadding)
        .background(badgeColor.opacity(0.1))
        .cornerRadius(Self.badgeCornerRadius)
    }

    private var badgeColor: Color {
        switch readiness {
        case .ready: .green
        case .preparing: .gray
        case .failed: .red
        }
    }

    private var badgeText: String {
        switch readiness {
        case .ready: "Ready"
        case .preparing(let label): label
        case .failed: "Error"
        }
    }
}
