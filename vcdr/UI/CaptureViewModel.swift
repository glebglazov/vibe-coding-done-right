import SwiftUI

@Observable
final class CaptureViewModel {
    // MARK: - State

    var text: String = ""
    var conversationTurns: [ConversationTurn] = []
    var captures: [CapturedContext] = []
    var isMinimized: Bool = false
    var scrollTrigger: Int = 0
    var clipboardCaptureCount: Int = 0
    var processedByModeName: String?
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

    /// Convenience for view compatibility
    var isRecording: Bool { phase == .recording }
    var isProcessing: Bool { phase == .processing }

    // MARK: - Configuration

    let settings: AppSettings
    let overrides: ConversationOverrides
    let outputDestinations: [OutputDestination]

    // MARK: - Callbacks

    let onSubmit: (String) -> Void
    let onDismiss: () -> Void
    var onCancelCapture: (() -> Void)?
    var onDestinationSubmit: ((String, UUID) -> Void)?
    let onExpand: () -> Void
    let audioRecorder: AudioRecorder?

    // MARK: - Computed

    var modeLabel: String {
        let destinationID = overrides.destinationOverride ?? settings.activeMode.defaultOutputDestinationID
        let destination = settings.outputDestination(for: destinationID)
        let parts = [settings.activeMode.name, overrides.resolvedParameterLabels(for: settings.activeMode), destination.symbol].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    /// Show "You:" / "Result:" labels when there are multiple turns,
    /// or when the single turn's input was transformed by processing,
    /// or when captured context is present.
    var showConversationLabels: Bool {
        if conversationTurns.count > 1 { return true }
        guard let turn = conversationTurns.first else { return false }
        if !turn.captures.isEmpty { return true }
        return turn.input != turn.output
    }

    /// Latest output text for copy/fire actions
    var latestText: String {
        conversationTurns.last?.output ?? ""
    }

    /// Latest text suitable for the pill copy button — latest turn output, or current text
    var latestCopyableText: String {
        let turnOutput = conversationTurns.last?.output ?? ""
        if !turnOutput.isEmpty { return turnOutput }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mode label for the minimized pill: "Mode · params · dest symbol" + " ⚡" for quick action
    var pillModeLabel: String {
        let destinationID = overrides.destinationOverride ?? settings.activeMode.defaultOutputDestinationID
        let destination = settings.outputDestination(for: destinationID)
        let parts = [settings.activeMode.name, overrides.resolvedParameterLabels(for: settings.activeMode), destination.symbol].compactMap { $0 }
        var label = parts.joined(separator: " · ")
        if settings.activeMode.quickAction {
            label += " \u{26A1}"
        }
        return label
    }

    init(
        settings: AppSettings,
        overrides: ConversationOverrides,
        conversationTurns: [ConversationTurn] = [],
        captures: [CapturedContext] = [],
        outputDestinations: [OutputDestination] = [],
        onSubmit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void,
        onExpand: @escaping () -> Void = {},
        audioRecorder: AudioRecorder? = nil
    ) {
        self.settings = settings
        self.overrides = overrides
        self.conversationTurns = conversationTurns
        self.captures = captures
        self.outputDestinations = outputDestinations
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
        self.onExpand = onExpand
        self.audioRecorder = audioRecorder
    }

    // MARK: - Key Handling

    /// Returns true if the event was handled (consumed)
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Delegate to mode switcher when it's showing
        if let msVM = modeSwitcherViewModel {
            return msVM.handleKeyEvent(event)
        }

        // Block input during recording
        if isRecording { return true }

        // Check destination hotkeys (Ctrl+P for paste, Ctrl+C for copy, etc.)
        if let matchedDestination = matchDestinationHotkey(event) {
            let effectiveText = resolveSubmissionText()
            guard !effectiveText.isEmpty else { return true }
            onDestinationSubmit?(effectiveText, matchedDestination)
            return true
        }

        // Check cancel capture hotkey (e.g. Shift+Tab) — cancel the capture
        if matchesCancelHotkey(event) {
            if let onCancelCapture { onCancelCapture() } else { onDismiss() }
            return true
        }

        switch event.keyCode {
        case 36: // Return
            // Shift+Return inserts newline (pass through to text editor)
            if event.modifierFlags.contains(.shift) { return false }
            guard !isProcessing else { return true }
            let effectiveText = resolveSubmissionText()
            guard !effectiveText.isEmpty else { return true }
            onSubmit(effectiveText)
            return true
        case 53: // Escape
            onDismiss()
            return true
        default:
            return false
        }
    }

    /// Typed text takes priority; falls back to first capture so the user
    /// can submit clipboard-gathered content without typing anything.
    private func resolveSubmissionText() -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return captures.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
    private func matchDestinationHotkey(_ event: NSEvent) -> UUID? {
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        for destination in outputDestinations where destination.activationHotkey.isAssigned {
            let requiredFlags = UInt(destination.activationHotkey.modifiers)
            if event.keyCode == destination.activationHotkey.keyCode && (eventFlags & requiredFlags) == requiredFlags {
                return destination.id
            }
        }
        return nil
    }
}
