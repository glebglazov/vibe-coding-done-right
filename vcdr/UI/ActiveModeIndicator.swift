import SwiftUI

/// Green glowing dot indicating the currently active mode.
struct ActiveModeIndicator: View {
    // MARK: - Constants

    private static let size: CGFloat = 8
    private static let innerGlowOpacity: Double = 0.8
    private static let innerGlowRadius: CGFloat = 4
    private static let outerGlowOpacity: Double = 0.4
    private static let outerGlowRadius: CGFloat = 8

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: Self.size, height: Self.size)
            .shadow(color: .green.opacity(Self.innerGlowOpacity), radius: Self.innerGlowRadius)
            .shadow(color: .green.opacity(Self.outerGlowOpacity), radius: Self.outerGlowRadius)
    }
}
