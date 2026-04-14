import KeyboardKit
import SwiftUI
import UIKit

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
            toolbar: { _ in
                HStack {
                    // Left: settings pills
                    DictateSettingsPills(controller: controller)
                        .padding(.leading, 10)

                    Spacer()

                    // Right: action button
                    DictateActionButton(
                        dictationState: controller.dictationState,
                        onStart: { controller.captureSelectedTextAndOpenRecord() },
                        onStop: { controller.stopAndWaitForResult() },
                        onInsert: { controller.insertPendingText() }
                    )
                    .padding(.trailing, 10)
                }
                .padding(.bottom, 6)
            }
        )
        .keyboardToolbarStyle(.init(height: 44))
    }
}

/// Settings pills displayed on the left side of the toolbar.
struct DictateSettingsPills: View {
    private static let pillHeight: CGFloat = 38
    private static let pillFont: CGFloat = 13

    @ObservedObject var controller: KeyboardViewController

    var body: some View {
        HStack(spacing: 4) {
            if controller.aiConfigured {
                Button {
                    KeyboardHaptics.light()
                    controller.toggleAI()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13))
                        Text(controller.aiActive ? "ON" : "OFF")
                            .font(.system(size: Self.pillFont, weight: .bold))
                    }
                    .foregroundStyle(controller.aiActive ? .blue : .gray)
                    .padding(.horizontal, 10)
                    .frame(height: Self.pillHeight)
                    .background(Capsule().fill(Color(.systemGray5)))
                    .contentShape(Capsule())
                }

                if controller.aiActive {
                    Button {
                        KeyboardHaptics.light()
                        controller.cycleAIMode()
                    } label: {
                        HStack(spacing: 4) {
                            Text(controller.aiMode.displayName.uppercased())
                                .font(.system(size: Self.pillFont, weight: .bold))
                            if controller.hasSelectedText {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 12))
                            }
                        }
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .frame(height: Self.pillHeight)
                        .background(Capsule().fill(Color(.systemGray5)))
                        .contentShape(Capsule())
                    }
                }
            }

            Button {
                KeyboardHaptics.light()
                controller.toggleTextStyle()
            } label: {
                Text(controller.textStyle.displayName.uppercased())
                    .font(.system(size: Self.pillFont, weight: .bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .frame(height: Self.pillHeight)
                    .background(Capsule().fill(Color(.systemGray5)))
                    .contentShape(Capsule())
            }
        }
    }
}

/// Action button (Start/Stop/transcribing/ready) in the toolbar.
struct DictateActionButton: View {
    private static let pillHeight: CGFloat = 38
    private static let pillFont: CGFloat = 13

    var dictationState: DictationState
    var onStart: () -> Void
    var onStop: () -> Void
    var onInsert: () -> Void

    var body: some View {
        switch dictationState {
        case .idle:
            Button {
                KeyboardHaptics.medium()
                onStart()
            } label: {
                actionPill("Start", icon: "mic.fill", color: .blue)
            }
        case .recording:
            Button {
                KeyboardHaptics.medium()
                onStop()
            } label: {
                actionPill("Stop", icon: "stop.fill", color: .red)
            }
        case .transcribing:
            actionPill("Processing", icon: "ellipsis", color: .orange)
                .phaseAnimator([false, true]) { content, phase in
                    content.opacity(phase ? 0.4 : 1.0)
                } animation: { _ in
                    .easeInOut(duration: 0.6)
                }
        case .ready:
            Button {
                KeyboardHaptics.medium()
                onInsert()
            } label: {
                actionPill("Insert", icon: "checkmark", color: .green)
            }
        case .emptyResult:
            Button {
                KeyboardHaptics.medium()
                onStart()
            } label: {
                actionPill("Start", icon: "mic.fill", color: .yellow)
            }
        }
    }

    private func actionPill(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 13))
            Text(text.uppercased())
                .font(.system(size: Self.pillFont, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: Self.pillHeight)
        .background(Capsule().fill(color))
        .contentShape(Capsule())
    }
}

// MARK: - Haptic Feedback

/// Lightweight haptic feedback for keyboard extension buttons.
enum KeyboardHaptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
