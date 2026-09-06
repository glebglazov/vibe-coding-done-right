import SwiftUI

/// One Transcription Model's settings, built from what that model declares it
/// can be told. Nothing here is written per model: a model that declares a
/// Capability gets its control, and a model that declares none says why rather
/// than showing controls it would ignore.
struct TranscriptionModelSettingsView: View {

    // MARK: - Constants

    private static let promptLineLimit = 3
    private static let promptSpacing: CGFloat = 4

    let model: TranscriptionModel
    @Binding var settings: TranscriptionModelSettings

    var body: some View {
        switch model.capabilities {
        case .nothing(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .kinds(let capabilities):
            ForEach(capabilities, id: \.self) { control(for: $0) }
        }
    }

    @ViewBuilder
    private func control(for capability: TranscriptionModelCapability) -> some View {
        switch capability {
        case .languageHint: languageHint
        case .freeTextPrompt: freeTextPrompt
        }
    }

    private var languageHint: some View {
        LabeledContent {
            Picker("Language", selection: $settings.languageHint) {
                ForEach(LanguageHint.allCases, id: \.self) { hint in
                    Text(hint.displayName).tag(hint)
                }
            }
            .labelsHidden()
        } label: {
            Text("Language")
            // What choosing a language commits you to, said where the choice
            // is made: the failure it causes is a fluent transcript in the
            // wrong language, which nothing downstream can flag.
            Text("""
                Detect sends no language and lets the model decide. Choosing \
                one forces it, and speech in another language is then \
                translated into it rather than transcribed — with no error.
                """)
        }
    }

    private var freeTextPrompt: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: Self.promptSpacing) {
                TextField("Names and jargon", text: $settings.freeTextPrompt, axis: .vertical)
                    .lineLimit(Self.promptLineLimit, reservesSpace: true)
                Text("\(settings.freeTextPrompt.count)/\(TranscriptionModelSettings.freeTextPromptCharacterLimit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } label: {
            Text("Vocabulary Prompt")
            Text("""
                Proper nouns and jargon written here bias how the model spells \
                them. It is a hint the model may ignore, and a long one makes \
                it more likely to repeat itself.
                """)
        }
    }
}
