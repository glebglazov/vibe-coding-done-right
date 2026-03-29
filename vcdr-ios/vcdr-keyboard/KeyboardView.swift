import KeyboardKit
import SwiftUI

/// Custom keyboard view that fixes iPad bottom row layout
/// (globe and symbols buttons are swapped in KeyboardKit's default iPad layout)
/// and adds the VCDR dictation button in the toolbar.
struct VCDRKeyboardView: View {
    var services: Keyboard.Services
    var state: Keyboard.State

    private var keyboardContext: KeyboardContext { state.keyboardContext }

    /// On iPad, KeyboardKit places `.nextKeyboard` (globe) where `.keyboardType(.numeric)` (symbols)
    /// should be and vice versa. This computed property returns a corrected layout.
    private var correctedLayout: KeyboardLayout {
        var layout = KeyboardLayout.standard(for: keyboardContext)
        guard keyboardContext.deviceTypeForKeyboard == .pad else { return layout }

        let bottomIdx = layout.bottomRowIndex
        guard bottomIdx >= 0, bottomIdx < layout.itemRows.count else { return layout }

        if let globeIdx = layout.itemRows[bottomIdx].index(of: .nextKeyboard),
           let symbolsIdx = layout.itemRows[bottomIdx].index(of: .keyboardType(.numeric)) {
            layout.itemRows[bottomIdx].swapAt(globeIdx, symbolsIdx)
        }
        return layout
    }

    var body: some View {
        KeyboardView(
            layout: correctedLayout,
            services: services,
            buttonContent: { $0.view },
            buttonView: { $0.view },
            collapsedView: { $0.view },
            emojiKeyboard: { $0.view },
            toolbar: { params in
                HStack(spacing: 0) {
                    params.view
                    DictateBarView()
                }
            }
        )
    }
}

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
