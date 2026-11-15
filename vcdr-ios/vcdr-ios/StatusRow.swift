import SwiftUI

/// The reserved one-line status row at the top of the app's recording screen.
///
/// `height` is fixed, so no phase, no tenant and no Dynamic Type setting can
/// reflow the screen below it.
struct StatusRow: View {

    // MARK: - Constants

    /// Reserved whether or not there is anything to say.
    static let height: CGFloat = 20
    /// The row honours Dynamic Type up to the point where a taller line would
    /// no longer fit `height`, then stops growing.
    private static let maxFontSize: CGFloat = 16
    /// Long content at large type shrinks to fit the width rather than
    /// truncating.
    private static let minimumScale: CGFloat = 0.6

    var status: TransientStatus?
    var fontSize: CGFloat
    var color: Color

    @ScaledMetric(relativeTo: .caption) private var typeScale: CGFloat = 1

    var body: some View {
        ZStack {
            // Invisible copies of every tenant, so the row claims the width of
            // its widest content once and never re-fits as tenants change.
            ForEach(TransientStatus.allCases, id: \.self) { tenant in
                label(tenant.text).hidden()
            }
            if let status {
                label(status.text)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .accessibilityHidden(status == nil)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: min(fontSize * typeScale, Self.maxFontSize), weight: .semibold))
            .tracking(0.5)
            .lineLimit(1)
            .minimumScaleFactor(Self.minimumScale)
            .foregroundStyle(color)
    }
}
