import SwiftUI

struct KeyboardView: View {
    let onNextKeyboard: () -> Void
    let needsInputModeSwitchKey: Bool
    let hasFullAccess: Bool

    // MARK: - Constants
    private static let keyboardHeight: CGFloat = 120
    private static let micButtonSize: CGFloat = 64
    private static let micIconSize: CGFloat = 32

    var body: some View {
        VStack(spacing: 8) {
            if !hasFullAccess {
                Text("Enable Full Access in Settings to use voice dictation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            HStack(spacing: 20) {
                if needsInputModeSwitchKey {
                    Button(action: onNextKeyboard) {
                        Image(systemName: "globe")
                            .font(.title2)
                            .padding()
                    }
                }

                Spacer()

                // SwiftUI Link is the only iOS 18-compatible way to open a URL
                // from a keyboard extension
                Link(destination: SharedConstants.recordDeepLinkURL) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: Self.micIconSize))
                        .foregroundStyle(.white)
                        .frame(width: Self.micButtonSize, height: Self.micButtonSize)
                        .background(.blue, in: Circle())
                }

                Spacer()

                // Placeholder for symmetry
                if needsInputModeSwitchKey {
                    Color.clear
                        .frame(width: 44, height: 44)
                }
            }
            .frame(height: Self.keyboardHeight)
            .padding(.horizontal)
        }
    }
}
