
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
    var showBorder: Bool = false
    var rejectCount: Int = 0
    var errorMessage: String?
    /// Output destination override set via mode switcher; nil means use mode default
    var outputDestinationOverrideID: UUID?
}

// MARK: - Panel

@MainActor
final class RecordingIndicatorPanel {
    // MARK: - Constants

    /// Fixed panel size — large enough to fit the error message pill below the circle.
    /// The panel background is clear, so the extra space is invisible in non-error states.
    private static let panelWidth: CGFloat = 320
    private static let panelHeight: CGFloat = 120
    /// Gap between bottom of menu bar and top of indicator panel
    private static let menuBarGap: CGFloat = 8

    private var panel: NSPanel?
    private let phaseState = IndicatorPhaseState()
    private let settings: AppSettings
    /// Stored top offset for positioning below the output panel during follow-ups.
    /// Used by showCancelled() so the cancelled indicator appears in the same spot.
    private var currentTopOffset: CGFloat = 0

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show(withBorder: Bool = false, topOffset: CGFloat = 0) {
        phaseState.phase = .recording
        phaseState.showBorder = withBorder
        phaseState.errorMessage = nil
        phaseState.outputDestinationOverrideID = nil
        currentTopOffset = topOffset

        // Always recreate the panel — the existing one may be a CancelledIndicatorView
        // from a recent Esc cancel, which doesn't reference phaseState at all.
        hide()

        let hostingView = NSHostingView(rootView: RecordingIndicatorView(phaseState: phaseState, settings: settings))
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)

        let panel = NSPanel(
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

    func hide() {
        panel?.close()
        panel = nil
    }

    /// Show a brief "cancelled" indicator (grey X) that auto-hides.
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

    /// Show a brief "copied" indicator (clipboard icon → green checkmark) that auto-hides
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

    private static let circleSize: CGFloat = 44
    private static let iconSize: CGFloat = 20
    private static let toggleBorderWidth: CGFloat = 2
    private static let phaseTransitionDuration: Double = 0.2

    private static let errorPillSpacing: CGFloat = 4
    private static let errorPillHPadding: CGFloat = 8
    private static let errorPillVPadding: CGFloat = 3
    private static let errorPillCornerRadius: CGFloat = 6
    private static let errorPillFontSize: CGFloat = 11

    private static let modeLabelHPadding: CGFloat = 8
    private static let modeLabelVPadding: CGFloat = 2
    private static let modeLabelCornerRadius: CGFloat = 6

    let phaseState: IndicatorPhaseState
    let settings: AppSettings
    @State private var animating = false

    var body: some View {
        VStack(spacing: Self.errorPillSpacing) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: Self.circleSize, height: Self.circleSize)
                    .overlay(
                        Circle().strokeBorder(.red, lineWidth: phaseState.showBorder ? Self.toggleBorderWidth : 0)
                    )
                    .shadow(radius: 2)

                switch phaseState.phase {
                case .recording:
                    Image(systemName: "waveform")
                        .font(.system(size: Self.iconSize, weight: .medium))
                        .foregroundStyle(.red)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: animating)
                        .transition(.opacity)

                case .processing:
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
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
            }

            if phaseState.phase == .recording {
                let destinationID = phaseState.outputDestinationOverrideID ?? settings.activeMode.defaultOutputDestinationID
                let destination = settings.outputDestination(for: destinationID)
                Text("\(settings.activeMode.name) · \(destination.symbol)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Self.modeLabelHPadding)
                    .padding(.vertical, Self.modeLabelVPadding)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.modeLabelCornerRadius))
                    .shadow(radius: 2)
                    .transition(.opacity)
            }

            if let message = phaseState.errorMessage, phaseState.phase == .error {
                Text(message)
                    .font(.system(size: Self.errorPillFontSize))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.errorPillHPadding)
                    .padding(.vertical, Self.errorPillVPadding)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.errorPillCornerRadius))
                    .shadow(radius: 2)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(ShakeEffect(shakeCount: phaseState.rejectCount))
        .animation(.easeInOut(duration: Self.phaseTransitionDuration), value: phaseState.phase)
        .animation(.default, value: phaseState.rejectCount)
        .onAppear { animating = true }
    }
}

// MARK: - Cancelled Indicator View

private struct CancelledIndicatorView: View {
    private static let circleSize: CGFloat = 44
    private static let iconSize: CGFloat = 20

    var body: some View {
        VStack {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: Self.circleSize, height: Self.circleSize)
                    .shadow(radius: 2)

                Image(systemName: "xmark")
                    .font(.system(size: Self.iconSize, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Copied Indicator View

private struct CopiedIndicatorView: View {
    private static let circleSize: CGFloat = 44
    private static let iconSize: CGFloat = 20
    private static let transitionDelay: Duration = .milliseconds(300)

    @State private var showCheckmark = false

    var body: some View {
        VStack {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: Self.circleSize, height: Self.circleSize)
                    .shadow(radius: 2)

                if showCheckmark {
                    Image(systemName: "checkmark")
                        .font(.system(size: Self.iconSize, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: Self.iconSize, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showCheckmark)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            try? await Task.sleep(for: Self.transitionDelay)
            showCheckmark = true
        }
    }
}

// MARK: - Copy Error Indicator View

private struct CopyErrorIndicatorView: View {
    private static let circleSize: CGFloat = 44
    private static let iconSize: CGFloat = 20
    private static let pillHPadding: CGFloat = 8
    private static let pillVPadding: CGFloat = 3
    private static let pillCornerRadius: CGFloat = 6
    private static let pillFontSize: CGFloat = 11
    private static let pillSpacing: CGFloat = 4

    let message: String

    var body: some View {
        VStack(spacing: Self.pillSpacing) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: Self.circleSize, height: Self.circleSize)
                    .shadow(radius: 2)

                Image(systemName: "xmark")
                    .font(.system(size: Self.iconSize, weight: .semibold))
                    .foregroundStyle(.red)
            }

            Text(message)
                .font(.system(size: Self.pillFontSize))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Self.pillHPadding)
                .padding(.vertical, Self.pillVPadding)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.pillCornerRadius))
                .shadow(radius: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Shake Effect

/// Horizontal shake effect triggered by incrementing `shakeCount`.
/// Each increment produces a brief left-right oscillation.
private struct ShakeEffect: GeometryEffect {
    private static let amplitude: CGFloat = 4
    private static let oscillations: CGFloat = 3

    // Must be a plain CGFloat — not derived from Int — so SwiftUI can
    // interpolate smoothly between old and new values during animation.
    var animatableData: CGFloat

    init(shakeCount: Int) {
        self.animatableData = CGFloat(shakeCount)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = Self.amplitude * sin(animatableData * .pi * Self.oscillations)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}
