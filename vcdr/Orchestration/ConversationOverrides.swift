import Foundation

/// Manages parameter and destination overrides for the current conversation.
/// Shared between RecordingCoordinator and PushToTypeCoordinator so both
/// participate in the same override lifecycle: set → consume → clear-on-next.
@Observable
@MainActor
final class ConversationOverrides {
    /// Parameter value overrides keyed by parameter ID -> selected option value string.
    var parameterOverrides: [UUID: String] = [:]

    /// Output destination override; nil means use mode default.
    var destinationOverride: UUID?

    /// Whether a pipeline has completed with active overrides.
    /// Used to clear overrides on the next fresh input.
    private var hasCompletedWithOverrides = false

    // MARK: - Resolution

    /// Resolves the effective output destination ID: override if set, otherwise mode default.
    func resolvedDestinationID(for mode: Mode) -> UUID {
        destinationOverride ?? mode.defaultOutputDestinationID
    }

    /// Resolves parameter values for a mode: overrides take precedence, then defaults.
    func resolvedParameterValues(for mode: Mode) -> [String: String] {
        var result: [String: String] = [:]
        for parameter in mode.parameters {
            let suffix = parameter.environmentVariableSuffix
            guard !suffix.isEmpty else { continue }
            if let override = parameterOverrides[parameter.id] {
                result[suffix] = override
            } else {
                result[suffix] = parameter.options.first?.value ?? ""
            }
        }
        return result
    }

    /// Resolves parameter labels for display (e.g. "Sonnet, English"). Returns nil if no parameters.
    func resolvedParameterLabels(for mode: Mode) -> String? {
        let labels = mode.parameters.compactMap { param -> String? in
            guard !param.options.isEmpty else { return nil }
            if let override = parameterOverrides[param.id],
               let option = param.options.first(where: { $0.value == override }) {
                return option.label
            }
            return param.options.first?.label
        }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    // MARK: - Lifecycle

    /// Mark that a pipeline completed with active overrides.
    /// The next fresh input will clear them.
    func markPipelineCompleted() {
        if !parameterOverrides.isEmpty || destinationOverride != nil {
            hasCompletedWithOverrides = true
        }
    }

    /// Clear overrides if a previous pipeline completed with them active.
    /// Called at the start of fresh input (recording or push-to-type).
    func clearIfCompletedPipeline() {
        guard hasCompletedWithOverrides else { return }
        parameterOverrides = [:]
        destinationOverride = nil
        hasCompletedWithOverrides = false
    }

    /// Clear all overrides immediately (e.g. on cancel).
    func clearAll() {
        parameterOverrides = [:]
        destinationOverride = nil
        hasCompletedWithOverrides = false
    }
}
