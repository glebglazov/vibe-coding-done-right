import Combine
import KeyboardKit
import OSLog
import SwiftUI
import UIKit

/// Keyboard-side dictation state, derived from the main app's recording state.
/// Every terminal case is published by the app on the Keyboard Channel — the
/// keyboard never infers one (ADR-0004).
enum DictationState {
    case idle
    case recording
    case transcribing
    /// Transcription text available — waiting for user tap to insert
    case ready
    /// Recording produced no speech — shown briefly before reverting to idle
    case emptyResult
    /// The app published `cancelled`: a Discard, or a stop during Arming. The
    /// DISCARDED pill shows briefly, then START comes back.
    case cancelled
    /// The run failed to produce a transcript. The reason stays in the app; the
    /// pill only reports that a failure happened.
    case failed
}

class KeyboardViewController: KeyboardInputViewController {

    /// What the keyboard's views render. The views observe this and never the
    /// controller itself (see `KeyboardDictationModel`).
    let model = KeyboardDictationModel()

    /// Text waiting to be inserted via tap-to-paste.
    private var pendingText: String?
    private let keyboardChannel = KeyboardChannel.live

    /// Whether a tap on the record control records in place. Kept outside
    /// `dictationState` — a run's state and the tap's destination are two
    /// different facts, and folding them together is what made a single
    /// keyboard state mean several things before.
    lazy var reachability = KeyboardReachabilityMonitor(channel: keyboardChannel)

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

        // Listen for settings changes from the main app (mode/style cycled in the app).
        DarwinNotificationCenter.observe(
            SharedConstants.settingsNotificationName,
            localName: .darwinSettingsChanged
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSettingsChanged),
            name: .darwinSettingsChanged, object: nil
        )
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

        // The heartbeat has no change notification, so the record control's
        // lit state is polled — but only for as long as the user can see it.
        reachability.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Nothing on screen to keep honest; an extension that polls while
        // hidden is spending a memory-constrained process on nobody.
        reachability.stop()
    }

    // MARK: - State Parsing

    @objc private func handleStateChanged() {
        refreshState()
    }

    @objc private func handleSettingsChanged() {
        SharedConstants.sharedDefaults.synchronize()
        refreshSettings()
        // The Settings UI may have toggled the haptics flag — refresh the
        // cached value the per-call hot path reads.
        KeyboardHaptics.refreshEnabled()
    }

    /// Reads the shared state key and updates `dictationState`.
    /// Parses state bundling format: `"idle|transcription text"`.
    private func refreshState() {
        // Keep a wire-published cancellation visible for its full flash.
        guard model.dictationState != .cancelled else { return }

        switch keyboardChannel.readState() {
        case .bundledResult(let text):
            if !text.isEmpty {
                pendingText = text
                model.dictationState = .ready
            } else {
                pendingText = nil
                model.dictationState = .idle
            }
        case .emptyResult:
            flash(.emptyResult, for: Self.emptyResultFlashDuration)
        case .cancelled:
            flash(.cancelled, for: Self.cancelledFlashDuration)
        case .failed:
            // The reason travels on the wire for the app to show; the pill
            // reports only that a failure happened (ADR-0004).
            flash(.failed, for: Self.failedFlashDuration)
        case .recording:
            pendingText = nil
            model.dictationState = .recording
        case .transcribing:
            pendingText = nil
            model.dictationState = .transcribing
        case .idle:
            pendingText = nil
            model.captureCount = 0
            model.dictationState = .idle
        }
    }

    /// Renders a terminal state the app published: consumes it from the wire so
    /// a later appearance can't replay a finished run, then reverts to idle once
    /// the user has had time to see it. Consuming is a silent write — a Darwin
    /// post would come back to this same process and end the flash immediately.
    private func flash(_ terminal: DictationState, for duration: TimeInterval) {
        pendingText = nil
        model.captureCount = 0
        model.dictationState = terminal
        keyboardChannel.consumeState()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard self?.model.dictationState == terminal else { return }
            self?.model.dictationState = .idle
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
        model.dictationState = .idle
        model.captureCount = 0
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
    /// Duration to show the red FAILED pill before reverting to idle. Longer
    /// than the informational no-speech flash: a failure is the one terminal
    /// state the user may want to act on, and the pill is the only place the
    /// keyboard reports it.
    private static let failedFlashDuration: TimeInterval = 5
    /// Duration to show the DISCARDED pill before START comes back.
    private static let cancelledFlashDuration: TimeInterval = DiscardTiming.keyboardFlash
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
            Logger.keyboard.info("Heartbeat verdict: command=stop fresh=true")
        case .openURL(let url):
            Logger.keyboard.info("Heartbeat verdict: command=stop fresh=false")
            model.dictationState = .transcribing
            openDeepLinkFallback(url, command: "stop", reason: "Heartbeat was stale")
            return
        }

        model.dictationState = .transcribing

        let postedAt = Date()
        let ackDeadline = postedAt.addingTimeInterval(Self.stopCommandAckTimeout)
        let deadline = postedAt.addingTimeInterval(Self.insertionTimeout)
        var previousPolledState: String?
        var didLogAcknowledgement = false

        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(Self.pollInterval))

            let state = keyboardChannel.readState()
            let stateName = Self.wireStateName(state)
            if previousPolledState != stateName {
                Logger.keyboard.info(
                    "Stop poll state transition: \(previousPolledState ?? "initial") -> \(stateName)"
                )
                previousPolledState = stateName
            }
            if state != .recording, !didLogAcknowledgement {
                Logger.keyboard.info("Stop Command Acknowledgement received: state=\(stateName)")
                didLogAcknowledgement = true
            }

            switch state {
            case .emptyResult:
                flash(.emptyResult, for: Self.emptyResultFlashDuration)
                return
            case .cancelled:
                flash(.cancelled, for: Self.cancelledFlashDuration)
                return
            case .failed:
                flash(.failed, for: Self.failedFlashDuration)
                return
            case .idle:
                // Idle is idle. Guessing Empty Result here is what made yellow
                // mean six different things (ADR-0004) — the app publishes the
                // terminal state it reached, and a run that reached one is
                // handled by the cases above.
                pendingText = nil
                model.captureCount = 0
                model.dictationState = .idle
                return
            case .recording:
                // Ack window passed and state hasn't moved off `.recording` —
                // the Darwin post landed in a suspended app. Foreground via URL
                // and exit; the app's stop pipeline takes it from here.
                if Date() >= ackDeadline {
                    Logger.keyboard.warning(
                        "Stop Command Acknowledgement timed out after \(Self.stopCommandAckTimeout)s"
                    )
                    openDeepLinkFallback(
                        KeyboardChannel.stopDeepLinkURL,
                        command: "stop",
                        reason: "Command Acknowledgement timed out"
                    )
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
                model.dictationState = .idle
                return
            }
        }

        // Timeout — show ready button as fallback for manual tap-to-insert
        Logger.keyboard.warning(
            "Stop poll timed out after \(Self.insertionTimeout)s; refreshing state for manual insertion"
        )
        refreshState()
    }

    /// Discard: no deep-link fallback, no acknowledgement wait (ADR-0003). The
    /// app answers with `cancelled`.
    func discardRecordingFromKeyboard() {
        keyboardChannel.cancelRecording()
    }

    /// Foregrounds the app on the surface that already owns the failure
    /// reason. The URL is a route only: the reason remains app-owned and is
    /// neither duplicated into the URL nor sent through another channel.
    func showFailureReason() {
        guard model.dictationState == .failed else { return }
        Logger.keyboard.info("Opening the app to show the Processing Failure reason")
        openURL(KeyboardChannel.failureDeepLinkURL)
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
        model.aiConfigured = SharedConstants.sharedDefaults.bool(forKey: SharedConstants.aiConfiguredKey)
        model.aiMode = SettingOverrides.effectiveAIMode()
        model.textStyle = SettingOverrides.effectiveTextStyle()
    }

    /// Cycles the AI mode through Verbatim → Dictation → Assistant → Verbatim.
    func cycleAIState() {
        guard !model.areOutputChoicesLocked else { return }
        model.aiMode = model.aiMode.next
        SettingOverrides.setAIMode(model.aiMode)
    }

    func cycleTextStyle() {
        guard !model.areOutputChoicesLocked else { return }
        model.textStyle = model.textStyle.next
        SettingOverrides.setTextStyle(model.textStyle)
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
        // A tap on the DISCARDED pill starts a run as START does. The flash
        // must end first: while it shows, `refreshState` ignores the wire, and
        // the app's `recording` would be lost.
        if model.dictationState == .cancelled { model.dictationState = .idle }
        // Clear legacy single-capture key
        keyboardChannel.clearLegacySelectedText()
        // Initialize captures array — include current selection as first capture if available
        var captures: [String] = []
        if model.aiMode.usesCaptures,
           let selected = textDocumentProxy.selectedText, !selected.isEmpty {
            captures.append(selected)
        }
        model.captureCount = captures.count

        switch keyboardChannel.startRecording(captures: captures) {
        case .commandSent:
            Logger.keyboard.info("Heartbeat verdict: command=start fresh=true")
            scheduleStartAckFallback()
        case .openURL(let url):
            Logger.keyboard.info("Heartbeat verdict: command=start fresh=false")
            openDeepLinkFallback(url, command: "start", reason: "Heartbeat was stale")
        }
    }

    /// Schedules a fallback to `openURL` if the app doesn't publish
    /// `.recording` within the ack window.
    private func scheduleStartAckFallback() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startCommandAckTimeout) { [weak self] in
            guard let self else { return }
            let state = self.keyboardChannel.readState()
            if state == .recording {
                Logger.keyboard.info("Start Command Acknowledgement received before timeout")
                return
            }
            Logger.keyboard.warning(
                "Start Command Acknowledgement timed out after \(Self.startCommandAckTimeout)s; state=\(Self.wireStateName(state))"
            )
            // App didn't ack — heartbeat lied (suspended between our read and the
            // command firing) or Darwin was dropped.
            self.openDeepLinkFallback(
                KeyboardChannel.recordDeepLinkURL,
                command: "start",
                reason: "Command Acknowledgement timed out"
            )
        }
    }

    /// Captures the currently selected text and appends it to the captures array.
    func captureSelectedText() {
        guard let selected = textDocumentProxy.selectedText, !selected.isEmpty else { return }
        keyboardChannel.appendCapture(selected)
        model.captureCount = keyboardChannel.readCaptures().count
        KeyboardHaptics.light()
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

    private func openDeepLinkFallback(_ url: URL, command: String, reason: String) {
        Logger.keyboard.notice("Deep-Link Fallback: command=\(command) reason=\(reason)")
        openURL(url)
    }

    private static func wireStateName(_ state: KeyboardChannel.State) -> String {
        switch state {
        case .idle: "idle"
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .emptyResult: "emptyResult"
        case .cancelled: "cancelled"
        case .failed: "failed"
        case .bundledResult: "bundledResult"
        }
    }

    // MARK: - Keyboard View Setup

    override func viewWillSetupKeyboardView() {
        setupKeyboardView { [unowned self] controller in
            VCDRKeyboardView(
                services: controller.services,
                state: controller.state,
                model: model,
                reachability: reachability,
                controller: self
            )
        }
    }
}
