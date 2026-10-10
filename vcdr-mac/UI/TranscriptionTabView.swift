import SwiftUI

struct TranscriptionTabView: View {
    let settings: AppSettings
    let library: TranscriptionLibrary
    let readiness: ModelReadiness
    let retryPreparation: () -> Void
    /// Makes a model the Default Transcription Model. Only an installed model
    /// can be chosen, so this costs a load and never a download; Status
    /// narrates that load.
    let selectDefaultModel: (TranscriptionModel) -> Void
    let spellingHints: SpellingHints

    /// The pinned removal awaiting consent, or nil when none is. A removal with
    /// nothing to disclose never lands here: it happens on the press
    /// (`docs/adr/0024`).
    @State private var pendingRemoval: PinnedModelRemoval?

    var body: some View {
        Form {
            Section("Model") {
                Picker("Default Model", selection: Binding(
                    get: { settings.transcriptionSettings.defaultModel },
                    set: { selectDefaultModel($0) }
                )) {
                    // The Installed Models, plus the one this setting already
                    // holds. Installing is the Library section below, where the
                    // cost and the progress are (`docs/adr/0023`).
                    ForEach(library.selectableModels(holding: runningModel), id: \.self) { model in
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

                // Only the family the Default belongs to: the settings on this
                // screen are the ones the next recording carries, so a family
                // that is not running has nothing to say here. Its values are
                // kept, not shown — making it the Default brings them back.
                TranscriptionModelSettingsView(
                    family: runningFamily,
                    settings: Binding(
                        get: { settings.transcriptionSettings.modelSettings[runningFamily] },
                        set: { settings.transcriptionSettings.modelSettings[runningFamily] = $0 }
                    ),
                    spellingHints: spellingHints
                )
            }

            Section("Library") {
                ForEach(library.entries) { entry in
                    TranscriptionLibraryRow(
                        entry: entry,
                        removalRefusal: library.removalRefusal(for: entry.model),
                        install: { library.install(entry.model, urgency: .unawaited) },
                        remove: { remove(entry.model) }
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
        // Each visit re-reads the Library — which is also how a device that
        // was offline last time finally learns what it can install — and then
        // keeps watching, so a model preparing while this screen is open moves
        // and reaches ready without the screen being closed and reopened.
        .task { await library.watch() }
        .confirmationDialog(
            "Remove this model?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if $0 == false { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { removal in
            Button("Remove and Unpin", role: .destructive) {
                Task { await library.remove(removal.model) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.disclosure)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    /// Presses Remove: a model Modes pin discloses what agreeing costs them and
    /// waits, and a model nothing pins goes now.
    private func remove(_ model: TranscriptionModel) {
        if let removal = library.pinnedModelRemoval(for: model) {
            pendingRemoval = removal
        } else {
            Task { await library.remove(model) }
        }
    }

    /// The Default Transcription Model — what the select holds and what the
    /// rest of this screen is about.
    private var runningModel: TranscriptionModel {
        settings.transcriptionSettings.defaultModel
    }

    /// The family the Default Transcription Model belongs to — the one whose
    /// settings this screen shows.
    private var runningFamily: TranscriptionModelFamily {
        runningModel.family
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
