import SwiftUI

// MARK: - Audio Waveform View

/// Visualizes real microphone input as vertical bars with a symmetric
/// bell-curve shape — tallest in the center, tapering to the edges.
struct AudioWaveformView: View {
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
    private static let dotStaggerDelay: Double = 0.15
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
                            .delay(Double(index) * Self.dotStaggerDelay),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = true }
    }
}
