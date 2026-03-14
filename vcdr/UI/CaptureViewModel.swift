import SwiftUI

@Observable
final class CaptureViewModel {
    // MARK: - State

    var segments: [InputSegment] = [InputSegment()]
    /// Index of the segment the cursor is currently in.
    /// Updated by SegmentEditor's onFocus callback when the user clicks into or types in an editor.
    /// Used by CaptureCoordinator to decide where to insert new captures.
    var activeSegmentIndex: Int = 0
    /// Saved cursor positions per segment ID, used to restore cursor on expand after collapse.
    /// Populated by CapturePanel.minimize(), consumed by SegmentEditor.makeNSView().
    var savedCursorPositions: [UUID: Int] = [:]
    var conversationTurns: [ConversationTurn] = []
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

    /// All captures across all segments, preserving order.
    var allCaptures: [CapturedContext] {
        segments.compactMap(\.capture)
    }

    /// Whether any segment has a capture.
    var hasCaptures: Bool {
        segments.contains { $0.capture != nil }
    }

    /// Full text content across all segments (for checking emptiness, draft recording).
    var fullText: String {
        segments.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
        segments: [InputSegment] = [InputSegment()],
        outputDestinations: [OutputDestination] = [],
        onSubmit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void,
        onExpand: @escaping () -> Void = {},
        audioRecorder: AudioRecorder? = nil
    ) {
        self.settings = settings
        self.overrides = overrides
        self.conversationTurns = conversationTurns
        self.segments = segments
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

    /// Builds interleaved submission text with `<capture-N>` tags from segments.
    /// Falls back to first capture text for submit-without-typing.
    private func resolveSubmissionText() -> String {
        // Trim trailing empty segments (no text, no capture) from submission
        var effectiveSegments = segments
        while effectiveSegments.count > 1,
              let last = effectiveSegments.last,
              last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              last.capture == nil {
            effectiveSegments.removeLast()
        }

        var parts: [String] = []
        for (index, segment) in effectiveSegments.enumerated() {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
            if let capture = segment.capture {
                let captureNumber = effectiveSegments[0...index].compactMap(\.capture).count
                parts.append("<capture-\(captureNumber)>\(capture.text)</capture-\(captureNumber)>")
            }
        }
        let result = parts.joined(separator: "\n")
        if !result.isEmpty { return result }
        // Fallback: first capture text (for submit-without-typing)
        return effectiveSegments.first?.capture?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
