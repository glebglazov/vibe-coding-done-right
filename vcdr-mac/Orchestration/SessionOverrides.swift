import Foundation

/// Manages parameter, destination, and style overrides for the current session.
/// Shared between `CaptureSession`, `ModeSwitcherCoordinator`,
/// `RecordingIndicatorPanel`, and `StyleResolutionPipeline` — the set → consume → clear-on-next lifecycle
/// is driven by `CaptureSession`.
@Observable
@MainActor
final class SessionOverrides {
    /// Parameter value overrides keyed by parameter ID -> selected option value string.
    var parameterOverrides: [UUID: String] = [:]

    /// Output destination override; nil means use mode default.
    var destinationOverride: UUID?

    /// Style override; nil means use frontmost-app-resolved style.
    /// Temporary style selection from menu bar or style switcher.
    var styleOverride: UUID?


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

    /// Mark that a pipeline completed.
    /// Destination override is cleared immediately — it's per-recording only,
    /// and leaving it set would show stale state in the mode switcher between recordings.
    func markPipelineCompleted() {
        destinationOverride = nil
    }

    /// Clear all overrides immediately (e.g. on cancel).
    func clearAll() {
        parameterOverrides = [:]
        destinationOverride = nil
        styleOverride = nil
    }

    /// Clears only the style override.
    func clearStyleOverride() {
        styleOverride = nil
    }
}
