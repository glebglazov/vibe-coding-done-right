import SwiftUI

/// Names the Transcription Model that runs on this device, says what it is
/// doing, and offers whatever that model accepts being told.
struct TranscriptionSettingsSection: View {
    let coordinator: RecordingFlowCoordinator
    @AppStorage(TranscriptionSettings.modelSettingsKey)
    private var modelSettings = TranscriptionModelSettingsStore()

    private var model: TranscriptionModel { TranscriptionSettings.defaultModel }

    var body: some View {
        Section {
            LabeledContent("Model", value: model.displayName)
            TranscriptionStatusRow(coordinator: coordinator)
            TranscriptionModelSettingsView(
                model: model,
                settings: Binding(
                    get: { modelSettings[model] },
                    set: { modelSettings[model] = $0 }
                )
            )
        } header: {
            Text("Transcription")
        } footer: {
            Text("Transcription runs on this device. The model and everything it is told are this device's own — neither is shared with your other devices.")
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
