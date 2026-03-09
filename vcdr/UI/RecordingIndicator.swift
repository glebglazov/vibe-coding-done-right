
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
    /// Output destination override set via mode switcher; nil means use mode default
    var outputDestinationOverrideID: UUID?
    /// Resolved parameter labels for display (e.g. "Sonnet, English")
    var parameterLabels: String?
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
    private static let resizeAnimationDuration: CGFloat = 0.15

    private var panel: NSPanel?
    private let phaseState = IndicatorPhaseState()
    private let modeSwitcherState = IndicatorModeSwitcherState()
    private let settings: AppSettings
    private let audioRecorder: AudioRecorder
    /// Stored top offset for positioning below the output panel during follow-ups.
    /// Used by showCancelled() so the cancelled indicator appears in the same spot.
    private var currentTopOffset: CGFloat = 0
    private var localEventMonitor: Any?
    private var globalClickMonitor: Any?

    var isVisible: Bool { panel != nil }

    init(settings: AppSettings, audioRecorder: AudioRecorder) {
        self.settings = settings
        self.audioRecorder = audioRecorder
    }

    func show(topOffset: CGFloat = 0) {
        phaseState.phase = .recording
        phaseState.errorMessage = nil
        phaseState.parameterLabels = nil
        currentTopOffset = topOffset

        // Always recreate the panel — the existing one may be a CancelledIndicatorView
        // from a recent Esc cancel, which doesn't reference phaseState at all.
        hide()

        let hostingView = NSHostingView(rootView: RecordingIndicatorView(
            phaseState: phaseState,
            modeSwitcherState: modeSwitcherState,
            settings: settings,
            audioRecorder: audioRecorder
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)

        let panel = KeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = hostingView
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        positionAtTopCenter(panel, topOffset: topOffset)

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(phase: IndicatorPhase, message: String? = nil) {
        phaseState.errorMessage = (phase == .error) ? message : nil
        phaseState.phase = phase
    }

    /// Trigger a shake animation to reject a hotkey press during processing
    func buzz() {
        phaseState.rejectCount += 1
    }

    var currentPhase: IndicatorPhase {
        phaseState.phase
    }

    func updateOutputDestinationOverride(_ id: UUID?) {
        phaseState.outputDestinationOverrideID = id
    }

    func updateParameterLabels(_ labels: String?) {
        phaseState.parameterLabels = labels
    }

    func hide() {
        hideModeSwitcherCleanup()
        panel?.close()
        panel = nil
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
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    private func resizeForModeSwitcher(viewModel: ModeSwitcherViewModel) {
        guard let panel else { return }
        let modeSwitcherHeight = ModeSwitcherPanel.calculateHeight(
            navigationLevel: viewModel.navigationLevel,
            modes: viewModel.modes,
            destinationCount: viewModel.outputDestinations.count,
            showingDestinations: viewModel.showingDestinations,
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeAnimationDuration
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    private func resizeToNormal() {
        guard let panel else { return }
        let currentFrame = panel.frame
        let newY = currentFrame.maxY - Self.panelHeight
        let newX = currentFrame.midX - Self.panelWidth / 2
        let newFrame = NSRect(x: newX, y: newY, width: Self.panelWidth, height: Self.panelHeight)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeAnimationDuration
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    /// Show a brief "cancelled" indicator (grey X pill) that auto-hides.
    /// Uses the stored topOffset so it appears where the recording indicator was.
    func showCancelled() {
        let offset = currentTopOffset
        currentTopOffset = 0
        hide()

        let hostingView = NSHostingView(rootView: CancelledIndicatorView())
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)

        let cancelPanel = makeEphemeralPanel(contentView: hostingView)
        positionAtTopCenter(cancelPanel, topOffset: offset)
        cancelPanel.orderFrontRegardless()
        self.panel = cancelPanel

        Task {
            try? await Task.sleep(for: Self.cancelledDisplayDuration)
            cancelPanel.close()
            if self.panel === cancelPanel {
                self.panel = nil
            }
        }
    }

    // MARK: - Copied Indicator

    private static let copiedDisplayDuration: Duration = .seconds(1.5)

    /// Show a brief "copied" indicator (clipboard icon → green checkmark pill) that auto-hides
    func showCopied() {
        hide()

        let hostingView = NSHostingView(rootView: CopiedIndicatorView())
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)

        let copiedPanel = makeEphemeralPanel(contentView: hostingView)
        positionAtTopCenter(copiedPanel)
        copiedPanel.orderFrontRegardless()
        self.panel = copiedPanel

        Task {
            try? await Task.sleep(for: Self.copiedDisplayDuration)
            copiedPanel.close()
            if self.panel === copiedPanel {
                self.panel = nil
            }
        }
    }

    // MARK: - Copy Error Indicator

    private static let copyErrorDisplayDuration: Duration = .seconds(2)

    /// Show a brief error indicator with a message that auto-hides
    func showCopyError(_ message: String) {
        hide()

        let hostingView = NSHostingView(rootView: CopyErrorIndicatorView(message: message))
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)

        let errorPanel = makeEphemeralPanel(contentView: hostingView)
        positionAtTopCenter(errorPanel)
        errorPanel.orderFrontRegardless()
        self.panel = errorPanel

        Task {
            try? await Task.sleep(for: Self.copyErrorDisplayDuration)
            errorPanel.close()
            if self.panel === errorPanel {
                self.panel = nil
            }
        }
    }

    // MARK: - Ephemeral Panel Helpers

    private func makeEphemeralPanel(contentView: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: contentView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = contentView
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        return panel
    }

    private func positionAtTopCenter(_ panel: NSPanel, topOffset: CGFloat = 0) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
        let x = screenFrame.midX - Self.panelWidth / 2
        let y = screenFrame.maxY - menuBarHeight - Self.panelHeight - Self.menuBarGap - topOffset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Constants (cancel indicator)
    private static let cancelledDisplayDuration: Duration = .seconds(1)
}

// MARK: - SwiftUI View

private struct RecordingIndicatorView: View {
    // MARK: - Constants

    private static let pillHeight: CGFloat = 32
    private static let pillHPadding: CGFloat = 12
    private static let pillSpacing: CGFloat = 6
    private static let iconSize: CGFloat = 16
    private static let phaseTransitionDuration: Double = 0.2

    private static let errorPillSpacing: CGFloat = 4
    private static let errorPillHPadding: CGFloat = 8
    private static let errorPillVPadding: CGFloat = 3
    private static let errorPillCornerRadius: CGFloat = 6
    private static let errorPillFontSize: CGFloat = 11

    let phaseState: IndicatorPhaseState
    let modeSwitcherState: IndicatorModeSwitcherState
    let settings: AppSettings
    let audioRecorder: AudioRecorder

    var body: some View {
        VStack(spacing: Self.errorPillSpacing) {
            HStack(spacing: Self.pillSpacing) {
                switch phaseState.phase {
                case .recording:
                    AudioWaveformView(audioLevels: audioRecorder.audioLevels)
                        .transition(.opacity)

                case .processing:
                    AnimatedDotsView()
                        .transition(.opacity)

                case .success:
                    Image(systemName: "checkmark")
                        .font(.system(size: Self.iconSize, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)

                case .error:
                    Image(systemName: "xmark")
                        .font(.system(size: Self.iconSize, weight: .semibold))
                        .foregroundStyle(.red)
                        .transition(.opacity)
                }

                if phaseState.phase == .recording || phaseState.phase == .processing {
                    let destinationID = phaseState.outputDestinationOverrideID ?? settings.activeMode.defaultOutputDestinationID
                    let destination = settings.outputDestination(for: destinationID)
                    let labelParts = [settings.activeMode.name, phaseState.parameterLabels, destination.symbol].compactMap { $0 }
                    Text(labelParts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Self.pillHPadding)
            .frame(height: Self.pillHeight)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
            .shadow(radius: 2)

            if let message = phaseState.errorMessage, phaseState.phase == .error {
                Text(message)
                    .font(.system(size: Self.errorPillFontSize))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.errorPillHPadding)
                    .padding(.vertical, Self.errorPillVPadding)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.errorPillCornerRadius))
                    .shadow(radius: 2)
                    .transition(.opacity)
            }

            if let vm = modeSwitcherState.viewModel {
                ModeSwitcherView(viewModel: vm)
                    .frame(width: ModeSwitcherPanel.panelWidth)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(ShakeEffect(shakeCount: phaseState.rejectCount))
        .animation(.easeInOut(duration: Self.phaseTransitionDuration), value: phaseState.phase)
        .animation(.default, value: phaseState.rejectCount)
    }
}

// MARK: - Audio Waveform View

/// Visualizes real microphone input as vertical bars with a symmetric
/// bell-curve shape — tallest in the center, tapering to the edges.
struct AudioWaveformView: View {
    // MARK: - Constants

    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let minBarHeight: CGFloat = 3
    private static let maxBarHeight: CGFloat = 14
    private static let animationDuration: Double = 0.06
    /// Symmetric taper: edges are much shorter, center is tallest
    private static let barScales: [CGFloat] = [0.25, 0.6, 1.0, 0.6, 0.25]

    let audioLevels: [Float]

    var body: some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(Array(audioLevels.enumerated()), id: \.offset) { index, level in
                let scale = Self.barScales[index]
                let height = Self.minBarHeight + (Self.maxBarHeight - Self.minBarHeight) * CGFloat(level) * scale
                Capsule()
                    .fill(.red)
                    .frame(width: Self.barWidth, height: height)
            }
        }
        .animation(.easeOut(duration: Self.animationDuration), value: audioLevels)
    }
}

// MARK: - Animated Dots View

/// Three bouncing dots with staggered animation for processing state.
struct AnimatedDotsView: View {
    // MARK: - Constants

    private static let dotSize: CGFloat = 5
    private static let dotSpacing: CGFloat = 3
    private static let bounceHeight: CGFloat = 4
    private static let animationDuration: Double = 0.4
    private static let dotCount = 3

    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: Self.dotSpacing) {
            ForEach(0..<Self.dotCount, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .offset(y: isAnimating ? -Self.bounceHeight : 0)
                    .animation(
                        .easeInOut(duration: Self.animationDuration)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = true }
    }
}

