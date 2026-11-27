import Combine
import KeyboardKit
import OSLog
import SwiftUI
import UIKit

class KeyboardViewController: KeyboardInputViewController {

    /// What the keyboard's views render. The views observe this and never the
    /// controller itself (see `KeyboardDictationModel`).
    let model = KeyboardDictationModel()

    private let keyboardChannel = KeyboardChannel.live
    /// What the keyboard shows for the app's snapshot. The keyboard never
    /// writes that snapshot; it only reads it.
    private lazy var wire = KeyboardWireReader(channel: keyboardChannel)
    /// The last reading rendered, so a pill gets its timer once.
    private var rendered: KeyboardShown = .idle

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

        // Listen for the app's snapshot, which also carries the Bundled Result.
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
        // auto-insert a Bundled Result (handles the case where the keyboard
        // wasn't visible when the transcription arrived).
        insertPendingText()

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

    // MARK: - Wire

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

    private func refreshState() {
        show(wire.refresh())
    }

    /// Renders what the reader decided. A pill that just started gets its
    /// timer here; the reader keeps it up until then.
    private func show(_ shown: KeyboardShown) {
        let started = shown != rendered
        rendered = shown
        model.dictationState = DictationState(shown)
        guard started, case .flash(let run, let flash) = shown else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashDuration(flash)) { [weak self] in
            guard let self else { return }
            self.show(self.wire.endFlash(of: run))
        }
    }

    // MARK: - Text Insertion

    /// Inserts the Bundled Result into the active text field.
    /// Must be called from a UIKit event context (button tap handler) for
    /// `textDocumentProxy.insertText()` to work — this is the WisprFlow pattern.
    func insertPendingText() {
        guard case .ready(let run, let text) = wire.shown else { return }
        insert(text, of: run)
    }

    /// Space is already added by TextPostProcessor.applyTerminator in the pipeline.
    private func insert(_ text: String, of run: RunID) {
        textDocumentProxy.insertText(text)
        KeyboardHaptics.success()
        show(wire.didInsert(for: run))
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
    /// Window to wait for the app to acknowledge a start command by its ID.
    /// If nothing by then, fall back to URL. Tuned for Darwin roundtrip + a
    /// MainActor hop under CoreML load.
    private static let startCommandAckTimeout: TimeInterval = 0.4
    /// Same purpose as `startCommandAckTimeout` but for stop, counted from
    /// when the command is sent.
    private static let stopCommandAckTimeout: TimeInterval = 0.4

    private static func flashDuration(_ flash: KeyboardFlash) -> TimeInterval {
        switch flash {
        case .emptyResult: emptyResultFlashDuration
        case .cancelled: cancelledFlashDuration
        case .failed: failedFlashDuration
        }
    }

    // MARK: - Commands

    /// Sends a stop command and polls for the transcription result within the
    /// button tap's UIKit event context. By never returning from the tap handler,
    /// the input connection stays alive so `insertText()` works — single-tap insert.
    /// `RunLoop.main.run(until:)` keeps UI events processing (animations stay alive).
    ///
    /// If the Heartbeat is stale the keyboard skips Darwin and foregrounds via
    /// URL. If the app does not acknowledge the command within
    /// `stopCommandAckTimeout` (it suspended between the Heartbeat read and the
    /// post), it falls back to URL mid-poll. The URL carries the same command,
    /// so the app takes it once. In both URL paths the keyboard returns without
    /// a result; the next `viewWillAppear` inserts the Bundled Result.
    func stopAndWaitForResult() {
        guard case .recording(let run) = wire.shown else { return }
        model.dictationState = .transcribing

        let command: CommandID
        switch keyboardChannel.stopRecording(run) {
        case .commandSent(let id):
            Logger.keyboard.info("Heartbeat verdict: command=stop fresh=true")
            command = id
        case .openURL(let link):
            Logger.keyboard.info("Heartbeat verdict: command=stop fresh=false")
            openDeepLinkFallback(link, reason: "Heartbeat was stale")
            return
        }

        let postedAt = Date()
        let ackDeadline = postedAt.addingTimeInterval(Self.stopCommandAckTimeout)
        let deadline = postedAt.addingTimeInterval(Self.insertionTimeout)
        var previousStep: KeyboardStopStep?

        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(Self.pollInterval))

            let step = wire.stopStep(for: command, of: run, ackTimedOut: Date() >= ackDeadline)
            if step != previousStep {
                Logger.keyboard.info("Stop poll step: \(String(describing: step))")
                previousStep = step
            }
            switch step {
            case .wait:
                continue
            case .insert(let text):
                // Result arrived — insert while the tap's event context is still active
                insert(text, of: run)
                return
            case .render:
                refreshState()
                return
            case .openDeepLink:
                Logger.keyboard.warning(
                    "Stop Command Acknowledgement timed out after \(Self.stopCommandAckTimeout)s"
                )
                openDeepLinkFallback(.stop(command, run: run), reason: "Command Acknowledgement timed out")
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
        guard case .recording(let run) = wire.shown else { return }
        keyboardChannel.discardRecording(run)
    }

    /// Foregrounds the app on the surface that already owns the failure
    /// reason. The URL is a route only: the reason remains app-owned and is
    /// neither duplicated into the URL nor sent through another channel.
    func showFailureReason() {
        guard model.dictationState == .failed, let url = KeyboardDeepLink.failure.url else { return }
        Logger.keyboard.info("Opening the app to show the Processing Failure reason")
        openURL(url)
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

    func toggleAIMode() {
        guard !model.areOutputChoicesLocked else { return }
        model.aiMode = model.aiMode.toggled
        SettingOverrides.setAIMode(model.aiMode)
    }

    func cycleTextStyle() {
        guard !model.areOutputChoicesLocked else { return }
        model.textStyle = model.textStyle.next
        SettingOverrides.setTextStyle(model.textStyle)
    }

    // MARK: - Recording

    /// Starts recording, picking the best transport based on the app's heartbeat.
    ///
    /// If the Heartbeat is fresh, the keyboard sends a Darwin command and checks
    /// after a short window that the app acknowledged that command by its ID.
    /// The run it started may already have ended by then: the acknowledgement
    /// still holds, so no deep link opens and no second run starts. If the
    /// Heartbeat is stale or the command is not acknowledged in time, the
    /// keyboard opens the record deep link, which carries the same command.
    ///
    /// There is no optimistic UI flip: the keyboard shows recording only when
    /// the app publishes it. An earlier attempt flipped up front, which misled
    /// users into tapping Stop before anything had actually started.
    func startRecordingFromKeyboard() {
        switch keyboardChannel.startRecording() {
        case .commandSent(let command):
            Logger.keyboard.info("Heartbeat verdict: command=start fresh=true")
            scheduleStartAckFallback(command)
        case .openURL(let link):
            Logger.keyboard.info("Heartbeat verdict: command=start fresh=false")
            openDeepLinkFallback(link, reason: "Heartbeat was stale")
        }
    }

    private func scheduleStartAckFallback(_ command: CommandID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startCommandAckTimeout) { [weak self] in
            guard let self else { return }
            if self.wire.isAcknowledged(command) {
                Logger.keyboard.info("Start Command Acknowledgement received before timeout")
                return
            }
            Logger.keyboard.warning(
                "Start Command Acknowledgement timed out after \(Self.startCommandAckTimeout)s"
            )
            // The Heartbeat lied (the app suspended between our read and the
            // command) or Darwin dropped the post.
            self.openDeepLinkFallback(.record(command), reason: "Command Acknowledgement timed out")
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

    private func openDeepLinkFallback(_ link: KeyboardDeepLink, reason: String) {
        Logger.keyboard.notice("Deep-Link Fallback: link=\(String(describing: link)) reason=\(reason)")
        guard let url = link.url else { return }
        openURL(url)
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
