import SwiftUI

/// Marks the bottom edge where the system gesture back to the previous app
/// starts: the edge glows, "Swipe to go back" sits above it, and a fingertip
/// lands on the home indicator, slides left to right, and lifts. It loops for
/// as long as it is on screen. Place it full width with the bottom safe area
/// ignored, so the fingertip sits on the home indicator.
struct EdgeSwipeHint: View {
    // MARK: - Constants

    private static let glowHeight: CGFloat = 110
    private static let glowPeakOpacity: Double = 0.38
    private static let glowDimOpacity: Double = 0.35
    private static let glowPulseDuration: Double = 1.1
    private static let labelFontSize: CGFloat = 14
    private static let labelTracking: CGFloat = 3
    private static let labelBottomPadding: CGFloat = 48
    private static let fingertipSize: CGFloat = 28
    private static let fingertipHaloWidth: CGFloat = 10
    private static let fingertipHaloOpacity: Double = 0.25
    private static let fingertipBottomPadding: CGFloat = 2
    private static let travel: CGFloat = 140
    private static let restingScale: CGFloat = 0.7
    private static let peakOpacity: Double = 0.9
    private static let landDuration: Double = 0.25
    private static let slideDuration: Double = 0.7
    private static let liftDuration: Double = 0.25
    private static let pauseDuration: Double = 0.6

    @Environment(\.theme) private var theme

    private enum Phase: CaseIterable {
        case waiting, landed, slid, lifted

        var offset: CGFloat {
            switch self {
            case .waiting, .landed: -EdgeSwipeHint.travel / 2
            case .slid, .lifted: EdgeSwipeHint.travel / 2
            }
        }

        var isTouching: Bool { self == .landed || self == .slid }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            glow
            Text("Swipe to go back")
                .font(.system(size: Self.labelFontSize, weight: .heavy))
                .tracking(Self.labelTracking)
                .textCase(.uppercase)
                .foregroundStyle(theme.primaryDim)
                .padding(.bottom, Self.labelBottomPadding)
            fingertip
                .padding(.bottom, Self.fingertipBottomPadding)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Swipe right along the bottom edge to go back")
    }

    private var glow: some View {
        LinearGradient(
            colors: [theme.primaryDim.opacity(Self.glowPeakOpacity), .clear],
            startPoint: .bottom,
            endPoint: .top
        )
        .frame(height: Self.glowHeight)
        .phaseAnimator([false, true]) { content, bright in
            content.opacity(bright ? 1 : Self.glowDimOpacity)
        } animation: { _ in
            .easeInOut(duration: Self.glowPulseDuration)
        }
    }

    private var fingertip: some View {
        Circle()
            .fill(theme.primaryDim)
            .frame(width: Self.fingertipSize, height: Self.fingertipSize)
            .background(
                Circle()
                    .fill(theme.primaryDim.opacity(Self.fingertipHaloOpacity))
                    .padding(-Self.fingertipHaloWidth)
            )
            .phaseAnimator(Phase.allCases) { content, phase in
                content
                    .offset(x: phase.offset)
                    .scaleEffect(phase.isTouching ? 1 : Self.restingScale)
                    .opacity(phase.isTouching ? Self.peakOpacity : 0)
            } animation: { phase in
                switch phase {
                case .waiting: .linear(duration: Self.pauseDuration)
                case .landed: .easeOut(duration: Self.landDuration)
                case .slid: .easeInOut(duration: Self.slideDuration)
                case .lifted: .easeIn(duration: Self.liftDuration)
                }
            }
    }
}
