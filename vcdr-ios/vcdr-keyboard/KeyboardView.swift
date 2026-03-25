import SwiftUI

struct KeyboardView: View {
    let onInsertText: (String) -> Void
    let onDeleteBackward: () -> Void
    let onNextKeyboard: () -> Void
    let needsInputModeSwitchKey: Bool
    let hasFullAccess: Bool

    @State private var isShifted = true
    @State private var isCapsLock = false

    // MARK: - Layout

    private static let row1 = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
    private static let row2 = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
    private static let row3 = ["z", "x", "c", "v", "b", "n", "m"]

    // MARK: - Constants

    private static let keyHeight: CGFloat = 42
    private static let keySpacing: CGFloat = 6
    private static let rowSpacing: CGFloat = 10
    private static let keyCornerRadius: CGFloat = 5
    private static let micBarHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            if !hasFullAccess {
                Text("Enable Full Access in Settings for voice dictation")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }

            // Mic bar on top
            micBar
                .padding(.horizontal, 4)
                .padding(.bottom, 4)

            // Keyboard rows
            VStack(spacing: Self.rowSpacing) {
                letterRow(Self.row1)
                letterRow(Self.row2)
                shiftRow
                bottomRow
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Mic Bar

    private var micBar: some View {
        Link(destination: SharedConstants.recordDeepLinkURL) {
            HStack {
                Image(systemName: "mic.fill")
                    .font(.body)
                Text("Dictate")
                    .font(.body.weight(.medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: Self.micBarHeight)
            .background(.blue, in: RoundedRectangle(cornerRadius: Self.keyCornerRadius))
        }
    }

    // MARK: - Letter Rows

    private func letterRow(_ letters: [String]) -> some View {
        HStack(spacing: Self.keySpacing) {
            ForEach(letters, id: \.self) { letter in
                keyButton(displayedAs: isShifted || isCapsLock ? letter.uppercased() : letter) {
                    let char = isShifted || isCapsLock ? letter.uppercased() : letter
                    onInsertText(char)
                    if isShifted && !isCapsLock {
                        isShifted = false
                    }
                }
            }
        }
    }

    private var shiftRow: some View {
        HStack(spacing: Self.keySpacing) {
            // Shift key
            Button {
                if isShifted && !isCapsLock {
                    // Single tap while shifted → un-shift
                    isShifted = false
                } else if isCapsLock {
                    isCapsLock = false
                    isShifted = false
                } else {
                    isShifted = true
                }
            } label: {
                Image(systemName: isCapsLock ? "capslock.fill" : (isShifted ? "shift.fill" : "shift"))
                    .font(.body)
                    .frame(maxWidth: .infinity, maxHeight: Self.keyHeight)
                    .background(
                        isShifted || isCapsLock ? Color(.systemBackground) : Color(.systemGray3),
                        in: RoundedRectangle(cornerRadius: Self.keyCornerRadius)
                    )
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    isCapsLock = true
                    isShifted = true
                }
            )
            .frame(maxWidth: .infinity)

            // Letter keys
            ForEach(Self.row3, id: \.self) { letter in
                keyButton(displayedAs: isShifted || isCapsLock ? letter.uppercased() : letter) {
                    let char = isShifted || isCapsLock ? letter.uppercased() : letter
                    onInsertText(char)
                    if isShifted && !isCapsLock {
                        isShifted = false
                    }
                }
            }

            // Backspace key
            Button(action: onDeleteBackward) {
                Image(systemName: "delete.left")
                    .font(.body)
                    .frame(maxWidth: .infinity, maxHeight: Self.keyHeight)
                    .background(Color(.systemGray3), in: RoundedRectangle(cornerRadius: Self.keyCornerRadius))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var bottomRow: some View {
        HStack(spacing: Self.keySpacing) {
            if needsInputModeSwitchKey {
                Button(action: onNextKeyboard) {
                    Image(systemName: "globe")
                        .font(.body)
                        .frame(width: 44, height: Self.keyHeight)
                        .background(Color(.systemGray3), in: RoundedRectangle(cornerRadius: Self.keyCornerRadius))
                }
            }

            // Space bar
            Button { onInsertText(" ") } label: {
                Text("space")
                    .font(.body)
                    .frame(maxWidth: .infinity, maxHeight: Self.keyHeight)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: Self.keyCornerRadius))
            }

            // Return key
            Button {
                onInsertText("\n")
            } label: {
                Image(systemName: "return")
                    .font(.body)
                    .frame(width: 88, height: Self.keyHeight)
                    .background(Color(.systemGray3), in: RoundedRectangle(cornerRadius: Self.keyCornerRadius))
            }
        }
    }

    // MARK: - Key Button

    private func keyButton(displayedAs label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 22, design: .default))
                .frame(maxWidth: .infinity, maxHeight: Self.keyHeight)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: Self.keyCornerRadius))
        }
        .buttonStyle(.plain)
    }
}
