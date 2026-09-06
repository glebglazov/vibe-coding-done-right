import SwiftUI

/// Chooses the Transcription Model that runs on this device, says what it is
/// doing, and offers whatever that model accepts being told.
struct TranscriptionSettingsSection: View {
    let coordinator: RecordingFlowCoordinator
    @AppStorage(TranscriptionSettings.modelSettingsKey)
    private var modelSettings = TranscriptionModelSettingsStore()
    @AppStorage(TranscriptionSettings.defaultModelKey)
    private var storedModel = TranscriptionSettings.defaultModel.rawValue

    private var model: TranscriptionModel {
        TranscriptionModel(rawValue: storedModel) ?? .parakeetV3
    }

    var body: some View {
        Section {
            Picker("Model", selection: $storedModel) {
                ForEach(TranscriptionProviderRegistry.offeredModels, id: \.self) { offered in
                    Text(offered.displayName).tag(offered.rawValue)
                }
            }
            TranscriptionStatusRow(coordinator: coordinator)
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
            Text("Transcription runs on this device. A model chosen here downloads the first time it records. The model and everything it is told are this device's own — neither is shared with your other devices.")
        }
    }
}

/// Reads Transcription Readiness inside its own body, so a phase tick redraws
/// this row alone rather than the whole Settings form — the same reason
/// `InitProgressLabel` exists on the recording screen.
private struct TranscriptionStatusRow: View {
    let coordinator: RecordingFlowCoordinator

    var body: some View {
        LabeledContent("Status", value: coordinator.initProgress)
    }
}
