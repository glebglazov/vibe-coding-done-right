import SwiftUI

struct WaveformView: View {
    let levels: [Float]

    // MARK: - Constants
    private static let barSpacing: CGFloat = 4
    private static let minBarHeight: CGFloat = 4
    private static let cornerRadius: CGFloat = 2
    private static let maxBarHeight: CGFloat = 60

    var body: some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(.tint)
                    .frame(maxHeight: max(Self.minBarHeight, CGFloat(level) * Self.maxBarHeight))
            }
        }
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}
