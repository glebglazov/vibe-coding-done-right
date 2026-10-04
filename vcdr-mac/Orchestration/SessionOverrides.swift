import Foundation

/// Manages parameter and destination overrides for the current Capture Session.
/// Shared between `CaptureSession`, `ModeSwitcherCoordinator`, and
/// `RecordingIndicatorPanel` — the set → consume → clear lifecycle
/// is driven by `CaptureSession`.
@Observable
@MainActor
final class SessionOverrides {
    /// Parameter value overrides keyed by parameter ID -> selected option value string.
    var parameterOverrides: [UUID: String] = [:]

    /// Output destination override; nil means use mode default.
    var destinationOverride: UUID?

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

    /// Clears every override when the Capture Session completes or is cancelled,
    /// so the next Capture Session starts from the Mode defaults.
    func clearAll() {
        parameterOverrides = [:]
        destinationOverride = nil
    }
}
