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

    private static let normalPanelSize: CGFloat = 48
    private static let errorPanelWidth: CGFloat = 320
    private static let errorPanelHeight: CGFloat = 120
    /// Gap between bottom of menu bar and top of indicator panel
    private static let menuBarGap: CGFloat = 8

    private var panel: NSPanel?
    private let phaseState = IndicatorPhaseState()

    func show() {
        phaseState.phase = .recording
        phaseState.errorMessage = nil
        guard panel == nil else {
            resizePanel(forError: false)
            return
        }

        let hostingView = NSHostingView(rootView: RecordingIndicatorView(phaseState: phaseState))
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.normalPanelSize, height: Self.normalPanelSize)

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = hostingView
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        // Position at top center of the main screen, just below the menu bar
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let visibleFrame = screen.visibleFrame
            let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
            let x = screenFrame.midX - Self.normalPanelSize / 2
            let y = screenFrame.maxY - menuBarHeight - Self.normalPanelSize - Self.menuBarGap
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(phase: IndicatorPhase, message: String? = nil) {
        phaseState.errorMessage = (phase == .error) ? message : nil
        phaseState.phase = phase
        if phase == .error && message != nil {
            resizePanel(forError: true)
        } else {
            resizePanel(forError: false)
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
        panel?.close()
        panel = nil
    }

    /// Resize and reposition the panel, keeping the top-center anchored
    private func resizePanel(forError: Bool) {
        guard let panel else { return }
        let currentTopCenter = NSPoint(x: panel.frame.midX, y: panel.frame.maxY)
        let newWidth = forError ? Self.errorPanelWidth : Self.normalPanelSize
        let newHeight = forError ? Self.errorPanelHeight : Self.normalPanelSize
        let newFrame = NSRect(
            x: currentTopCenter.x - newWidth / 2,
            y: currentTopCenter.y - newHeight,
            width: newWidth,
            height: newHeight
        )
        panel.setFrame(newFrame, display: true)
    }
}

// MARK: - SwiftUI View

private struct RecordingIndicatorView: View {
    // MARK: - Constants

    private static let circleSize: CGFloat = 44
    private static let iconSize: CGFloat = 20
    private static let phaseTransitionDuration: Double = 0.2

    private static let errorPillSpacing: CGFloat = 4
    private static let errorPillHPadding: CGFloat = 8
    private static let errorPillVPadding: CGFloat = 3
    private static let errorPillCornerRadius: CGFloat = 6
    private static let errorPillFontSize: CGFloat = 11

    let phaseState: IndicatorPhaseState
    @State private var animating = false

    var body: some View {
        VStack(spacing: Self.errorPillSpacing) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: Self.circleSize, height: Self.circleSize)

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
                    .transition(.opacity)
            }
        }
        .modifier(ShakeEffect(shakeCount: phaseState.rejectCount))
        .animation(.easeInOut(duration: Self.phaseTransitionDuration), value: phaseState.phase)
        .animation(.default, value: phaseState.rejectCount)
        .onAppear { animating = true }
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
