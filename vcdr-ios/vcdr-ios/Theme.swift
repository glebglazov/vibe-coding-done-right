import SwiftUI

/// Brutalist design system — sharp edges, bold accents, adaptive backgrounds.
/// Access via `Theme.current(for:)` or the `@Environment(\.theme)` value.
struct Theme {
    // MARK: - Backgrounds
    let background: Color
    let surfaceLowest: Color
    let surfaceContainer: Color
    let surfaceHigh: Color
    let surfaceHighest: Color

    // MARK: - Accents
    let primary: Color
    let primaryDim: Color

    // MARK: - Text
    let onSurface: Color
    let onSurfaceVariant: Color

    // MARK: - Dot Grid
    let dotGridColor: Color

    // MARK: - Variants

    static let dark = Theme(
        background: Color(red: 14 / 255, green: 14 / 255, blue: 14 / 255),
        surfaceLowest: .black,
        surfaceContainer: Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255),
        surfaceHigh: Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255),
        surfaceHighest: Color(red: 38 / 255, green: 38 / 255, blue: 38 / 255),
        primary: Color(red: 1, green: 142 / 255, blue: 128 / 255),
        primaryDim: Color(red: 226 / 255, green: 36 / 255, blue: 31 / 255),
        onSurface: .white,
        onSurfaceVariant: Color(red: 171 / 255, green: 171 / 255, blue: 171 / 255),
        dotGridColor: .white.opacity(0.04)
    )

    static let light = Theme(
        background: Color(red: 245 / 255, green: 245 / 255, blue: 245 / 255),
        surfaceLowest: .white,
        surfaceContainer: Color(red: 235 / 255, green: 235 / 255, blue: 235 / 255),
        surfaceHigh: Color(red: 225 / 255, green: 225 / 255, blue: 225 / 255),
        surfaceHighest: Color(red: 210 / 255, green: 210 / 255, blue: 210 / 255),
        primary: Color(red: 220 / 255, green: 50 / 255, blue: 40 / 255),
        primaryDim: Color(red: 180 / 255, green: 30 / 255, blue: 25 / 255),
        onSurface: .black,
        onSurfaceVariant: Color(red: 100 / 255, green: 100 / 255, blue: 100 / 255),
        dotGridColor: .black.opacity(0.04)
    )

    static func current(for scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
