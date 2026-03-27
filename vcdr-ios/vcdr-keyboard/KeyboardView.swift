import SwiftUI

/// Mic icon displayed on the right side of the autocomplete toolbar.
/// Tapping opens the main VCDR app via deep link to start recording.
struct DictateBarView: View {
    // MARK: - Constants
    private static let iconSize: CGFloat = 20
    private static let tapTargetSize: CGFloat = 44
    private static let circleSize: CGFloat = 40

    var body: some View {
        Link(destination: SharedConstants.recordDeepLinkURL) {
            Image(systemName: "mic.fill")
                .font(.system(size: Self.iconSize))
                .foregroundStyle(.white)
                .frame(width: Self.circleSize, height: Self.circleSize)
                .background(Circle().fill(.blue))
                .frame(width: Self.tapTargetSize, height: Self.tapTargetSize)
                .contentShape(Circle())
        }
        .padding(.trailing, 4)
    }
}
