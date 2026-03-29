import SwiftUI
import OSLog

@Observable
final class CaptureViewModel {
    // MARK: - Types

    /// Unified phase for both the minimized pill and expanded view state
    enum CapturePhase {
        case idle
        case recording
        case processing
        case success
        case error
    }

    struct PhaseState {
        var phase: CapturePhase = .idle
        var errorMessage: String?

        var isRecording: Bool { phase == .recording }
        var isProcessing: Bool { phase == .processing }
    }

    struct FeedbackCounters {
        var clipboardCaptureCount: Int = 0
        var rejectCount: Int = 0
    }

    // MARK: - State (5 observable properties)

    var displayedTurn: DisplayedTurn?
    var isMinimized: Bool = false
    var phaseState = PhaseState()
    var feedbackCounters = FeedbackCounters()
    var initialAppName: String?

    @ObservationIgnored var processedByModeName: String?
    /// Non-nil when AI processing failed — shown as a notice in the preview
    var aiProcessingErrorMessage: String?
    /// Set to true when the mode switcher is shown as a standalone panel — prevents
    /// the CapturePanel from auto-dismissing when it loses focus to the mode switcher.
    @ObservationIgnored var isSuspendedForModeSwitcher: Bool = false

    /// Convenience forwarders
    var isRecording: Bool { phaseState.isRecording }
    var isProcessing: Bool { phaseState.isProcessing }

    // MARK: - Configuration

    let settings: AppSettings
    let overrides: SessionOverrides
    let outputDestinations: [OutputDestination]

    // MARK: - Callbacks

    let onDismiss: () -> Void
    let onCancelCapture: (() -> Void)?
    /// Called when the user presses Return to confirm the preview.
    let onConfirm: (() -> Void)?
    /// Called when a destination hotkey is pressed during preview, passing the destination ID.
    let onDestinationSubmit: ((UUID) -> Void)?
    let onExpand: () -> Void
    let audioRecorder: AudioRecorder?
    /// Called when user taps Retry after AI processing failed
    var onRetryAIProcessing: (() -> Void)?

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
        onConfirm: (() -> Void)? = nil,
        onCancelCapture: (() -> Void)? = nil,
        onDestinationSubmit: ((UUID) -> Void)? = nil,
        onExpand: @escaping () -> Void = {},
        audioRecorder: AudioRecorder? = nil
    ) {
        self.settings = settings
        self.overrides = overrides
        self.displayedTurn = displayedTurn
        self.outputDestinations = outputDestinations
        self.onDismiss = onDismiss
        self.onConfirm = onConfirm
        self.onCancelCapture = onCancelCapture
        self.onDestinationSubmit = onDestinationSubmit
        self.onExpand = onExpand
        self.audioRecorder = audioRecorder
    }

    func clearError() {
        phaseState = PhaseState()
    }

    /// Handles pill tap: copies error message to clipboard if in error state, then expands.
    func onPillTapped() {
        if phaseState.phase == .error, let msg = phaseState.errorMessage {
            ClipboardHelper.writeString(msg)
        }
        onExpand()
    }

    // MARK: - Key Handling

    /// Returns true if the event was handled (consumed)
    func handleKeyEvent(_ event: NSEvent) -> Bool {
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

    /// Matches against output destination hotkeys using the shared superset-modifier matching algorithm.
    private func matchDestinationHotkey(_ event: NSEvent) -> UUID? {
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        let bindings = outputDestinations.map { ($0.id, $0.activationHotkey.keyCode, $0.activationHotkey.modifiers) }
        let match = DestinationHotkeyManager.matchBinding(
            keyCode: event.keyCode,
            modifierBits: UInt64(eventFlags),
            bindings: bindings
        )
        if let match, event.modifierFlags.contains(.control) {
            let dest = outputDestinations.first { $0.id == match }
            Logger.hotkeys.debug("Destination hotkey matched: '\(dest?.name ?? "unknown")'")
        }
        return match
    }
}
