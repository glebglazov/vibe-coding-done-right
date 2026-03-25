import SwiftUI

/// Dictation bar displayed above the KeyboardKit system keyboard.
struct DictateBarView: View {
    let hasFullAccess: Bool

    // MARK: - Constants
    private static let barHeight: CGFloat = 44

    var body: some View {
        if !hasFullAccess {
            Text("Enable Full Access in Settings for voice dictation")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        }

        Link(destination: SharedConstants.recordDeepLinkURL) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.body)
                Text("Dictate")
                    .font(.body.weight(.medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: Self.barHeight)
            .background(.blue, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
    }
}
