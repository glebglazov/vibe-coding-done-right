import SwiftUI

/// The three ways this phone handles a recording. Each opens its own screen,
/// because a mode now says both what it does with the transcript and what
/// records it — Verbatim included, which does nothing with the transcript and
/// still has to record with something.
struct ModesView: View {
    let coordinator: RecordingFlowCoordinator

    var body: some View {
        Form {
            Section {
                ForEach(AIPromptMode.availableModes, id: \.self) { mode in
                    NavigationLink(mode.displayName) {
                        ModeSettingsView(mode: mode, coordinator: coordinator)
                    }
                }
            } footer: {
                Text("Each mode records with the Default Transcription Model unless it pins its own.")
            }
        }
        .navigationTitle("Modes")
        .navigationBarTitleDisplayMode(.inline)
    }
}
