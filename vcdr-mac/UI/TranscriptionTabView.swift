import SwiftUI

struct TranscriptionTabView: View {
    let settings: AppSettings
    let library: TranscriptionLibrary
    let readiness: ModelReadiness
    let retryPreparation: () -> Void
    /// Makes a model the Default Transcription Model. One that is not
    /// downloaded yet may be chosen — Status then narrates its preparation.
    let selectDefaultModel: (TranscriptionModel) -> Void

    var body: some View {
        Form {
            Section("Model") {
                Picker("Default Model", selection: Binding(
                    get: { settings.transcriptionSettings.defaultModel },
                    set: { selectDefaultModel($0) }
                )) {
                    ForEach(TranscriptionProviderRegistry.offeredModels, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                LabeledContent("Status") {
                    ModelStatusBadge(readiness: readiness)
                }

                if case .failed(let failure) = readiness {
                    LabeledContent {
                        Button("Try Again", action: retryPreparation)
                    } label: {
                        Text(failure.headline)
                        Text(failure.remedy)
                    }
                }
            }

            Section("Library") {
                ForEach(library.entries) { entry in
                    TranscriptionLibraryRow(
                        entry: entry,
                        removalRefusal: library.removalRefusal(for: entry.model),
                        install: { library.install(entry.model, urgency: .unawaited) },
                        remove: { Task { await library.remove(entry.model) } }
                    )
                }
            }

            // Only the family the Default belongs to: the settings on this
            // screen are the ones the next recording carries, so a family
            // that is not running has nothing to say here. Its values are
            // kept, not shown — making it the Default brings them back.
            Section("\(runningFamily.displayName) Settings") {
                TranscriptionModelSettingsView(
                    family: runningFamily,
                    settings: Binding(
                        get: { settings.transcriptionSettings.modelSettings[runningFamily] },
                        set: { settings.transcriptionSettings.modelSettings[runningFamily] = $0 }
                    )
                )
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
        // Each visit re-reads the Library — which is also how a device that
        // was offline last time finally learns what it can install — and then
        // keeps watching, so a model preparing while this screen is open moves
        // and reaches ready without the screen being closed and reopened.
        .task { await library.watch() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    /// The family the Default Transcription Model belongs to — the one whose
    /// settings this screen shows.
    private var runningFamily: TranscriptionModelFamily {
        settings.transcriptionSettings.defaultModel.family
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
        case .failed(let failure): failure.badge
        }
    }
}
