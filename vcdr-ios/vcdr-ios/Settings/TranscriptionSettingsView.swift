import SwiftUI

/// The iPhone's own Transcription screen, matching the macOS Transcription tab
/// in name and in content: chooses the Transcription Model that runs on this
/// device, says what it is doing, offers whatever that model accepts being
/// told, and lists the Library every model can be installed from and removed
/// again.
struct TranscriptionSettingsView: View {
    let coordinator: RecordingFlowCoordinator
    @AppStorage(TranscriptionSettings.modelSettingsKey)
    private var modelSettings = TranscriptionModelSettingsStore()
    @AppStorage(TranscriptionSettings.defaultModelKey)
    private var storedModel = TranscriptionSettings.defaultModel.rawValue

    private var model: TranscriptionModel {
        TranscriptionModel(rawValue: storedModel) ?? .parakeetUltra
    }

    /// The one Library the app has, so a model preparing for a recording moves
    /// the row this screen shows for it.
    private var library: TranscriptionLibrary {
        coordinator.transcriptionLibrary
    }

    var body: some View {
        Form {
            Section {
                Picker("Default Model", selection: $storedModel) {
                    // The Installed Models, plus the one this setting already
                    // holds. Installing is the Library section below, where the
                    // cost and the progress are (`docs/adr/0023`).
                    ForEach(library.selectableModels(holding: model), id: \.self) { offered in
                        Text(offered.displayName).tag(offered.rawValue)
                    }
                }
                TranscriptionStatusRow(library: library, model: model)
                TranscriptionModelSettingsView(
                    family: model.family,
                    settings: Binding(
                        get: { modelSettings[model.family] },
                        set: { modelSettings[model.family] = $0 }
                    ),
                    spellingHints: SpellingHints(coordinator.substitutionStore.substitutions)
                )
                ForEach(AIPromptMode.allCases.reversed(), id: \.self) { mode in
                    ModeTranscriptionRow(mode: mode, coordinator: coordinator)
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Transcription runs on this device. Choose from the models you have installed — the Library below is where models are installed and removed. \"With AI On\" and \"With AI Off\" can pin another installed model. The model and everything it is told are this device's own — neither is shared with your other devices.")
            }

            LibrarySection(library: library)
        }
        .navigationTitle("Transcription")
        .navigationBarTitleDisplayMode(.inline)
        // Each visit re-reads the Library — which is also how a device that was
        // offline last time finally learns what it can install — and then keeps
        // watching, so a model preparing while this screen is open moves and
        // reaches ready without the screen being closed and reopened.
        .task { await library.watch() }
    }
}

/// Reads one model's state inside its own body, so a phase tick redraws this
/// row alone rather than the whole Settings form — the same reason
/// `InitProgressLabel` exists on the recording screen.
private struct TranscriptionStatusRow: View {
    let library: TranscriptionLibrary
    let model: TranscriptionModel

    var body: some View {
        LabeledContent("Status", value: library.entry(for: model).state.label(for: model))
    }
}

/// Reads the whole Library inside its own body, for the same reason the Status
/// row reads one model's state inside its own: a download ticking must not
/// re-evaluate the Settings form above it.
private struct LibrarySection: View {
    let library: TranscriptionLibrary

    /// The pinned removal awaiting consent, or nil when none is. A removal with
    /// nothing to disclose never lands here: it happens on the press
    /// (`docs/adr/0024`).
    @State private var pendingRemoval: PinnedModelRemoval?

    var body: some View {
        Section("Library") {
            ForEach(library.entries) { entry in
                TranscriptionLibraryRow(
                    entry: entry,
                    removalRefusal: library.removalRefusal(for: entry.model),
                    install: { library.install(entry.model) },
                    remove: { remove(entry.model) }
                )
            }
        }
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
    }

    /// Presses Remove: a model Prompt Modes pin discloses what agreeing costs
    /// them and waits, and a model nothing pins goes now.
    private func remove(_ model: TranscriptionModel) {
        if let removal = library.pinnedModelRemoval(for: model) {
            pendingRemoval = removal
        } else {
            Task { await library.remove(model) }
        }
    }
}
