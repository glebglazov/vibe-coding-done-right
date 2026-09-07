import SwiftUI

/// A Prompt Mode's Transcription Override: the model it records with, what that
/// model's family is told for this mode, and — because the effective settings
/// are computed — where each of those values came from.
struct ModeTranscriptionSection: View {
    @Binding var override: TranscriptionOverride
    /// Which models this phone has, so the select offers only those. Nothing is
    /// installed from this screen.
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
                // The Installed Models, plus whatever this Prompt Mode
                // already names. Naming a model here moves a pointer and spends
                // nothing, so there is no download to narrate and no Library row
                // to narrate it with (`docs/adr/0023`).
                ForEach(library.selectableModels(holding: override.model), id: \.self) { model in
                    Text(model.displayName).tag(TranscriptionModel?.some(model))
                }
            }

            if let model = override.model {
                TranscriptionModelSettingsView(
                    family: model.family,
                    settings: effectiveSettings(of: model.family),
                    origin: { origin(of: $0, for: model.family) }
                )
            }
        }
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
