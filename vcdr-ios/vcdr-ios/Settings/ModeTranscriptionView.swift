import SwiftUI

/// The Transcription Model that one AI state records with, opened from the
/// "With AI On" and "With AI Off" rows of Settings › Transcription.
struct ModeTranscriptionView: View {
    let mode: AIPromptMode
    let coordinator: RecordingFlowCoordinator

    @AppStorage private var override: TranscriptionOverride

    init(mode: AIPromptMode, coordinator: RecordingFlowCoordinator) {
        self.mode = mode
        self.coordinator = coordinator
        _override = AppStorage(
            wrappedValue: TranscriptionOverride.none,
            TranscriptionSettings.modeOverrideKey(for: mode)
        )
    }

    var body: some View {
        Form {
            ModeTranscriptionSection(
                override: $override,
                library: coordinator.transcriptionLibrary,
                spellingHints: SpellingHints(coordinator.substitutionStore.substitutions)
            )
        }
        .navigationTitle(mode.pinRowTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The row that opens `ModeTranscriptionView` and names the model the AI
/// state pins. It observes the pin, so the name changes when the user returns.
struct ModeTranscriptionRow: View {
    let mode: AIPromptMode
    let coordinator: RecordingFlowCoordinator

    @AppStorage private var override: TranscriptionOverride

    init(mode: AIPromptMode, coordinator: RecordingFlowCoordinator) {
        self.mode = mode
        self.coordinator = coordinator
        _override = AppStorage(
            wrappedValue: TranscriptionOverride.none,
            TranscriptionSettings.modeOverrideKey(for: mode)
        )
    }

    var body: some View {
        NavigationLink {
            ModeTranscriptionView(mode: mode, coordinator: coordinator)
        } label: {
            LabeledContent(mode.pinRowTitle, value: override.model?.displayName ?? "Default")
        }
    }
}

extension AIPromptMode {
    var pinRowTitle: String {
        switch self {
        case .dictation: "With AI On"
        case .verbatim: "With AI Off"
        }
    }
}
