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
}

// MARK: - Panel

@MainActor
final class RecordingIndicatorPanel {
    private var panel: NSPanel?
    private let phaseState = IndicatorPhaseState()

    func show() {
        phaseState.phase = .recording
        guard panel == nil else { return }

        let hostingView = NSHostingView(rootView: RecordingIndicatorView(phaseState: phaseState))
        hostingView.frame = NSRect(x: 0, y: 0, width: 48, height: 48)

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
            let x = screenFrame.midX - 24
            let y = screenFrame.maxY - menuBarHeight - 56
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(phase: IndicatorPhase) {
        phaseState.phase = phase
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
}

// MARK: - SwiftUI View

private struct RecordingIndicatorView: View {
    // MARK: - Constants

    private static let circleSize: CGFloat = 44
    private static let iconSize: CGFloat = 20

    private static let phaseTransitionDuration: Double = 0.2

    let phaseState: IndicatorPhaseState
    @State private var animating = false

    var body: some View {
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
