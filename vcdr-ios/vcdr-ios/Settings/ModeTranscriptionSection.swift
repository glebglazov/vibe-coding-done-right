import SwiftUI

/// A Prompt Mode's Transcription Override: the model it records with, what that
/// model's family is told for this mode, and — because the effective settings
/// are computed — where each of those values came from.
struct ModeTranscriptionSection: View {
    @Binding var override: TranscriptionOverride
    /// Where a named model is installed from, and the state its row shows while
    /// that download runs.
    let library: TranscriptionLibrary
    @AppStorage(TranscriptionSettings.defaultModelKey)
    private var storedDefault = TranscriptionSettings.defaultModel.rawValue
    @AppStorage(TranscriptionSettings.modelSettingsKey)
    private var modelSettings = TranscriptionModelSettingsStore()

    var body: some View {
        Section("Transcription") {
            Picker("Model", selection: namedModel) {
                Text("Default (\(defaultModel.displayName))")
                    .tag(TranscriptionModel?.none)
                ForEach(TranscriptionProviderRegistry.offeredModels, id: \.self) { model in
                    Text(model.displayName).tag(TranscriptionModel?.some(model))
                }
            }

            if let model = override.model {
                // The same row the Library shows, because a model named here is
                // downloaded here: without progress a person watching a 627 MB
                // fetch has nothing to read. There is nowhere to remove a model
                // from on this screen — the Library owns that.
                TranscriptionLibraryRow(
                    entry: library.entry(for: model),
                    removalRefusal: nil,
                    install: { library.install(model) },
                    remove: nil
                )

                TranscriptionModelSettingsView(
                    family: model.family,
                    settings: effectiveSettings(of: model.family),
                    origin: { origin(of: $0, for: model.family) }
                )
            }
        }
        // A model may be named before it is here, and it downloads from the
        // moment it is named — the row above narrates that.
        .task { await library.watch() }
    }

    private var defaultModel: TranscriptionModel {
        TranscriptionModel(rawValue: storedDefault) ?? .parakeetV3
    }

    // MARK: - Naming a model

    private var namedModel: Binding<TranscriptionModel?> {
        Binding(
            get: { override.model },
            set: { override = library.override(override, naming: $0) }
        )
    }

    // MARK: - Settings, resolved and edited

    /// What this mode tells `family`: the family's own settings under this
    /// mode's patch. An edit lands as a patch of only what it changed, so
    /// everything the mode has not touched keeps following the family.
    private func effectiveSettings(of family: TranscriptionModelFamily) -> Binding<TranscriptionModelSettings> {
        Binding(
            get: { shownSettings(of: family) },
            set: { edited in
                var patch = override[family]
                patch.record(edited, replacing: shownSettings(of: family))
                override[family] = patch
            }
        )
    }

    private func shownSettings(of family: TranscriptionModelFamily) -> TranscriptionModelSettings {
        override[family].applied(to: modelSettings[family])
    }

    private func origin(
        of capability: TranscriptionModelCapability,
        for family: TranscriptionModelFamily
    ) -> TranscriptionSettingOrigin {
        guard override[family].isSet(capability) else { return .inherited(from: family) }
        return .setByThisMode {
            override[family].clear(capability)
        }
    }
}
