import SwiftUI

struct KeyboardView: View {
    let onNextKeyboard: () -> Void
    let onDeleteBackward: () -> Void
    let onSpace: () -> Void
    let onNewline: () -> Void
    let needsInputModeSwitchKey: Bool
    let hasFullAccess: Bool

    // MARK: - Constants
    private static let keyboardHeight: CGFloat = 120
    private static let micButtonSize: CGFloat = 64
    private static let micIconSize: CGFloat = 32
    private static let utilityButtonMinWidth: CGFloat = 56
    private static let utilityButtonHeight: CGFloat = 44
    private static let utilityCornerRadius: CGFloat = 8

    var body: some View {
        VStack(spacing: 8) {
            if !hasFullAccess {
                Text("Enable Full Access in Settings to use voice dictation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            HStack(spacing: 12) {
                if needsInputModeSwitchKey {
                    utilityButton(icon: "globe", action: onNextKeyboard)
                }

                utilityButton(icon: "delete.left", action: onDeleteBackward)

                utilityButton(icon: "space", action: onSpace)
                    .frame(maxWidth: .infinity)

                // SwiftUI Link is the only iOS 18-compatible way to open a URL
                // from a keyboard extension
                Link(destination: SharedConstants.recordDeepLinkURL) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: Self.micIconSize))
                        .foregroundStyle(.white)
                        .frame(width: Self.micButtonSize, height: Self.micButtonSize)
                        .background(.blue, in: Circle())
                }

                utilityButton(icon: "return", action: onNewline)
                    .frame(maxWidth: .infinity)

                // Placeholder for symmetry with globe button
                if needsInputModeSwitchKey {
                    Color.clear
                        .frame(width: Self.utilityButtonMinWidth, height: Self.utilityButtonHeight)
                }
            }
            .frame(height: Self.keyboardHeight)
            .padding(.horizontal)
        }
    }

    private func utilityButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .frame(minWidth: Self.utilityButtonMinWidth, minHeight: Self.utilityButtonHeight)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: Self.utilityCornerRadius))
        }
        .contentShape(Rectangle())
    }
}
