import SwiftUI

/// A Mode's Transcription Override: the model it records with, what that
/// model's family is told for this Mode, and — because the effective settings
/// are computed — where each of those values came from.
struct ModeTranscriptionSection: View {
    @Binding var mode: Mode
    let settings: AppSettings
    /// Which models this Mac has, so the select offers only those. Nothing is
    /// installed from this screen.
    let library: TranscriptionLibrary

    var body: some View {
        Section("Transcription") {
            Picker("Model", selection: namedModel) {
                Text("Default (\(settings.transcriptionSettings.defaultModel.displayName))")
                    .tag(TranscriptionModel?.none)
                // The Installed Models, plus whatever this Mode already names.
                // Naming a model here moves a pointer and spends nothing, so
                // there is no download to narrate and no Library row to narrate
                // it with (`docs/adr/0023`).
                ForEach(library.selectableModels(holding: mode.transcriptionOverride.model), id: \.self) { model in
                    Text(model.displayName).tag(TranscriptionModel?.some(model))
                }
            }

            if let model = mode.transcriptionOverride.model {
                TranscriptionModelSettingsView(
                    family: model.family,
                    settings: effectiveSettings(of: model.family),
                    origin: { origin(of: $0, for: model.family) }
                )
            }
        }
    }

    // MARK: - Naming a model

    private var namedModel: Binding<TranscriptionModel?> {
        Binding(
            get: { mode.transcriptionOverride.model },
            set: { mode.transcriptionOverride = library.override(mode.transcriptionOverride, naming: $0) }
        )
    }

    // MARK: - Settings, resolved and edited

    /// What this Mode tells `family`: the family's own settings under this
    /// Mode's patch. An edit lands as a patch of only what it changed, so
    /// everything the Mode has not touched keeps following the family.
    private func effectiveSettings(of family: TranscriptionModelFamily) -> Binding<TranscriptionModelSettings> {
        Binding(
            get: { settings.transcriptionSettings.effectiveTranscription(for: mode).settings },
            set: { edited in
                let shown = settings.transcriptionSettings.effectiveTranscription(for: mode).settings
                var patch = mode.transcriptionOverride[family]
                patch.record(edited, replacing: shown)
                mode.transcriptionOverride[family] = patch
            }
        )
    }

    private func origin(
        of capability: TranscriptionModelCapability,
        for family: TranscriptionModelFamily
    ) -> TranscriptionSettingOrigin {
        guard mode.transcriptionOverride[family].isSet(capability) else { return .inherited(from: family) }
        return .setByThisMode {
            mode.transcriptionOverride[family].clear(capability)
        }
    }
}
