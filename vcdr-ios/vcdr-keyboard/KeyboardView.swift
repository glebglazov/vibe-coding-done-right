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

                    // Right: capture button (during recording in assistant mode) + action button
                    DictateActionButton(
                        dictationState: controller.dictationState,
                        showCapture: controller.aiActive && controller.aiMode == .assistant,
                        captureCount: controller.captureCount,
                        onStart: { controller.captureSelectedTextAndOpenRecord() },
                        onStop: { controller.stopAndWaitForResult() },
                        onInsert: { controller.insertPendingText() },
                        onCapture: { controller.captureSelectedText() }
                    )
                    .padding(.trailing, 10)
                }
                .padding(.top, 2)
                .padding(.bottom, 6)
            }
        )
        .keyboardToolbarStyle(.init(height: 50))
    }
}

/// Settings pills displayed on the left side of the toolbar.
struct DictateSettingsPills: View {
    private static let pillHeight: CGFloat = 36
    private static let pillFont: CGFloat = 12
    private static let pillBorder: CGFloat = 1.5

    @ObservedObject var controller: KeyboardViewController

    var body: some View {
        HStack(spacing: 8) {
            if controller.aiConfigured {
                Button {
                    KeyboardHaptics.light()
                    controller.toggleAI()
                } label: {
                    sonicPill(
                        icon: "sparkles",
                        text: controller.aiActive ? "ON" : "OFF",
                        filled: controller.aiActive
                    )
                }

                if controller.aiActive {
                    Button {
                        KeyboardHaptics.light()
                        controller.cycleAIMode()
                    } label: {
                        sonicPill(text: controller.aiMode.displayName.uppercased())
                    }
                }
            }

            Button {
                KeyboardHaptics.light()
                controller.toggleTextStyle()
            } label: {
                sonicPill(text: controller.textStyle.displayName.uppercased())
            }
        }
    }

    private func sonicPill(icon: String? = nil, text: String, filled: Bool = false) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .black))
            }
            Text(text)
                .font(.system(size: Self.pillFont, weight: .black))
                .tracking(1.5)
        }
        .foregroundStyle(filled ? Color.white : Color(.label))
        .padding(.horizontal, 12)
        .frame(height: Self.pillHeight)
        .background(Capsule().fill(filled ? Color.blue : Color(.systemGray5)))
        .overlay(Capsule().stroke(Color(.label), lineWidth: Self.pillBorder))

        .contentShape(Capsule())
    }
}

/// Action button (Start/Stop/transcribing/ready) in the toolbar,
/// with an optional Capture button shown during recording in assistant mode.
struct DictateActionButton: View {
    private static let pillHeight: CGFloat = 36
    private static let pillFont: CGFloat = 12
    private static let pillBorder: CGFloat = 1.5

    var dictationState: DictationState
    var showCapture: Bool
    var captureCount: Int
    var onStart: () -> Void
    var onStop: () -> Void
    var onInsert: () -> Void
    var onCapture: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch dictationState {
            case .idle:
                Button {
                    KeyboardHaptics.medium()
                    onStart()
                } label: {
                    actionPill("Start", icon: "mic.fill", color: .blue)
                }
            case .recording:
                if showCapture {
                    Button {
                        onCapture()
                    } label: {
                        capturePill
                    }
                }
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
    }

    /// Capture button: icon only for 1 capture, icon + ×N for 2+.
    private var capturePill: some View {
        HStack(spacing: 3) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 12, weight: .black))
            if captureCount >= 2 {
                Text("×\(captureCount)")
                    .font(.system(size: Self.pillFont, weight: .black))
                    .tracking(1.5)
            }
        }
        .foregroundStyle(captureCount > 0 ? .white : .white.opacity(0.7))
        .padding(.horizontal, captureCount >= 2 ? 10 : 8)
        .frame(height: Self.pillHeight)
        .background(Capsule().fill(Color(.systemGray2)))
        .overlay(Capsule().stroke(Color(.label), lineWidth: Self.pillBorder))

        .contentShape(Capsule())
    }

    private func actionPill(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
            Text(text.uppercased())
                .font(.system(size: Self.pillFont, weight: .black))
                .tracking(1.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: Self.pillHeight)
        .background(Capsule().fill(color))
        .overlay(Capsule().stroke(Color(.label), lineWidth: Self.pillBorder))

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
