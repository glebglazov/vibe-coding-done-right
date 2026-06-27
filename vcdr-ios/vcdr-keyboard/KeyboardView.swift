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

                    // Right: capture button (during recording in any AI mode) + action button
                    DictateActionButton(
                        dictationState: controller.dictationState,
                        showCapture: true,
                        captureCount: controller.captureCount,
                        onStart: { controller.startRecordingFromKeyboard() },
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
        .keyboardToolbarStyle(.init(height: 44))
    }
}

/// Settings pills displayed on the left side of the toolbar.
struct DictateSettingsPills: View {
    private static let pillHeight: CGFloat = 32
    private static let pillFont: CGFloat = 11
    private static let pillBorder: CGFloat = 1.5

    @ObservedObject var controller: KeyboardViewController

    /// All three labels of the AI mode pill, used to reserve a fixed pill width
    /// so cycling between states doesn't reflow the toolbar.
    private static let aiModeLabels = ["VERBATIM", "DICTATION", "ASSISTANT"]

    var body: some View {
        HStack(spacing: 8) {
            if controller.aiConfigured {
                Button {
                    KeyboardHaptics.light()
                    controller.cycleAIState()
                } label: {
                    sonicPill(
                        icon: "sparkles",
                        text: controller.aiMode.displayName.uppercased(),
                        sizingTexts: Self.aiModeLabels,
                        filled: controller.aiMode != .verbatim
                    )
                }
            }

            if controller.aiMode != .assistant {
                Button {
                    KeyboardHaptics.light()
                    controller.cycleTextStyle()
                } label: {
                    sonicPill(text: controller.textStyle.displayName.uppercased())
                }
            }
        }
    }

    private func sonicPill(
        icon: String? = nil,
        text: String,
        sizingTexts: [String]? = nil,
        filled: Bool = false
    ) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .black))
            }
            ZStack {
                if let sizingTexts {
                    ForEach(sizingTexts, id: \.self) { t in
                        pillText(t).opacity(0)
                    }
                }
                pillText(text)
            }
        }
        .foregroundStyle(filled ? Color.white : Color(.label))
        .padding(.horizontal, 10)
        .frame(height: Self.pillHeight)
        .background(Capsule().fill(filled ? Color.blue : Color(.systemGray5)))
        .overlay(Capsule().stroke(Color(.label), lineWidth: Self.pillBorder))

        .contentShape(Capsule())
    }

    private func pillText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Self.pillFont, weight: .black))
            .tracking(0.5)
    }
}

/// Action button (Start/Stop/transcribing/ready) in the toolbar,
/// with an optional Capture button shown during recording in assistant mode.
struct DictateActionButton: View {
    private static let pillHeight: CGFloat = 32
    private static let pillFont: CGFloat = 11
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
                actionPill("", icon: "ellipsis", color: .orange)
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

    /// Capture button: icon only for 0 captures, icon + ×N for 1+.
    private var capturePill: some View {
        HStack(spacing: 3) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11, weight: .black))
            if captureCount >= 1 {
                Text("×\(captureCount)")
                    .font(.system(size: Self.pillFont, weight: .black))
                    .tracking(0.5)
            }
        }
        .foregroundStyle(captureCount > 0 ? .white : .white.opacity(0.7))
        .padding(.horizontal, captureCount >= 1 ? 8 : 6)
        .frame(height: Self.pillHeight)
        .background(Capsule().fill(captureCount > 0 ? Color.blue : Color(.systemGray2)))
        .overlay(Capsule().stroke(Color(.label), lineWidth: Self.pillBorder))

        .contentShape(Capsule())
    }

    private func actionPill(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .black))
            if !text.isEmpty {
                Text(text.uppercased())
                    .font(.system(size: Self.pillFont, weight: .black))
                    .tracking(0.5)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: Self.pillHeight)
        .background(Capsule().fill(color))
        .overlay(Capsule().stroke(Color(.label), lineWidth: Self.pillBorder))

        .contentShape(Capsule())
    }
}

// MARK: - Haptic Feedback

/// Haptic feedback for keyboard-extension buttons.
///
/// Why this is non-trivial in a keyboard extension: `UIImpactFeedbackGenerator(style:)`
/// (the legacy initializer) resolves its haptic engine via the host process's
/// key window. A keyboard extension's input view doesn't live in that key
/// window — it lives in its own scene — so the legacy initializer binds to
/// either nothing or the wrong context, and impacts are dropped silently.
/// `prepare()` and long-lived references can't fix a generator that never
/// had a usable scene to begin with (the failure mode in PRs #25 and #29).
///
/// The iOS 17.5+ `init(view:style:)` form lets the system bind the generator
/// to a specific view's window/scene. Apple's docs call this out explicitly
/// for "apps that support multiple scenes or are running in a window that
/// isn't on the main screen" — the textbook description of a keyboard
/// extension. Call `attach(to:)` from `viewDidLoad` once the controller's
/// view exists; the generators are then long-lived for the process lifetime.
///
/// We still hold long-lived references and re-`prepare()` after each impact
/// to keep the haptic-engine XPC connection warm — that part of PR #29 is
/// independently useful for latency, just not sufficient on its own.
///
/// `isEnabled` is cached and refreshed via `refreshEnabled()` from
/// `handleSettingsChanged` (after `synchronize()`), so the per-call hot path
/// is a bool read rather than a cross-process `UserDefaults` round-trip.
enum KeyboardHaptics {
    private static var lightGenerator: UIImpactFeedbackGenerator?
    private static var mediumGenerator: UIImpactFeedbackGenerator?

    /// Cached enabled flag. Refresh via `refreshEnabled()` whenever the
    /// settings notification fires.
    private static var isEnabled: Bool = SessionSettings.effectiveKeyboardHapticsEnabled()

    /// Reads the current value from shared defaults into the cache. Call
    /// from `KeyboardViewController.handleSettingsChanged` after the
    /// `synchronize()` so changes from the main app's Settings UI take
    /// effect on the next tap.
    static func refreshEnabled() {
        isEnabled = SessionSettings.effectiveKeyboardHapticsEnabled()
    }

    /// Builds the long-lived generators bound to the extension's own
    /// view/scene via iOS 17.5+ `init(view:style:)`. Without this, the
    /// generators bind to the host app's key window (or nothing) and
    /// impacts are dropped silently.
    ///
    /// **Must be called when `view.window` is non-nil** — i.e. from
    /// `viewWillAppear` or later, NOT `viewDidLoad`. The legacy initializer
    /// is forgiving about scene context; the `view:` form binds to a real
    /// scene at construction time and a windowless view binds to nothing.
    ///
    /// Idempotent: subsequent calls are no-ops, so PR #29's long-lived
    /// warming holds across re-appearances.
    static func attach(to view: UIView) {
        if lightGenerator == nil {
            lightGenerator = UIImpactFeedbackGenerator(style: .light, view: view)
        }
        if mediumGenerator == nil {
            mediumGenerator = UIImpactFeedbackGenerator(style: .medium, view: view)
        }
        prepare()
    }

    /// Warms the haptic engine. Cheap once warm; pays the cold-daemon cost
    /// the first time the keyboard process spins up. Call from view
    /// lifecycle hooks and on transitions to `.transcribing`.
    static func prepare() {
        guard isEnabled else { return }
        lightGenerator?.prepare()
        mediumGenerator?.prepare()
    }

    static func light() {
        guard isEnabled else { return }
        lightGenerator?.impactOccurred()
        lightGenerator?.prepare()
    }

    static func medium() {
        guard isEnabled else { return }
        mediumGenerator?.impactOccurred()
        mediumGenerator?.prepare()
    }

    static func success() {
        guard isEnabled else { return }
        mediumGenerator?.impactOccurred()
        mediumGenerator?.prepare()
    }
}
