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
                        install: { library.install(entry.model) },
                        remove: { Task { await library.remove(entry.model) } }
                    )
                }
            }

            // A section per model rather than one for the Default: the
            // settings belong to the model, so they stay readable while
            // another model is the one that runs.
            ForEach(TranscriptionProviderRegistry.offeredModels, id: \.self) { model in
                Section("\(model.displayName) Settings") {
                    TranscriptionModelSettingsView(
                        model: model,
                        settings: Binding(
                            get: { settings.transcriptionSettings.modelSettings[model] },
                            set: { settings.transcriptionSettings.modelSettings[model] = $0 }
                        )
                    )
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
        // Each visit re-reads the Library, which is also how a device that was
        // offline last time finally learns what it can install.
        .task { await library.refresh() }
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
        case .failed(let failure): failure.badge
        }
    }
}
