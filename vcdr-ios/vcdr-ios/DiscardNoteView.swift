import SwiftUI

/// The note at the bottom of the recording page after a Discard: where the
/// run went, and VIEW when History holds it.
struct DiscardNoteView: View {
    // MARK: - Constants

    private static let maxWidth: CGFloat = 420
    private static let border: CGFloat = 1.5
    private static let horizontalPadding: CGFloat = 20
    private static let height: CGFloat = 52
    private static let messageFontSize: CGFloat = 15
    private static let viewFontSize: CGFloat = 13
    private static let viewTracking: CGFloat = 2

    @Environment(\.theme) private var theme

    let note: DiscardNote
    let onView: () -> Void

    var body: some View {
        HStack {
            Text(note.text)
                .font(.system(size: Self.messageFontSize))
                .foregroundStyle(theme.onSurface)
            Spacer()
            if case .saved = note {
                Button(action: onView) {
                    Text("VIEW")
                        .font(.system(size: Self.viewFontSize, weight: .black))
                        .tracking(Self.viewTracking)
                        .foregroundStyle(theme.primary)
                        .frame(height: Self.height)
                        .contentShape(Rectangle())
                }
                .accessibilityHint("Opens History on the discarded recording")
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(maxWidth: Self.maxWidth)
        .frame(height: Self.height)
        .background(theme.surfaceHigh)
        .overlay(Rectangle().stroke(theme.onSurface, lineWidth: Self.border))
        .accessibilityElement(children: .contain)
    }
}
