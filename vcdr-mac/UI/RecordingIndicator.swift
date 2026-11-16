
import AppKit
import SwiftUI

// MARK: - Indicator Phase

enum IndicatorPhase: Equatable {
    case recording
    case processing
    case success
    case error
}


@Observable
@MainActor
final class IndicatorPhaseState {
    var phase: IndicatorPhase = .recording
    var rejectCount: Int = 0
    var errorMessage: String?
}

// MARK: - Panel

@MainActor
final class RecordingIndicatorPanel {
    // MARK: - Constants

    /// Fixed panel size — large enough to fit the error message pill below the indicator.
    /// The panel background is clear, so the extra space is invisible in non-error states.
    private static let panelWidth: CGFloat = 320
    private static let panelHeight: CGFloat = 120
    /// Gap between bottom of menu bar and top of indicator panel
    private static let menuBarGap: CGFloat = 8
    private static let cancelledDisplayDuration: Duration = .seconds(1)
    private static let dismissedDisplayDuration: Duration = .seconds(1)
    private static let discardedDisplayDuration: Duration = .seconds(2)
    private static let discardOutcomeDisplayDuration: Duration = .seconds(1.5)
    private static let successDisplayDuration: Duration = .seconds(1.5)
    private static let copiedDisplayDuration: Duration = .seconds(1.5)
    private static let copyErrorDisplayDuration: Duration = .seconds(2)

    private var panel: NSPanel?
    private let phaseState = IndicatorPhaseState()
    private let settings: AppSettings
    private let overrides: SessionOverrides
    private let audioRecorder: AudioRecorder
    /// Stored top offset for positioning below the output panel during follow-ups.
    /// Used by showCancelled() so the cancelled indicator appears in the same spot.
    private var currentTopOffset: CGFloat = 0
    private var dismissTask: Task<Void, Never>?

    var isVisible: Bool { panel != nil }

    init(settings: AppSettings, overrides: SessionOverrides, audioRecorder: AudioRecorder) {
        self.settings = settings
        self.overrides = overrides
        self.audioRecorder = audioRecorder
    }

    func show(topOffset: CGFloat = 0) {
        phaseState.phase = .recording
        phaseState.errorMessage = nil
        currentTopOffset = topOffset

        // Always recreate the panel — the existing one may be a CancelledIndicatorView
        // from a recent Esc cancel, which doesn't reference phaseState at all.
        hide()

        let hostingView = NSHostingView(rootView: RecordingIndicatorView(
            phaseState: phaseState,
            settings: settings,
            overrides: overrides,
            audioRecorder: audioRecorder
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)

        let panel = KeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.configureAsOverlay(ignoresMouseEvents: true)
        panel.contentView = hostingView

        positionAtTopCenter(panel, topOffset: topOffset)

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(phase: IndicatorPhase, message: String? = nil) {
        phaseState.errorMessage = (phase == .error) ? message : nil
        phaseState.phase = phase
        if phase == .error {
            // Allow clicks on the error message pill for copy-to-clipboard
            panel?.ignoresMouseEvents = false
        }
    }

    /// Trigger a shake animation to reject a hotkey press during processing
    func buzz() {
        phaseState.rejectCount += 1
    }

    var currentPhase: IndicatorPhase {
        phaseState.phase
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.close()
        panel = nil
    }

    /// Schedules an auto-dismiss after the given duration if the indicator is still
    /// showing a terminal phase (.success or .error). Cancels any previously scheduled dismiss.
    func dismissAfterDelay(_ duration: Duration) {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            let phase = currentPhase
            if phase == .success || phase == .error {
                hide()
            }
        }
    }

    /// Cancels a pending auto-dismiss scheduled by dismissAfterDelay.
    func cancelPendingDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    // MARK: - Ephemeral Indicators

    /// Show a brief "cancelled" indicator (grey X pill) that auto-hides.
    /// Uses the stored topOffset so it appears where the recording indicator was.
    func showCancelled() {
        let offset = currentTopOffset
        currentTopOffset = 0
        showEphemeral(content: CancelledIndicatorView(), duration: Self.cancelledDisplayDuration, topOffset: offset)
    }

    /// Show a brief "dismissed" indicator that auto-hides.
    func showDismissed() {
        showEphemeral(content: InfoPillView(icon: "checkmark", iconColor: .green, label: "dismissed"), duration: Self.dismissedDisplayDuration)
    }

    /// Show a brief success indicator with the destination name that auto-hides.
    func showSuccess(destinationName: String) {
        showEphemeral(content: InfoPillView(icon: "checkmark", iconColor: .green, label: destinationName), duration: Self.successDisplayDuration)
    }

    /// Show a brief "copied" indicator (clipboard icon → green checkmark pill) that auto-hides
    func showCopied() {
        showEphemeral(content: CopiedIndicatorView(), duration: Self.copiedDisplayDuration)
    }

    /// Show a brief error indicator with a message that auto-hides
    func showCopyError(_ message: String) {
        showEphemeral(content: CopyErrorIndicatorView(message: message), duration: Self.copyErrorDisplayDuration)
    }

    /// Show a brief "recording discarded" indicator when the user cancels a run
    /// that was still waiting for the model. Cancelling there throws away audio
    /// the user has already spoken, so the pill names the loss rather than
    /// showing the bare cancel mark.
    func showRecordingDiscarded() {
        showEphemeral(content: InfoPillView(icon: "trash", iconColor: .secondary, label: "Recording discarded"), duration: Self.discardedDisplayDuration)
    }

    /// Show the outcome of a ⇧⎋ Discard. Called only once the outcome is
    /// known, so the pill never says "saved" before the save.
    func showDiscarded(savedToHistory: Bool) {
        let label = savedToHistory ? "Discarded · saved to History" : "Discarded"
        showEphemeral(content: InfoPillView(icon: "xmark", iconColor: .secondary, label: label), duration: Self.discardOutcomeDisplayDuration)
    }

    // MARK: - Private Helpers

    private func showEphemeral<V: View>(content: V, duration: Duration, topOffset: CGFloat = 0) {
        hide()

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)

        let ephemeralPanel = makeEphemeralPanel(contentView: hostingView)
        positionAtTopCenter(ephemeralPanel, topOffset: topOffset)
        ephemeralPanel.orderFrontRegardless()
        self.panel = ephemeralPanel

        // Auto-close the ephemeral indicator after the display duration elapses
        Task {
            try? await Task.sleep(for: duration)
            ephemeralPanel.close()
            if self.panel === ephemeralPanel {
                self.panel = nil
            }
        }
    }

    private func makeEphemeralPanel(contentView: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: contentView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.configureAsOverlay(ignoresMouseEvents: true)
        panel.contentView = contentView
        return panel
    }

    private func positionAtTopCenter(_ panel: NSPanel, topOffset: CGFloat = 0) {
        if let origin = panelOriginBelowMenuBar(width: Self.panelWidth, height: Self.panelHeight, offset: Self.menuBarGap + topOffset) {
            panel.setFrameOrigin(origin)
        }
    }
}

