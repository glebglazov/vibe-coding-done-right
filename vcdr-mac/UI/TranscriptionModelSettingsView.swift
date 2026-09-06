import SwiftUI

/// Where the value in one settings control came from, and what can be done
/// about it. The effective settings a Mode records with are computed rather
/// than stored, so a Mode's screen has to account for every value it shows —
/// that provenance is the transparency the Override exists for.
enum TranscriptionSettingOrigin {
    /// The family's own settings screen: the value is the family's own, and
    /// there is nothing above it to have come from.
    case theFamilysOwn
    /// A Mode that has not set this: the value is the family's, and editing the
    /// family's own settings changes it here too.
    case inherited(from: TranscriptionModelFamily)
    /// A Mode that has set this for itself, and the way to give it back.
    case setByThisMode(useInherited: () -> Void)

    /// What the control says about where its value came from, or nil when there
    /// is nowhere else it could have come from.
    var label: String? {
        switch self {
        case .theFamilysOwn: nil
        case .inherited(let family): "From \(family.displayName) settings"
        case .setByThisMode: "Set by this Mode"
        }
    }
}

/// One Transcription Model Family's settings, built from what that family
/// declares it can be told. Nothing here is written per family: a family that
/// declares a Capability gets its control, and a family that declares none says
/// why rather than showing controls it would ignore.
struct TranscriptionModelSettingsView: View {

    // MARK: - Constants

    private static let promptLineLimit = 3
    private static let promptSpacing: CGFloat = 4

    let family: TranscriptionModelFamily
    @Binding var settings: TranscriptionModelSettings
    /// Where each value came from. The Transcription screen edits the family's
    /// own settings and says nothing; a Mode's screen edits a patch over them
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
                }
            } label: {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        VStack(alignment: .leading, spacing: Self.promptSpacing) {
            Text("Vocabulary Prompt")
            Text("""
                Proper nouns and jargon written here bias how the model spells \
                them. It is a hint the model may ignore, and a long one makes \
                it more likely to repeat itself.
                """)
            TextField("Names and jargon", text: $settings.freeTextPrompt, axis: .vertical)
                .lineLimit(Self.promptLineLimit, reservesSpace: true)
            Text("\(settings.freeTextPrompt.count)/\(TranscriptionModelSettings.freeTextPromptCharacterLimit)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
