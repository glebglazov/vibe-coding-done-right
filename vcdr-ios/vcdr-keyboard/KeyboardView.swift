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
            collapsedView: { _ in
                CompactKeyboardView(controller: controller, reachability: controller.reachability)
            },
            emojiKeyboard: { $0.view },
            toolbar: { _ in
                // Never render the strip in Compact: the pills already live
                // in the compact view, and a toolbar that leaked through
                // would show them twice.
                if keyboardContext.isKeyboardCollapsed {
                    EmptyView()
                } else {
                    FullKeyboardToolbar(controller: controller, reachability: controller.reachability)
                }
            }
        )
        .keyboardToolbarStyle(keyboardContext.isKeyboardCollapsed
            ? .init(height: 0, minHeight: 0)
            : .init(height: KeyboardDisplayModeManager.fullToolbarHeight))
        // Compact draws no keys, so KeyboardKit's opaque keyboard background
        // has nothing to sit behind — hiding it lets the host app show through
        // the strip. Full keeps it: the key rows need it for contrast.
        .keyboardViewBackground(keyboardContext.isKeyboardCollapsed ? .hidden : .automatic)
    }
}

/// The Full Keyboard's toolbar strip: one line carrying the status slot and
/// the dictation controls. Lives in its own view rather than inline in the
/// `toolbar:` builder because it holds the Discard Warning wash state — the
/// strip is what reddens while the Stop pill is held, and the strip's own
/// background is opaque, so the wash simply tints it.
struct FullKeyboardToolbar: View {
    @ObservedObject var controller: KeyboardViewController
    @ObservedObject var reachability: KeyboardReachabilityMonitor
    @State private var wash = DiscardWarningWashState()
    @State private var narration = HoldNarrationState()

    var body: some View {
        HStack {
            // Left: settings pills, yielding to the Discard Hint during a hold
            KeyboardStripLeading(controller: controller, narration: narration)
                .padding(.leading, 10)

            Spacer()

            // Right: capture button (during recording in any AI mode) + action button
            DictateActionButton(
                dictationState: controller.dictationState,
                recordsInPlace: reachability.recordsInPlace,
                showCapture: true,
                captureCount: controller.captureCount,
                onStart: { controller.startRecordingFromKeyboard() },
                onStop: { controller.stopAndWaitForResult() },
                onDiscard: {
                    wash.beginDiscardUnwind()
                    narration.end()
                    controller.discardRecordingFromKeyboard()
                },
                onInsert: { controller.insertPendingText() },
                onCapture: { controller.captureSelectedText() },
                onShowFailure: { controller.showFailureReason() },
                onHintBegan: { narration.beginHint() },
                onWarningRamp: {
                    wash.ramp(to: $0)
                    narration.ramp(to: $0)
                },
                onWarningEnd: {
                    wash.end()
                    narration.end()
                }
            )

            KeyboardModeToggleButton(direction: .collapse) {
                controller.collapseKeyboard()
            }
            .padding(.trailing, 10)
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
        .discardWarningWash(progress: wash.progress)
        // Belt-and-braces: whatever ends the run, neither the wash nor the
        // hold narration can outlive it.
        .onChange(of: controller.dictationState) { _, newState in
            if newState != .recording {
                wash.end()
                narration.end()
            }
        }
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

/// Chevron pill that flips display mode without a reload: down at the right
/// end of the Full toolbar, up at the right end of the Compact row. One view
/// for both directions so the two ends of the toggle can't drift apart.
struct KeyboardModeToggleButton: View {
    enum Direction {
        case collapse, expand

        var icon: String {
            switch self {
            case .collapse: "chevron.down"
            case .expand: "chevron.up"
            }
        }
    }

    private static let pillHeight: CGFloat = 32
    private static let pillWidth: CGFloat = 36
    private static let pillBorder: CGFloat = 1.5
    private static let iconSize: CGFloat = 12

    var direction: Direction
    var onToggle: () -> Void

    var body: some View {
        Button {
            KeyboardHaptics.light()
            onToggle()
        } label: {
            Image(systemName: direction.icon)
                .font(.system(size: Self.iconSize, weight: .black))
                .foregroundStyle(Color(.label))
                .frame(width: Self.pillWidth, height: Self.pillHeight)
                .background(Capsule().fill(Color(.systemGray5)))
                .overlay(Capsule().stroke(Color(.label), lineWidth: Self.pillBorder))
                .contentShape(Capsule())
        }
    }
}

/// Capture button shown during recording: icon only for 0 captures,
/// icon + ×N for 1+. Appends the current text selection to the session's
/// captures; used by the Full toolbar strip and the Compact strip alike.
struct DictateCaptureButton: View {
    private static let pillHeight: CGFloat = 32
    private static let pillFont: CGFloat = 11
    private static let pillBorder: CGFloat = 1.5

    var captureCount: Int
    var onCapture: () -> Void

    var body: some View {
        Button {
            onCapture()
        } label: {
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
    }
}

/// Action button (Start/Stop/transcribing/ready) in the toolbar,
/// with an optional Capture button shown during recording in assistant mode.
struct DictateActionButton: View {
    private static let pillHeight: CGFloat = 32
    private static let pillFont: CGFloat = 11
    private static let pillBorder: CGFloat = 1.5

    var dictationState: DictationState
    /// Whether a tap on the record control records in place, straight from the
    /// predicate the tap itself reads.
    var recordsInPlace: Bool
    var showCapture: Bool
    var captureCount: Int
    var onStart: () -> Void
    var onStop: () -> Void
    var onDiscard: () -> Void
    var onInsert: () -> Void
    var onCapture: () -> Void
    var onShowFailure: () -> Void
    /// Fires a quarter-second into a hold, before anything animates, so the
    /// strip can put the Discard Hint where the settings pills sit.
    var onHintBegan: () -> Void = {}
    /// Forwarded from the Stop pill's hold so the surrounding strip — not the
    /// pill under the thumb — can carry the Discard Warning.
    var onWarningRamp: (CGFloat) -> Void = { _ in }
    var onWarningEnd: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            switch dictationState {
            case .idle:
                recordButton(color: .blue)
            case .recording:
                if showCapture {
                    DictateCaptureButton(captureCount: captureCount, onCapture: onCapture)
                }
                HoldToDiscardStopPill(
                    text: "Stop",
                    icon: "stop.fill",
                    color: .red,
                    onStop: onStop,
                    onDiscard: onDiscard,
                    onDiscardHaptic: { KeyboardHaptics.medium() },
                    onHintBegan: onHintBegan,
                    onWarningRamp: onWarningRamp,
                    onWarningEnd: onWarningEnd
                )
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
                recordButton(color: .yellow)
            case .cancelled:
                actionPill("CANCELLED", icon: "xmark", color: .gray)
            case .failed:
                // Red, and only "FAILED" — the reason lives in the app, which
                // has room to show it in full (ADR-0004).
                Button {
                    KeyboardHaptics.medium()
                    onShowFailure()
                } label: {
                    actionPill(
                        "FAILED",
                        icon: "exclamationmark.triangle.fill",
                        trailingIcon: "chevron.right",
                        color: .red
                    )
                }
                .accessibilityLabel("Failed")
                .accessibilityHint("Opens VCDR to show the reason")
            }
        }
    }

    /// The record control, lit when a tap records in place and unlit when it
    /// will open the app instead. Only this control carries the glow: every
    /// other pill describes a run that has already started, where the question
    /// of where the next tap lands does not arise.
    private func recordButton(color: Color) -> some View {
        Button {
            KeyboardHaptics.medium()
            onStart()
        } label: {
            actionPill("Start", icon: "mic.fill", color: color)
                .recordReachabilityGlow(isLit: recordsInPlace, color: color)
        }
        .accessibilityLabel("Start")
        .accessibilityHint(
            recordsInPlace
                ? "Records here, without leaving the keyboard"
                : "Opens VCDR to record"
        )
    }

    private func actionPill(
        _ text: String,
        icon: String,
        trailingIcon: String? = nil,
        color: Color
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .black))
            if !text.isEmpty {
                Text(text.uppercased())
                    .font(.system(size: Self.pillFont, weight: .black))
                    .tracking(0.5)
            }
            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.system(size: 9, weight: .black))
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

/// Stop pill with hold-to-Discard: release before the threshold stops.
///
/// The pill draws no warning of its own — a thumb covers it, so progress there
/// cannot be read. It reports the ramp outwards via `onWarningRamp`/
/// `onWarningEnd` and the strip around it carries the whole cue.
struct HoldToDiscardStopPill: View {
    private static let pillHeight: CGFloat = 32
    private static let pillFont: CGFloat = 11
    private static let pillBorder: CGFloat = 1.5

    let text: String
    let icon: String
    let color: Color
    let onStop: () -> Void
    let onDiscard: () -> Void
    let onDiscardHaptic: () -> Void
    let onHintBegan: () -> Void
    let onWarningEnd: () -> Void

    @State private var holdController: HoldToDiscardController
    @State private var isPressed = false
    /// Boxed so the controller's ramp closure and the gesture can share it.
    /// Held in `@State` (not a plain `let`) so re-inits of this view struct —
    /// which happen ~60×/s while the ramp drives `DiscardWarningWashState`'s
    /// progress — don't hand the gesture a fresh, disconnected box each render.
    @State private var ladder: HapticLadderBox

    init(
        text: String,
        icon: String,
        color: Color,
        onStop: @escaping () -> Void,
        onDiscard: @escaping () -> Void,
        onDiscardHaptic: @escaping () -> Void = {},
        onHintBegan: @escaping () -> Void = {},
        onWarningRamp: @escaping (CGFloat) -> Void = { _ in },
        onWarningEnd: @escaping () -> Void = {}
    ) {
        self.text = text
        self.icon = icon
        self.color = color
        self.onStop = onStop
        self.onDiscard = onDiscard
        self.onDiscardHaptic = onDiscardHaptic
        self.onHintBegan = onHintBegan
        self.onWarningEnd = onWarningEnd
        let ladder = HapticLadderBox()
        _ladder = State(initialValue: ladder)
        _holdController = State(
            initialValue: HoldToDiscardController(
                onStop: onStop,
                onDiscard: onDiscard,
                onDiscardHaptic: onDiscardHaptic,
                onWarningRamp: { progress in
                    onWarningRamp(progress)
                    // `KeyboardHaptics.light()` is a no-op when the user has
                    // haptics off, so the ladder simply vanishes there.
                    for _ in 0..<ladder.ticks(upTo: progress) { KeyboardHaptics.light() }
                }
            )
        )
    }

    var body: some View {
        @Bindable var hold = holdController

        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: Self.pillFont, weight: .black))
            Text(text.uppercased())
                .font(.system(size: Self.pillFont, weight: .black))
                .tracking(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: Self.pillHeight)
        .background(Capsule().fill(color))
        .overlay(Capsule().stroke(Color(.label), lineWidth: Self.pillBorder))
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Discard recording") {
            holdController.discardImmediately()
        }
        .onAppear { KeyboardHaptics.prepare() }
        .onChange(of: hold.isHinting) { _, hinting in
            if hinting { onHintBegan() }
        }
        .onChange(of: hold.isWarning) { _, warning in
            if !warning {
                ladder.reset()
                onWarningEnd()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    ladder.reset()
                    holdController.touchDown()
                }
                .onEnded { _ in
                    guard isPressed else { return }
                    isPressed = false
                    holdController.touchUp()
                    // Fire the retreat straight from the release rather than
                    // only from the `isWarning` `onChange` below, which lands
                    // a render pass later. `onWarningEnd()` is idempotent, so
                    // the `onChange` still firing afterward is a no-op.
                    ladder.reset()
                    onWarningEnd()
                }
        )
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
