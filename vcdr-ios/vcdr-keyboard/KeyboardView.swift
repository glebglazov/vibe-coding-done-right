import SwiftUI

struct KeyboardView: View {
    let onNextKeyboard: () -> Void
    let onDeleteBackward: () -> Void
    let onNewline: () -> Void
    let needsInputModeSwitchKey: Bool
    let hasFullAccess: Bool

    // MARK: - Constants
    private static let keyboardHeight: CGFloat = 120
    private static let micButtonSize: CGFloat = 64
    private static let micIconSize: CGFloat = 32
    private static let utilityButtonSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 8) {
            if !hasFullAccess {
                Text("Enable Full Access in Settings to use voice dictation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            HStack(spacing: 16) {
                if needsInputModeSwitchKey {
                    Button(action: onNextKeyboard) {
                        Image(systemName: "globe")
                            .font(.title2)
                            .frame(width: Self.utilityButtonSize, height: Self.utilityButtonSize)
                    }
                }

                Spacer()

                Button(action: onDeleteBackward) {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .frame(width: Self.utilityButtonSize, height: Self.utilityButtonSize)
                }

                // SwiftUI Link is the only iOS 18-compatible way to open a URL
                // from a keyboard extension
                Link(destination: SharedConstants.recordDeepLinkURL) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: Self.micIconSize))
                        .foregroundStyle(.white)
                        .frame(width: Self.micButtonSize, height: Self.micButtonSize)
                        .background(.blue, in: Circle())
                }

                Button(action: onNewline) {
                    Image(systemName: "return")
                        .font(.title2)
                        .frame(width: Self.utilityButtonSize, height: Self.utilityButtonSize)
                }

                Spacer()

                // Placeholder for symmetry with globe button
                if needsInputModeSwitchKey {
                    Color.clear
                        .frame(width: Self.utilityButtonSize, height: Self.utilityButtonSize)
                }
            }
            .frame(height: Self.keyboardHeight)
            .padding(.horizontal)
        }
    }
}
