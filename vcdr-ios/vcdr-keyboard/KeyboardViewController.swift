import Combine
import KeyboardKit
import SwiftUI
import UIKit

/// Keyboard-side dictation state, derived from the main app's recording state.
enum DictationState {
    case idle
    case recording
    case transcribing
    /// Transcription text available — waiting for user tap to insert
    case ready
    /// Recording produced no speech — shown briefly before reverting to idle
    case emptyResult
}

class KeyboardViewController: KeyboardInputViewController, ObservableObject {

    /// Current dictation state — drives the DictateBarView appearance.
    ///
    /// Re-warms the haptic engine on every transition into `.transcribing`
    /// so the success impact fired from inside `stopAndWaitForResult`'s
    /// `RunLoop.main.run(until:)` poll lands on a primed engine. The keyboard
    /// extension's daemon connection goes cold quickly, so without this the
    /// insertion haptic is the most likely to drop.
    @Published var dictationState: DictationState = .idle {
        didSet {
            if dictationState == .transcribing, oldValue != .transcribing {
                KeyboardHaptics.prepare()
            }
        }
    }

    // MARK: - Shared Settings (keyboard ↔ app)
    @Published var aiConfigured: Bool = false
    /// Source of truth for the AI/Verbatim pill. `.verbatim` ↔ "AI off".
    @Published var aiMode: SharedAIMode = .verbatim
    @Published var textStyle: SharedTextStyle = .casual

    /// True when the text field has a non-empty selection and assistant mode is active.
    /// Drives the selection indicator icon in the toolbar.
    @Published var hasSelectedText: Bool = false

    /// Number of text selections captured in the current recording session (assistant mode).
    @Published var captureCount: Int = 0

    /// Text waiting to be inserted via tap-to-paste.
    private var pendingText: String?
    private let keyboardChannel = KeyboardChannel.live

    /// Owns the Compact/Full display mode: persistence, the KeyboardKit
    /// collapse flag, and the Compact height constraint.
    private var displayModeManager: KeyboardDisplayModeManager?

    override func viewDidLoad() {
        super.viewDidLoad()
        setup(for: .vcdr)

        // Land in the persisted display mode before the first frame — absent
        // key reads as Compact, so fresh installs and installs that used the
        // keyboard before Compact existed both open collapsed.
        let modeManager = KeyboardDisplayModeManager(
            keyboardContext: state.keyboardContext,
            inputView: view
        )
        modeManager.activate()
        displayModeManager = modeManager

        // Refresh the cached enabled flag now; haptic generator construction
        // is deferred to `viewWillAppear` because the iOS 17.5+
        // `UIImpactFeedbackGenerator(view:style:)` needs `view.window` to be
        // non-nil at construction time — and at `viewDidLoad` it isn't yet.
        KeyboardHaptics.refreshEnabled()

        // Listen for recording state changes from the main app.
        // Text is delivered via state bundling ("idle|text") on this same channel.
        DarwinNotificationCenter.observe(
            KeyboardChannel.stateNotificationName,
            localName: .darwinStateChanged
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleStateChanged),
            name: .darwinStateChanged, object: nil
        )

        // Listen for settings changes from the main app (mode/style toggled in-session).
        DarwinNotificationCenter.observe(
            SharedConstants.settingsNotificationName,
            localName: .darwinSettingsChanged
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSettingsChanged),
            name: .darwinSettingsChanged, object: nil
        )
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        refreshSelectedTextIndicator()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refreshSelectedTextIndicator()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Mitigate the brownish background flash on keyboard load.
        // KeyboardKit only clears the child UIHostingController's view background,
        // not the parent view or inputView. This is a known iOS/KeyboardKit issue
        // (KeyboardKit#1008) with no full fix yet — this reduces but does not
        // fully eliminate the flash.
        view.backgroundColor = .clear
        inputView?.backgroundColor = .clear

        // Force cross-process defaults sync to avoid stale state flash
        // (e.g. reading "recording" from a previous session before sync completes)
        SharedConstants.sharedDefaults.synchronize()
        refreshState()
        refreshSettings()
        refreshSelectedTextIndicator()

        // First call here builds the long-lived generators bound to this
        // view's window/scene (iOS 17.5+ `init(view:style:)`); subsequent
        // calls are no-op + `prepare()`. `viewWillAppear` is the earliest
        // hook where `view.window` is guaranteed non-nil, which is what
        // the scene-aware initializer needs.
        KeyboardHaptics.refreshEnabled()
        KeyboardHaptics.attach(to: view)
        // viewWillAppear provides a fresh textDocumentProxy connection —
        // auto-insert if text is pending (handles the case where the keyboard
        // wasn't visible when the transcription arrived).
        if pendingText != nil {
            insertPendingText()
        }

        // The system can drop view constraints between appearances (rotation,
        // dock changes) — re-pin the Compact height if we're collapsed.
        displayModeManager?.reassertHeight()
    }

    // MARK: - State Parsing

    @objc private func handleStateChanged() {
        refreshState()
    }

    @objc private func handleSettingsChanged() {
        SharedConstants.sharedDefaults.synchronize()
        refreshSettings()
        refreshSelectedTextIndicator()
        // The Settings UI may have toggled the haptics flag — refresh the
        // cached value the per-call hot path reads.
        KeyboardHaptics.refreshEnabled()
    }

    /// Reads the shared state key and updates `dictationState`.
    /// Parses state bundling format: `"idle|transcription text"`.
    private func refreshState() {
        switch keyboardChannel.readState() {
        case .bundledResult(let text):
            if !text.isEmpty {
                pendingText = text
                dictationState = .ready
            } else {
                pendingText = nil
                dictationState = .idle
            }
        case .emptyResult:
            pendingText = nil
            dictationState = .emptyResult
            // Clear the state so it doesn't persist across keyboard appearances
            keyboardChannel.clearResult()
            // Auto-revert to idle after the flash duration
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.emptyResultFlashDuration) { [weak self] in
                guard self?.dictationState == .emptyResult else { return }
                self?.dictationState = .idle
            }
        case .recording:
            pendingText = nil
            dictationState = .recording
        case .transcribing:
            pendingText = nil
            dictationState = .transcribing
        case .idle:
            pendingText = nil
            captureCount = 0
            dictationState = .idle
        }
    }

    // MARK: - Text Insertion

    /// Inserts pending transcription text into the active text field.
    /// Must be called from a UIKit event context (button tap handler) for
    /// `textDocumentProxy.insertText()` to work — this is the WisprFlow pattern.
    func insertPendingText() {
        guard let text = pendingText, !text.isEmpty else { return }
        textDocumentProxy.insertText(text)
        KeyboardHaptics.success()
        // Space is already added by TextPostProcessor.applyTerminator in the pipeline
        pendingText = nil
        dictationState = .idle
        captureCount = 0
        // Clear the bundled text so it isn't re-inserted on next keyboard appearance
        keyboardChannel.clearResult()
    }

    // MARK: - Constants

    /// Maximum time to wait for transcription result within the tap's event context
    private static let insertionTimeout: TimeInterval = 15
    /// Polling interval while waiting for result
    private static let pollInterval: TimeInterval = 0.1
    /// Duration to show the yellow empty-result indicator before reverting to idle
    private static let emptyResultFlashDuration: TimeInterval = 2
    /// Window to wait for the app to confirm a `startRecording` command by
    /// writing `state = .recording`. If nothing by then, fall back to URL.
    /// Tuned for Darwin roundtrip + a MainActor hop under CoreML load.
    private static let startCommandAckTimeout: TimeInterval = 0.4
    /// Same purpose as `startCommandAckTimeout` but for stop. Counted from
    /// when the Darwin command is posted; if the app hasn't moved state out
    /// of `.recording` by then, we assume the command was lost (suspended
    /// app between heartbeat read and Darwin post) and foreground via URL.
    private static let stopCommandAckTimeout: TimeInterval = 0.4

    // MARK: - Commands

    /// Sends a stop command and polls for the transcription result within the
    /// button tap's UIKit event context. By never returning from the tap handler,
    /// the input connection stays alive so `insertText()` works — single-tap insert.
    /// `RunLoop.main.run(until:)` keeps UI events processing (animations stay alive).
    ///
    /// Mirrors the start path's heartbeat-aware fallback: if the app's heartbeat
    /// is stale we skip Darwin entirely and foreground via URL. If the heartbeat
    /// is fresh but the app doesn't ack within `stopCommandAckTimeout` (the
    /// heartbeat lied because the app suspended between our read and our post),
    /// we fall back to URL mid-poll. In both URL paths the keyboard returns
    /// without a result; the app's stop pipeline publishes bundled text and the
    /// next `viewWillAppear` auto-pastes it.
    func stopAndWaitForResult() {
        switch keyboardChannel.stopRecording() {
        case .commandSent:
            break
        case .openURL(let url):
            dictationState = .transcribing
            openURL(url)
            return
        }

        dictationState = .transcribing

        let postedAt = Date()
        let ackDeadline = postedAt.addingTimeInterval(Self.stopCommandAckTimeout)
        let deadline = postedAt.addingTimeInterval(Self.insertionTimeout)

        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(Self.pollInterval))

            switch keyboardChannel.readState() {
            case .emptyResult:
                dictationState = .emptyResult
                keyboardChannel.clearResult()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.emptyResultFlashDuration) { [weak self] in
                    guard self?.dictationState == .emptyResult else { return }
                    self?.dictationState = .idle
                }
                return
            case .idle:
                dictationState = .emptyResult
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.emptyResultFlashDuration) { [weak self] in
                    guard self?.dictationState == .emptyResult else { return }
                    self?.dictationState = .idle
                }
                return
            case .recording:
                // Ack window passed and state hasn't moved off `.recording` —
                // the Darwin post landed in a suspended app. Foreground via URL
                // and exit; the app's stop pipeline takes it from here.
                if Date() >= ackDeadline {
                    openURL(KeyboardChannel.stopDeepLinkURL)
                    return
                }
            case .transcribing:
                continue
            case .bundledResult(let text):
                guard !text.isEmpty else { continue }
                // Result arrived — insert while the tap's event context is still active
                textDocumentProxy.insertText(text)
                KeyboardHaptics.success()
                // Space is already added by TextPostProcessor.applyTerminator in the pipeline
                keyboardChannel.clearResult()
                pendingText = nil
                dictationState = .idle
                return
            }
        }

        // Timeout — show ready button as fallback for manual tap-to-insert
        refreshState()
    }

    // MARK: - Display Mode (Compact / Full)

    /// Switches to the Full Keyboard — a state flip in the live process, so
    /// the already-built key rows come back instantly.
    func expandKeyboard() {
        displayModeManager?.expand()
    }

    /// Switches to the Compact Keyboard.
    func collapseKeyboard() {
        displayModeManager?.collapse()
    }

    // MARK: - Settings

    private func refreshSettings() {
        aiConfigured = SharedConstants.sharedDefaults.bool(forKey: SharedConstants.aiConfiguredKey)
        aiMode = SessionSettings.effectiveAIMode()
        textStyle = SessionSettings.effectiveTextStyle()
    }

    /// Cycles the AI mode through Verbatim → Dictation → Assistant → Verbatim.
    func cycleAIState() {
        aiMode = aiMode.next
        SessionSettings.setAIMode(aiMode)
        refreshSelectedTextIndicator()
    }

    func cycleTextStyle() {
        textStyle = textStyle.next
        SessionSettings.setTextStyle(textStyle)
    }

    // MARK: - Selected Text Capture

    /// Starts recording, picking the best transport based on the app's heartbeat.
    ///
    /// If the main app's heartbeat in shared defaults is recent, the app is
    /// alive and reachable via Darwin command — we send one and wait briefly
    /// for it to confirm by writing `state = .recording`. On confirmation the
    /// existing `darwinStateChanged` observer flips `dictationState` and the
    /// user never leaves the keyboard. If the heartbeat is stale or the
    /// command isn't acknowledged in time, we fall back to the URL scheme,
    /// which foregrounds the app and starts recording via the deep-link path.
    ///
    /// Critically there is NO optimistic UI flip — `dictationState` stays at
    /// `.idle` until the app publishes `.recording`. An earlier attempt
    /// optimistically flipped to `.recording` up front, which misled users
    /// into tapping Stop before anything had actually started.
    func startRecordingFromKeyboard() {
        // Clear legacy single-capture key
        keyboardChannel.clearLegacySelectedText()
        // Initialize captures array — include current selection as first capture if available
        var captures: [String] = []
        if aiMode == .assistant,
           let selected = textDocumentProxy.selectedText, !selected.isEmpty {
            captures.append(selected)
        }
        captureCount = captures.count

        switch keyboardChannel.startRecording(captures: captures) {
        case .commandSent:
            scheduleStartAckFallback()
        case .openURL(let url):
            openURL(url)
        }
    }

    /// Schedules a fallback to `openURL` if the app doesn't publish
    /// `.recording` within the ack window.
    private func scheduleStartAckFallback() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startCommandAckTimeout) { [weak self] in
            guard let self else { return }
            if self.keyboardChannel.readState() == .recording { return }
            // App didn't ack — heartbeat lied (suspended between our read and the
            // command firing) or Darwin was dropped. Wake it via URL; the command
            // + captures we already wrote will be overwritten by the deep-link
            // path, which calls its own `startRecording(fromDeepLink:)`.
            self.openURL(KeyboardChannel.recordDeepLinkURL)
        }
    }

    /// Captures the currently selected text and appends it to the captures array.
    /// Called via the Capture button during recording in any AI mode.
    func captureSelectedText() {
        guard let selected = textDocumentProxy.selectedText, !selected.isEmpty else { return }
        keyboardChannel.appendCapture(selected)
        captureCount = keyboardChannel.readCaptures().count
        KeyboardHaptics.light()
    }

    /// Refreshes the `hasSelectedText` flag based on current proxy state and mode.
    func refreshSelectedTextIndicator() {
        let selected = aiMode == .assistant
            && !(textDocumentProxy.selectedText ?? "").isEmpty
        if hasSelectedText != selected {
            hasSelectedText = selected
        }
    }

    /// Opens a URL from the keyboard extension using the system responder chain.
    private func openURL(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url)
                return
            }
            responder = current.next
        }
    }

    // MARK: - Keyboard View Setup

    override func viewWillSetupKeyboardView() {
        setupKeyboardView { [unowned self] controller in
            VCDRKeyboardView(
                services: controller.services,
                state: controller.state,
                controller: self
            )
        }
    }
}
