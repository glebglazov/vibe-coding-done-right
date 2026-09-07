import SwiftUI

/// Chooses the Transcription Model that runs on this device, says what it is
/// doing, offers whatever that model accepts being told, and lists the Library
/// every model can be installed from and removed again.
struct TranscriptionSettingsSection: View {
    let coordinator: RecordingFlowCoordinator
    @AppStorage(TranscriptionSettings.modelSettingsKey)
    private var modelSettings = TranscriptionModelSettingsStore()
    @AppStorage(TranscriptionSettings.defaultModelKey)
    private var storedModel = TranscriptionSettings.defaultModel.rawValue

    private var model: TranscriptionModel {
        TranscriptionModel(rawValue: storedModel) ?? .parakeetV3
    }

    /// The one Library the app has, so a model preparing for a recording moves
    /// the row this screen shows for it.
    private var library: TranscriptionLibrary {
        coordinator.transcriptionLibrary
    }

    var body: some View {
        Group {
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
                    )
                )
            } header: {
                Text("Transcription")
            } footer: {
                Text("Transcription runs on this device. Choose from the models you have installed — the Library below is where models are installed and removed. The model and everything it is told are this device's own — neither is shared with your other devices.")
            }

            Section("Library") {
                LibraryRows(library: library)
            }
        }
        // Each visit re-reads the Library — which is also how a device that was
        // offline last time finally learns what it can install — and then keeps
        // watching, so a model preparing while Settings is open moves and
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
private struct LibraryRows: View {
    let library: TranscriptionLibrary

    var body: some View {
        ForEach(library.entries) { entry in
            TranscriptionLibraryRow(
                entry: entry,
                removalRefusal: library.removalRefusal(for: entry.model),
                install: { library.install(entry.model) },
                remove: { Task { await library.remove(entry.model) } }
            )
        }
    }
}
