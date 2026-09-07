import SwiftUI

/// One Transcription Model Family's settings, built from what that family
/// declares it can be told. Nothing here is written per family: a family that
/// declares a Capability gets its control, and a family that declares none says
/// why rather than leaving the settings area blank.
struct TranscriptionModelSettingsView: View {

    // MARK: - Constants

    private static let promptLineLimit = 3
    private static let promptSpacing: CGFloat = 4

    let family: TranscriptionModelFamily
    @Binding var settings: TranscriptionModelSettings
    /// Where each value came from. The Transcription section edits the family's
    /// own settings and says nothing; a mode's screen edits a patch over them
    /// and accounts for every control.
    var origin: (TranscriptionModelCapability) -> TranscriptionSettingOrigin = { _ in .theFamilysOwn }

    var body: some View {
        switch family.capabilities {
        case .nothing(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .kinds(let capabilities):
            ForEach(capabilities, id: \.self) { capability in
                control(for: capability)
                originRow(for: capability)
            }
        }
    }

    @ViewBuilder
    private func control(for capability: TranscriptionModelCapability) -> some View {
        switch capability {
        case .languageHint: languageHint
        case .freeTextPrompt: freeTextPrompt
        }
    }

    @ViewBuilder
    private func originRow(for capability: TranscriptionModelCapability) -> some View {
        let origin = origin(capability)
        if let label = origin.label {
            LabeledContent {
                if case .setByThisMode(let useInherited) = origin {
                    Button("Use Inherited", action: useInherited)
                        .buttonStyle(.borderless)
                }
            } label: {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var languageHint: some View {
        VStack(alignment: .leading, spacing: Self.promptSpacing) {
            Picker("Language", selection: $settings.languageHint) {
                ForEach(LanguageHint.allCases, id: \.self) { hint in
                    Text(hint.displayName).tag(hint)
                }
            }
            // What choosing a language commits you to, said where the choice is
            // made: the failure it causes is a fluent transcript in the wrong
            // language, which nothing downstream can flag.
            Text("""
                Detect sends no language and lets the model decide. Choosing \
                one forces it, and speech in another language is then \
                translated into it rather than transcribed — with no error.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var freeTextPrompt: some View {
        VStack(alignment: .leading, spacing: Self.promptSpacing) {
            LabeledContent("Vocabulary Prompt") {
                Text("\(settings.freeTextPrompt.count)/\(TranscriptionModelSettings.freeTextPromptCharacterLimit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            TextField("Names and jargon", text: $settings.freeTextPrompt, axis: .vertical)
                .lineLimit(Self.promptLineLimit, reservesSpace: true)
            Text("""
                Proper nouns and jargon written here bias how the model spells \
                them. It is a hint the model may ignore, and a long one makes \
                it more likely to repeat itself.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
