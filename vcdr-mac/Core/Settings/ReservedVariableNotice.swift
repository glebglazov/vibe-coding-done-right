import Foundation

/// The informational message shown inline under a Variables-screen row whose
/// name matches an AI Provider's Reserved key name (`ANTHROPIC_API_KEY`, …).
///
/// It explains the relationship between an explicit bash override and the
/// authoritative Provider key (see `docs/adr/0001-ai-provider-key-source-of-truth.md`).
/// AI calls always read the Provider key; a Reserved Variable only overrides the
/// value bash scripts see.
enum ReservedVariableNotice: Equatable {
    /// Override value equals the Provider key — the row is redundant.
    case duplicatesProviderKey(provider: AIProvider)
    /// Override value differs from the Provider key (and is non-empty) — bash only.
    case overridesBashOnly(provider: AIProvider)
    /// Override value is empty — no effect, falls back to the Provider key.
    case noEffect(provider: AIProvider)

    /// The user-facing message for this notice.
    var message: String {
        switch self {
        case let .duplicatesProviderKey(provider):
            "Duplicates the \(provider.displayName) key from Providers — safe to delete."
        case let .overridesBashOnly(provider):
            "Overrides `\(provider.apiKeyVariableName)` for bash scripts only; "
                + "AI calls still use the Providers key. Make sure that's intended."
        case .noEffect:
            "No effect — falls back to the Providers key."
        }
    }

    /// Whether this notice flags a potential surprise (warrants a warning style).
    /// Only a divergent override is a warning; duplicate / empty are informational.
    var isWarning: Bool {
        if case .overridesBashOnly = self { return true }
        return false
    }
}
