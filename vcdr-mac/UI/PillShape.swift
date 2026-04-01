import SwiftUI

/// Shared capsule pill style used by the capture view minimized pill,
/// recording indicator, and ephemeral indicator views.
struct PillShape: ViewModifier {
    // MARK: - Constants

    static let defaultHeight: CGFloat = 32
    static let defaultHPadding: CGFloat = 12

    var height: CGFloat = Self.defaultHeight
    var hPadding: CGFloat = Self.defaultHPadding

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, hPadding)
            .frame(height: height)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
            .shadow(radius: 2)
    }
}

extension View {
    func pillShape(height: CGFloat = PillShape.defaultHeight, hPadding: CGFloat = PillShape.defaultHPadding) -> some View {
        modifier(PillShape(height: height, hPadding: hPadding))
    }
}
