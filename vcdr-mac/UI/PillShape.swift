import SwiftUI

/// Brutalist capsule pill — hard border, flat adaptive fill, no material, no shadow.
/// Mirrors the iOS Theme's `surfaceHigh` + `onSurface` pairing.
struct PillShape: ViewModifier {
    static let defaultHeight: CGFloat = 32
    static let defaultHPadding: CGFloat = 12
    static let strokeWidth: CGFloat = 1.5

    @Environment(\.colorScheme) private var colorScheme

    var height: CGFloat = Self.defaultHeight
    var hPadding: CGFloat = Self.defaultHPadding

    private var fillColor: Color {
        colorScheme == .dark
            ? Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
            : Color(red: 225 / 255, green: 225 / 255, blue: 225 / 255)
    }

    private var strokeColor: Color {
        colorScheme == .dark ? .white : .black
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, hPadding)
            .frame(height: height)
            .background(fillColor, in: Capsule())
            .overlay(Capsule().strokeBorder(strokeColor, lineWidth: Self.strokeWidth))
    }
}

extension View {
    func pillShape(height: CGFloat = PillShape.defaultHeight, hPadding: CGFloat = PillShape.defaultHPadding) -> some View {
        modifier(PillShape(height: height, hPadding: hPadding))
    }
}
