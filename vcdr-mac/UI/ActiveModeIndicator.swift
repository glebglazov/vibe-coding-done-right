import SwiftUI

/// Glowing dot indicating the currently active mode.
/// Green by default, red when recording is in progress.
struct ActiveModeIndicator: View {
    // MARK: - Constants

    private static let size: CGFloat = 8
    private static let innerGlowOpacity: Double = 0.8
    private static let innerGlowRadius: CGFloat = 4
    private static let outerGlowOpacity: Double = 0.4
    private static let outerGlowRadius: CGFloat = 8

    var color: Color = .green

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: Self.size, height: Self.size)
            .shadow(color: color.opacity(Self.innerGlowOpacity), radius: Self.innerGlowRadius)
            .shadow(color: color.opacity(Self.outerGlowOpacity), radius: Self.outerGlowRadius)
    }
}
