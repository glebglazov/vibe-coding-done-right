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
    @Published var aiMode: SharedAIMode = .dictation
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
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

    // MARK: - Commands

    /// Sends a stop command and polls for the transcription result within the
    /// button tap's UIKit event context. By never returning from the tap handler,
    /// the input connection stays alive so `insertText()` works — single-tap insert.
    /// `RunLoop.main.run(until:)` keeps UI events processing (animations stay alive).
    /// Falls back to `.ready` state if the result doesn't arrive within the timeout.
    func stopAndWaitForResult() {
        let sd = SharedConstants.sharedDefaults
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

        let deadline = Date().addingTimeInterval(Self.insertionTimeout)
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

            guard raw.hasPrefix(idlePrefix) else { continue }

            let text = String(raw.dropFirst(idlePrefix.count))
            guard !text.isEmpty else { continue }

            // Result arrived — insert while the tap's event context is still active
            textDocumentProxy.insertText(text)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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

    func toggleAI() {
        aiActive.toggle()
        SessionSettings.setAIActive(aiActive)
        refreshSelectedTextIndicator()
    }

    func cycleAIMode() {
        aiMode = aiMode.next
        SessionSettings.setAIMode(aiMode)
        refreshSelectedTextIndicator()
    }

    func cycleTextStyle() {
        textStyle = textStyle.next
        SessionSettings.setTextStyle(textStyle)
    }

    // MARK: - Selected Text Capture

    /// Starts recording and initializes the captures array.
    /// If text is selected in assistant mode, it becomes the first capture.
    func captureSelectedTextAndOpenRecord() {
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
        // Open the main app to start recording via deep link
        openURL(SharedConstants.recordDeepLinkURL)
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
