import SwiftUI

// MARK: - Audio Level Meter

struct AudioLevelMeter: View {
    let level: Float

    // MARK: - Constants

    private static let meterHeight: CGFloat = 8
    private static let cornerRadius: CGFloat = 4
    private static let yellowThreshold: Float = 0.5
    private static let redThreshold: Float = 0.8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(Color.secondary.opacity(0.2))

                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(meterColor)
                    .frame(width: geometry.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(width: 120, height: Self.meterHeight)
    }

    private var meterColor: Color {
        if level > Self.redThreshold {
            return .red
        } else if level > Self.yellowThreshold {
            return .yellow
        }
        return .green
    }
}
