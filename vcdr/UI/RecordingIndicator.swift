
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

// MARK: - Indicator Capture State

/// Tracks mid-recording clipboard captures for visual feedback (badge flash).
@Observable
@MainActor
final class IndicatorCaptureState {
    var captureCount: Int = 0
}

// MARK: - Indicator Mode Switcher State

/// Separate observable for mode switcher state, to avoid exceeding IndicatorPhaseState's 5-property limit.
@Observable
@MainActor
final class IndicatorModeSwitcherState {
    var viewModel: ModeSwitcherViewModel?
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
    /// Gap between pill and mode switcher list
    private static let modeSwitcherGap: CGFloat = 4
    private static let cancelledDisplayDuration: Duration = .seconds(1)
    private static let dismissedDisplayDuration: Duration = .seconds(1)
    private static let successDisplayDuration: Duration = .seconds(1.5)
    private static let copiedDisplayDuration: Duration = .seconds(1.5)
    private static let copyErrorDisplayDuration: Duration = .seconds(2)

    private var panel: NSPanel?
    private let phaseState = IndicatorPhaseState()
    private let captureState = IndicatorCaptureState()
    private let modeSwitcherState = IndicatorModeSwitcherState()
    private let settings: AppSettings
    private let overrides: ConversationOverrides
    private let audioRecorder: AudioRecorder
    /// Stored top offset for positioning below the output panel during follow-ups.
    /// Used by showCancelled() so the cancelled indicator appears in the same spot.
    private var currentTopOffset: CGFloat = 0
    private var localEventMonitor: Any?
    private var globalClickMonitor: Any?
    private var dismissTask: Task<Void, Never>?

    var isVisible: Bool { panel != nil }

    init(settings: AppSettings, overrides: ConversationOverrides, audioRecorder: AudioRecorder) {
        self.settings = settings
        self.overrides = overrides
        self.audioRecorder = audioRecorder
    }

    func show(topOffset: CGFloat = 0) {
        phaseState.phase = .recording
        phaseState.errorMessage = nil
        captureState.captureCount = 0
        currentTopOffset = topOffset

        // Always recreate the panel — the existing one may be a CancelledIndicatorView
        // from a recent Esc cancel, which doesn't reference phaseState at all.
        hide()

        let hostingView = NSHostingView(rootView: RecordingIndicatorView(
            phaseState: phaseState,
            captureState: captureState,
            modeSwitcherState: modeSwitcherState,
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

    /// Triggers a brief clipboard icon flash on the recording indicator
    func signalClipboardCapture() {
        captureState.captureCount += 1
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        hideModeSwitcherCleanup()
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

    // MARK: - Contextual Mode Switcher

    func showModeSwitcher(viewModel: ModeSwitcherViewModel) {
        modeSwitcherState.viewModel = viewModel
        panel?.ignoresMouseEvents = false
        panel?.makeKey()

        // Resize panel to fit the mode list below the pill
        resizeForModeSwitcher(viewModel: viewModel)

        // Wire resize callback so parameter/destination drilling updates panel height
        viewModel.onResize = { [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            self.resizeForModeSwitcher(viewModel: viewModel)
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel] event in
            guard let viewModel else { return event }
            return viewModel.handleKeyEvent(event) ? nil : event
        }

        // Dismiss via the VM's onDismiss callback so the coordinator is notified
        // (e.g. to resume the Escape cancel tap)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak viewModel] _ in
            viewModel?.onDismiss()
        }
    }

    func hideModeSwitcher() {
        hideModeSwitcherCleanup()
        resizeToNormal()
    }

    var isModeSwitcherVisible: Bool {
        modeSwitcherState.viewModel != nil
    }

    private func hideModeSwitcherCleanup() {
        modeSwitcherState.viewModel = nil
        panel?.ignoresMouseEvents = true
        removeEventMonitor(&localEventMonitor)
        removeEventMonitor(&globalClickMonitor)
    }

    private func resizeForModeSwitcher(viewModel: ModeSwitcherViewModel) {
        guard let panel else { return }
        let modeSwitcherHeight = ModeSwitcherPanel.calculateHeight(
            navigationLevel: viewModel.navigation.level,
            modes: viewModel.modes,
            destinationCount: viewModel.outputDestinations.count,
            showingDestinations: viewModel.navigation.showingDestinations,
            showHint: viewModel.showHint
        )
        let totalHeight = Self.panelHeight + Self.modeSwitcherGap + modeSwitcherHeight
        // Use mode switcher width since it's wider than the pill
        let width = max(Self.panelWidth, ModeSwitcherPanel.panelWidth)
        let currentFrame = panel.frame
        // Keep top edge pinned, grow downward
        let newY = currentFrame.maxY - totalHeight
        let newX = currentFrame.midX - width / 2
        let newFrame = NSRect(x: newX, y: newY, width: width, height: totalHeight)
        panel.animateResize(to: newFrame)
    }

    private func resizeToNormal() {
        guard let panel else { return }
        let currentFrame = panel.frame
        let newY = currentFrame.maxY - Self.panelHeight
        let newX = currentFrame.midX - Self.panelWidth / 2
        let newFrame = NSRect(x: newX, y: newY, width: Self.panelWidth, height: Self.panelHeight)
        panel.animateResize(to: newFrame)
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

    // MARK: - Private Helpers

    private func showEphemeral<V: View>(content: V, duration: Duration, topOffset: CGFloat = 0) {
        hide()

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)

        let ephemeralPanel = makeEphemeralPanel(contentView: hostingView)
        positionAtTopCenter(ephemeralPanel, topOffset: topOffset)
        ephemeralPanel.orderFrontRegardless()
        self.panel = ephemeralPanel

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

