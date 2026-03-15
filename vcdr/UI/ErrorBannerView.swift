import SwiftUI

struct ErrorBannerView: View {
    // MARK: - Constants

    private static let iconSize: CGFloat = 11
    private static let fontSize: CGFloat = 11
    private static let dismissIconSize: CGFloat = 9
    private static let hPadding: CGFloat = 8
    private static let vPadding: CGFloat = 4
    private static let copiedFeedbackDuration: Duration = .seconds(1)

    let message: String
    let onDismiss: () -> Void

    @State private var showCopied = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Self.iconSize))
                .foregroundStyle(.red)

            Text(showCopied ? "Copied" : message)
                .font(.system(size: Self.fontSize))
                .foregroundStyle(showCopied ? Color.secondary : Color.red)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: Self.dismissIconSize))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Self.hPadding)
        .padding(.vertical, Self.vPadding)
        .contentShape(Rectangle())
        .onTapGesture {
            ClipboardHelper.writeString(message)
            showCopied = true
            Task {
                try? await Task.sleep(for: Self.copiedFeedbackDuration)
                showCopied = false
            }
        }
    }
}
