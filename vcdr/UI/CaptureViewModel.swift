import SwiftUI
import OSLog

@Observable
final class CaptureViewModel {
    // MARK: - State

    var displayedTurn: DisplayedTurn?
    var isMinimized: Bool = false
    var processedByModeName: String?
    var rejectCount: Int = 0
    var modeSwitcherViewModel: ModeSwitcherViewModel?

    /// Unified phase for both the minimized pill and expanded view state
    enum CapturePhase {
        case idle
        case recording
        case processing
        case success
        case error
        case cancelled
    }
    var phase: CapturePhase = .idle
    var errorMessage: String?

    /// Convenience for view compatibility
    var isRecording: Bool { phase == .recording }
    var isProcessing: Bool { phase == .processing }

    // MARK: - Configuration

    let settings: AppSettings
    let overrides: SessionOverrides
    let outputDestinations: [OutputDestination]
    /// Name of the app that was frontmost when capture started, for display in "Paste to Initial App" labels.
    var initialAppName: String?

    // MARK: - Callbacks

    let onDismiss: () -> Void
    var onCancelCapture: (() -> Void)?
    /// Called when the user presses Return to confirm the preview.
    var onConfirm: (() -> Void)?
    /// Called when a destination hotkey is pressed during preview, passing the destination ID.
    var onDestinationSubmit: ((UUID) -> Void)?
    let onExpand: () -> Void
    let audioRecorder: AudioRecorder?

    // MARK: - Computed

    var modeLabel: String {
        let destinationID = overrides.destinationOverride ?? settings.activeMode.defaultOutputDestinationID
        let destination = settings.outputDestination(for: destinationID)
        return buildModeLabel(
            modeName: settings.activeMode.name,
            parameterLabels: overrides.resolvedParameterLabels(for: settings.activeMode),
            destinationSymbol: destinationDisplaySymbol(for: destination)
        )
    }

    /// Returns the destination symbol, enriched with the initial app name for `.pasteToInitialApp`.
    private func destinationDisplaySymbol(for destination: OutputDestination) -> String {
        if destination.type == .pasteToInitialApp, let appName = initialAppName {
            return "\(destination.symbol) \(appName)"
        }
        return destination.symbol
    }

    /// Returns the display name for a destination, enriched for `.pasteToInitialApp`.
    func destinationDisplayName(for destination: OutputDestination) -> String {
        if destination.type == .pasteToInitialApp, let appName = initialAppName {
            return "paste to \(appName)"
        }
        return destination.name.lowercased()
    }

    /// Output text from the displayed turn for copy actions.
    var outputText: String? {
        displayedTurn?.output
    }

    /// Mode label for the minimized pill: "Mode · params · dest symbol" + " ⚡" for quick action
    var pillModeLabel: String {
        var label = modeLabel
        if settings.activeMode.showPreview {
            label += " \u{1F441}"  // 👁 — preview enabled
        }
        return label
    }

    init(
        settings: AppSettings,
        overrides: SessionOverrides,
        displayedTurn: DisplayedTurn? = nil,
        outputDestinations: [OutputDestination] = [],
        onDismiss: @escaping () -> Void,
        onExpand: @escaping () -> Void = {},
        audioRecorder: AudioRecorder? = nil
    ) {
        self.settings = settings
        self.overrides = overrides
        self.displayedTurn = displayedTurn
        self.outputDestinations = outputDestinations
        self.onDismiss = onDismiss
        self.onExpand = onExpand
        self.audioRecorder = audioRecorder
    }

    func clearError() {
        errorMessage = nil
        phase = .idle
    }

    // MARK: - Key Handling

    /// Returns true if the event was handled (consumed)
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Delegate to mode switcher when it's showing
        if let msVM = modeSwitcherViewModel {
            return msVM.handleKeyEvent(event)
        }

        // During recording, only handle dismiss — let other keys pass through
        if isRecording {
            if event.keyCode == KeyCodeMap.escapeKeyCode {
                onDismiss()
                return true
            }
            return false
        }

        // Check destination hotkeys (Ctrl+P for paste, Ctrl+C for copy, etc.)
        if let matchedDestination = matchDestinationHotkey(event) {
            onDestinationSubmit?(matchedDestination)
            return true
        }

        // Check cancel capture hotkey (e.g. Shift+Tab) — cancel the capture
        if matchesCancelHotkey(event) {
            if let onCancelCapture { onCancelCapture() } else { onDismiss() }
            return true
        }

        switch event.keyCode {
        case KeyCodeMap.returnKeyCode:
            guard !isProcessing else { return true }
            onConfirm?()
            return true
        case KeyCodeMap.escapeKeyCode:
            onDismiss()
            return true
        default:
            return false
        }
    }

    /// Checks if the event matches the configured cancel recording hotkey.
    private func matchesCancelHotkey(_ event: NSEvent) -> Bool {
        let binding = settings.cancelRecordingHotkey
        guard binding.isAssigned else { return false }
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        let requiredFlags = UInt(binding.modifiers)
        return event.keyCode == binding.keyCode && (eventFlags & requiredFlags) == requiredFlags
    }

    /// Checks if the event matches any output destination's activation hotkey.
    /// Uses superset modifier matching — extra modifiers are allowed.
    /// When multiple destinations share the same keyCode, the most specific match
    /// (most required modifier bits) wins, so Shift+Ctrl+P beats Ctrl+P.
    private func matchDestinationHotkey(_ event: NSEvent) -> UUID? {
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        let hasControlModifier = event.modifierFlags.contains(.control)
        if hasControlModifier {
            Logger.hotkeys.debug("Destination hotkey check: keyCode=\(event.keyCode) eventFlags=0x\(String(eventFlags, radix: 16)) destinations=\(self.outputDestinations.count)")
            for destination in outputDestinations where destination.activationHotkey.isAssigned {
                Logger.hotkeys.debug("  dest '\(destination.name)': keyCode=\(destination.activationHotkey.keyCode) modifiers=0x\(String(destination.activationHotkey.modifiers, radix: 16))")
            }
        }
        var bestMatch: (id: UUID, specificity: Int)?
        for destination in outputDestinations where destination.activationHotkey.isAssigned {
            let requiredFlags = UInt(destination.activationHotkey.modifiers)
            if event.keyCode == destination.activationHotkey.keyCode && (eventFlags & requiredFlags) == requiredFlags {
                let specificity = requiredFlags.nonzeroBitCount
                if bestMatch == nil || specificity > bestMatch!.specificity {
                    bestMatch = (destination.id, specificity)
                }
            }
        }
        if hasControlModifier {
            if let match = bestMatch {
                let dest = outputDestinations.first { $0.id == match.id }
                Logger.hotkeys.debug("Destination hotkey matched: '\(dest?.name ?? "unknown")'")
            } else {
                Logger.hotkeys.debug("Destination hotkey: no match for keyCode=\(event.keyCode)")
            }
        }
        return bestMatch?.id
    }
}
