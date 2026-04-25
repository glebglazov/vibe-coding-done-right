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
    @Published var dictationState: DictationState = .idle

    // MARK: - Shared Settings (keyboard ↔ app)
    @Published var aiConfigured: Bool = false
    @Published var aiActive: Bool = false
    @Published var aiMode: SharedAIMode = .verbatim
    @Published var textStyle: SharedTextStyle = .casual

    /// True when the text field has a non-empty selection and assistant mode is active.
    /// Drives the selection indicator icon in the toolbar.
    @Published var hasSelectedText: Bool = false

    /// Number of text selections captured in the current recording session (assistant mode).
    @Published var captureCount: Int = 0

    /// Text waiting to be inserted via tap-to-paste.
    private var pendingText: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        setup(for: .vcdr)

        // Listen for recording state changes from the main app.
        // Text is delivered via state bundling ("idle|text") on this same channel.
        DarwinNotificationCenter.observe(
            SharedConstants.stateNotificationName,
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
        // viewWillAppear provides a fresh textDocumentProxy connection —
        // auto-insert if text is pending (handles the case where the keyboard
        // wasn't visible when the transcription arrived).
        if pendingText != nil {
            insertPendingText()
        }
    }

    // MARK: - State Parsing

    @objc private func handleStateChanged() {
        refreshState()
    }

    @objc private func handleSettingsChanged() {
        SharedConstants.sharedDefaults.synchronize()
        refreshSettings()
        refreshSelectedTextIndicator()
    }

    /// Reads the shared state key and updates `dictationState`.
    /// Parses state bundling format: `"idle|transcription text"`.
    private func refreshState() {
        guard let raw = SharedConstants.sharedDefaults.string(forKey: SharedConstants.stateKey) else {
            dictationState = .idle
            pendingText = nil
            captureCount = 0
            return
        }

        let idlePrefix = "\(RecordingState.idle.rawValue)|"
        if raw.hasPrefix(idlePrefix) {
            let text = String(raw.dropFirst(idlePrefix.count))
            if !text.isEmpty {
                pendingText = text
                dictationState = .ready
            } else {
                pendingText = nil
                dictationState = .idle
            }
        } else if raw == RecordingState.emptyResult.rawValue {
            pendingText = nil
            dictationState = .emptyResult
            // Clear the state so it doesn't persist across keyboard appearances
            SharedConstants.sharedDefaults.set(RecordingState.idle.rawValue, forKey: SharedConstants.stateKey)
            // Auto-revert to idle after the flash duration
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.emptyResultFlashDuration) { [weak self] in
                guard self?.dictationState == .emptyResult else { return }
                self?.dictationState = .idle
            }
        } else if let state = RecordingState(rawValue: raw) {
            pendingText = nil
            switch state {
            case .recording: dictationState = .recording
            case .transcribing: dictationState = .transcribing
            case .idle: dictationState = .idle
            case .emptyResult: break // handled above
            }
        } else {
            pendingText = nil
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
        SharedConstants.sharedDefaults.set(RecordingState.idle.rawValue, forKey: SharedConstants.stateKey)
    }

    // MARK: - Constants

    /// Maximum time to wait for transcription result within the tap's event context
    private static let insertionTimeout: TimeInterval = 15
    /// Polling interval while waiting for result
    private static let pollInterval: TimeInterval = 0.1
    /// Duration to show the yellow empty-result indicator before reverting to idle
    private static let emptyResultFlashDuration: TimeInterval = 2
    /// Heartbeat-freshness window. If the app's heartbeat is within this many
    /// seconds of now, we treat the app as alive and send a Darwin command
    /// (stays in keyboard). Otherwise we go straight to URL. ~3x the app's
    /// 5-second heartbeat cadence — covers propagation + clock skew.
    private static let heartbeatFreshnessWindow: TimeInterval = 18
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
        let sd = SharedConstants.sharedDefaults

        // Stale heartbeat → app is suspended/killed. The Darwin command would
        // be dropped on the floor; go straight to URL.
        guard appLikelyAlive(in: sd) else {
            dictationState = .transcribing
            openURL(SharedConstants.stopDeepLinkURL)
            return
        }

        // Multi-capture: captures are accumulated explicitly via the Capture button.
        // No implicit capture on stop — the cursor position at stop time determines
        // where the result is inserted, independent of capture locations.
        sd.set(
            RecordingCommand.stopRecording.rawValue,
            forKey: SharedConstants.commandKey
        )
        sd.synchronize()
        DarwinNotificationCenter.post(SharedConstants.commandNotificationName)
        dictationState = .transcribing

        let postedAt = Date()
        let ackDeadline = postedAt.addingTimeInterval(Self.stopCommandAckTimeout)
        let deadline = postedAt.addingTimeInterval(Self.insertionTimeout)
        let idlePrefix = "\(RecordingState.idle.rawValue)|"

        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(Self.pollInterval))

            guard let raw = SharedConstants.sharedDefaults.string(forKey: SharedConstants.stateKey) else { continue }

            // Empty result — break out immediately, show yellow flash
            if raw == RecordingState.emptyResult.rawValue {
                dictationState = .emptyResult
                SharedConstants.sharedDefaults.set(RecordingState.idle.rawValue, forKey: SharedConstants.stateKey)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.emptyResultFlashDuration) { [weak self] in
                    guard self?.dictationState == .emptyResult else { return }
                    self?.dictationState = .idle
                }
                return
            }

            // App already idle with no bundled text — recording finished before
            // the keyboard sent stop. Treat as empty result (brief flash, then reset).
            if raw == RecordingState.idle.rawValue {
                dictationState = .emptyResult
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.emptyResultFlashDuration) { [weak self] in
                    guard self?.dictationState == .emptyResult else { return }
                    self?.dictationState = .idle
                }
                return
            }

            // Ack window passed and state hasn't moved off `.recording` —
            // the Darwin post landed in a suspended app. Foreground via URL
            // and exit; the app's stop pipeline takes it from here.
            if raw == RecordingState.recording.rawValue, Date() >= ackDeadline {
                openURL(SharedConstants.stopDeepLinkURL)
                return
            }

            guard raw.hasPrefix(idlePrefix) else { continue }

            let text = String(raw.dropFirst(idlePrefix.count))
            guard !text.isEmpty else { continue }

            // Result arrived — insert while the tap's event context is still active
            textDocumentProxy.insertText(text)
            KeyboardHaptics.success()
            // Space is already added by TextPostProcessor.applyTerminator in the pipeline
            SharedConstants.sharedDefaults.set(RecordingState.idle.rawValue, forKey: SharedConstants.stateKey)
            pendingText = nil
            dictationState = .idle
            return
        }

        // Timeout — show ready button as fallback for manual tap-to-insert
        refreshState()
    }

    // MARK: - Settings

    private func refreshSettings() {
        aiConfigured = SharedConstants.sharedDefaults.bool(forKey: SharedConstants.aiConfiguredKey)
        aiActive = SessionSettings.effectiveAIActive()
        aiMode = SessionSettings.effectiveAIMode()
        textStyle = SessionSettings.effectiveTextStyle()
    }

    /// Cycles the AI state through Off → Dictation → Assistant → Off.
    func cycleAIState() {
        if !aiActive {
            aiActive = true
            aiMode = .dictation
        } else if aiMode == .dictation {
            aiMode = .assistant
        } else {
            aiActive = false
        }
        SessionSettings.setAIActive(aiActive)
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
        let sd = SharedConstants.sharedDefaults
        // Clear legacy single-capture key
        sd.removeObject(forKey: SharedConstants.selectedTextKey)
        // Initialize captures array — include current selection as first capture if available
        var captures: [String] = []
        if aiActive, aiMode == .assistant,
           let selected = textDocumentProxy.selectedText, !selected.isEmpty {
            captures.append(selected)
        }
        if let data = try? JSONEncoder().encode(captures) {
            sd.set(data, forKey: SharedConstants.capturedTextsKey)
        }
        sd.synchronize()
        captureCount = captures.count

        if appLikelyAlive(in: sd) {
            tryStartViaDarwinCommand(in: sd)
        } else {
            openURL(SharedConstants.recordDeepLinkURL)
        }
    }

    /// Returns true if the main app has written a recent heartbeat. Stale or
    /// missing → app is suspended/killed, skip Darwin entirely.
    private func appLikelyAlive(in sd: UserDefaults) -> Bool {
        let beat = sd.double(forKey: SharedConstants.appHeartbeatKey)
        guard beat > 0 else { return false }
        return Date().timeIntervalSince1970 - beat < Self.heartbeatFreshnessWindow
    }

    /// Writes the `startRecording` command, posts the Darwin notification, and
    /// schedules a fallback to `openURL` if the app doesn't publish
    /// `state = .recording` within the ack window.
    private func tryStartViaDarwinCommand(in sd: UserDefaults) {
        sd.set(RecordingCommand.startRecording.rawValue, forKey: SharedConstants.commandKey)
        sd.synchronize()
        DarwinNotificationCenter.post(SharedConstants.commandNotificationName)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startCommandAckTimeout) { [weak self] in
            guard let self else { return }
            let raw = SharedConstants.sharedDefaults.string(forKey: SharedConstants.stateKey)
            if raw == RecordingState.recording.rawValue { return }
            // App didn't ack — heartbeat lied (suspended between our read and the
            // command firing) or Darwin was dropped. Wake it via URL; the command
            // + captures we already wrote will be overwritten by the deep-link
            // path, which calls its own `startRecording(fromDeepLink:)`.
            self.openURL(SharedConstants.recordDeepLinkURL)
        }
    }

    /// Captures the currently selected text and appends it to the captures array.
    /// Called via the Capture button during recording in assistant mode.
    func captureSelectedText() {
        guard aiActive, aiMode == .assistant,
              let selected = textDocumentProxy.selectedText, !selected.isEmpty else { return }
        let sd = SharedConstants.sharedDefaults
        sd.synchronize()
        var captures: [String] = []
        if let data = sd.data(forKey: SharedConstants.capturedTextsKey) {
            captures = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        captures.append(selected)
        if let data = try? JSONEncoder().encode(captures) {
            sd.set(data, forKey: SharedConstants.capturedTextsKey)
        }
        sd.synchronize()
        captureCount = captures.count
        KeyboardHaptics.light()
    }

    /// Refreshes the `hasSelectedText` flag based on current proxy state and mode.
    func refreshSelectedTextIndicator() {
        let selected = aiActive && aiMode == .assistant
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
