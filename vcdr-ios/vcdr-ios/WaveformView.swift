import SwiftUI

struct WaveformView: View {
    let levels: [Float]

    // MARK: - Constants
    private static let barWidth: CGFloat = 4
    private static let barSpacing: CGFloat = 3
    private static let minBarHeight: CGFloat = 8
    private static let maxBarHeight: CGFloat = 250
    private static let glowThreshold: Float = 0.6
    private static let glowRadius: CGFloat = 12

    var body: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                let isLoud = level > Self.glowThreshold
                Rectangle()
                    .fill(isLoud ? Theme.primary : Theme.primaryDim)
                    .frame(
                        width: Self.barWidth,
                        height: max(Self.minBarHeight, CGFloat(level) * Self.maxBarHeight)
                    )
                    .opacity(0.2 + Double(level) * 0.8)
                    .shadow(
                        color: isLoud ? Theme.primary.opacity(0.3) : .clear,
                        radius: Self.glowRadius
                    )
            }
        }
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}
