import KeyboardKit
import SwiftUI

/// Custom keyboard view that fixes iPad bottom row layout
/// (globe and symbols buttons are swapped in KeyboardKit's default iPad layout)
/// and adds the VCDR dictation button in the toolbar.
struct VCDRKeyboardView: View {
    var services: Keyboard.Services
    var state: Keyboard.State
    @ObservedObject var controller: KeyboardViewController

    /// Observed so the view re-renders when keyboard case changes,
    /// ensuring `correctedLayout` is recomputed with the current shift state.
    @ObservedObject private var keyboardContext: KeyboardContext

    init(services: Keyboard.Services, state: Keyboard.State, controller: KeyboardViewController) {
        self.services = services
        self.state = state
        self.controller = controller
        self._keyboardContext = ObservedObject(wrappedValue: state.keyboardContext)
    }

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
                    DictateBarView(
                        dictationState: controller.dictationState,
                        onStop: { controller.stopAndWaitForResult() },
                        onInsert: { controller.insertPendingText() }
                    )
                }
            }
        )
    }
}

/// State-aware dictation button displayed on the right side of the autocomplete toolbar.
/// - Idle: blue mic — opens VCDR via deep link to start recording
/// - Recording: red stop — sends stop command to the main app
/// - Transcribing: pulsing indicator while the app processes
/// - Ready: green checkmark — tap inserts transcription text (WisprFlow pattern)
struct DictateBarView: View {
    // MARK: - Constants
    private static let iconSize: CGFloat = 20
    private static let tapTargetSize: CGFloat = 44
    private static let circleSize: CGFloat = 40

    var dictationState: DictationState
    var onStop: () -> Void
    var onInsert: () -> Void

    var body: some View {
        Group {
            switch dictationState {
            case .idle:
                Link(destination: SharedConstants.recordDeepLinkURL) {
                    circleButton(icon: "mic.fill", color: .blue)
                }
            case .recording:
                Button(action: onStop) {
                    circleButton(icon: "stop.fill", color: .red)
                }
            case .transcribing:
                circleButton(icon: "ellipsis", color: .orange)
                    .phaseAnimator([false, true]) { content, phase in
                        content.opacity(phase ? 0.4 : 1.0)
                    } animation: { _ in
                        .easeInOut(duration: 0.6)
                    }
            case .ready:
                Button(action: onInsert) {
                    circleButton(icon: "checkmark", color: .green)
                }
            case .emptyResult:
                Link(destination: SharedConstants.recordDeepLinkURL) {
                    circleButton(icon: "mic.fill", color: .yellow)
                }
            }
        }
        .padding(.trailing, 4)
    }

    private func circleButton(icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: Self.iconSize))
            .foregroundStyle(.white)
            .frame(width: Self.circleSize, height: Self.circleSize)
            .background(Circle().fill(color))
            .frame(width: Self.tapTargetSize, height: Self.tapTargetSize)
            .contentShape(Circle())
    }
}
