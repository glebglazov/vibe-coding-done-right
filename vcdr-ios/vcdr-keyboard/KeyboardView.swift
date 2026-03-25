import SwiftUI

/// Small mic icon displayed on the right side of the autocomplete toolbar.
struct DictateBarView: View {
    let hasFullAccess: Bool

    // MARK: - Constants
    private static let iconSize: CGFloat = 20
    private static let tapTargetSize: CGFloat = 36

    var body: some View {
        Link(destination: SharedConstants.recordDeepLinkURL) {
            Image(systemName: "mic.fill")
                .font(.system(size: Self.iconSize))
                .foregroundStyle(.blue)
                .frame(width: Self.tapTargetSize, height: Self.tapTargetSize)
        }
        .padding(.trailing, 4)
    }
}
