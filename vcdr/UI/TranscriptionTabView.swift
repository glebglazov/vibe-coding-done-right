import SwiftUI

struct TranscriptionTabView: View {
    let settings: AppSettings
    let isTranscriptionReady: Bool
    let initializationStatus: String

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
                        isReady: isTranscriptionReady,
                        statusText: initializationStatus
                    )
                }
            }

            Section("Pre-processing") {
                Toggle("Remove filler words (um, uh, etc.)", isOn: Binding(
                    get: { settings.removeFillerWords },
                    set: { settings.removeFillerWords = $0 }
                ))

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Append terminator template", isOn: Binding(
                        get: { settings.terminatorTemplateEnabled },
                        set: { settings.terminatorTemplateEnabled = $0 }
                    ))

                    if settings.terminatorTemplateEnabled {
                        TextField("Terminator template", text: Binding(
                            get: { settings.terminatorTemplate },
                            set: { settings.terminatorTemplate = $0 }
                        ))
                        .labelsHidden()
                        .help("Appended after transcription if it doesn't end with punctuation. Tokens: <dot>, <space>, <newline>.")
                    }
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
    // MARK: - Constants

    private static let dotSpacing: CGFloat = 6
    private static let dotSize: CGFloat = 8
    private static let badgeHPadding: CGFloat = 10
    private static let badgeVPadding: CGFloat = 4
    private static let badgeCornerRadius: CGFloat = 12

    let isReady: Bool
    let statusText: String

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
