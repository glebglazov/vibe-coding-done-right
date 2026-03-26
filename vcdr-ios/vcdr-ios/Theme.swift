import SwiftUI

/// Brutalist design system — dark backgrounds, coral/red accents, sharp edges.
enum Theme {
    // MARK: - Backgrounds

    /// Main background (#0e0e0e)
    static let background = Color(red: 14 / 255, green: 14 / 255, blue: 14 / 255)

    /// Deepest black (#000000)
    static let surfaceLowest = Color.black

    /// Container surface (#191919)
    static let surfaceContainer = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)

    /// Elevated surface (#1f1f1f)
    static let surfaceHigh = Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)

    /// Highest elevation (#262626)
    static let surfaceHighest = Color(red: 38 / 255, green: 38 / 255, blue: 38 / 255)

    // MARK: - Accents

    /// Primary coral (#ff8e80)
    static let primary = Color(red: 1, green: 142 / 255, blue: 128 / 255)

    /// Dimmed red (#e2241f)
    static let primaryDim = Color(red: 226 / 255, green: 36 / 255, blue: 31 / 255)

    // MARK: - Text

    /// Primary text (white)
    static let onSurface = Color.white

    /// Secondary text (#ababab)
    static let onSurfaceVariant = Color(red: 171 / 255, green: 171 / 255, blue: 171 / 255)
}
