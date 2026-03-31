import Combine
import KeyboardKit
import OSLog
import SwiftUI

/// Keyboard-side dictation state, derived from the main app's recording state.
enum DictationState {
    case idle
    case recording
    case transcribing
    /// Transcription text available — waiting for user tap to insert
    case ready
}

class KeyboardViewController: KeyboardInputViewController, ObservableObject {

    /// Current dictation state — drives the DictateBarView appearance.
    @Published var dictationState: DictationState = .idle

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

    /// Reads the shared state key and updates `dictationState`.
    /// Parses state bundling format: `"idle|transcription text"`.
    private func refreshState() {
        guard let raw = SharedConstants.sharedDefaults.string(forKey: SharedConstants.stateKey) else {
            dictationState = .idle
            pendingText = nil
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
        } else if let state = RecordingState(rawValue: raw) {
            pendingText = nil
            switch state {
            case .recording: dictationState = .recording
            case .transcribing: dictationState = .transcribing
            case .idle: dictationState = .idle
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
        pendingText = nil
        dictationState = .idle
        // Clear the bundled text so it isn't re-inserted on next keyboard appearance
        SharedConstants.sharedDefaults.set(RecordingState.idle.rawValue, forKey: SharedConstants.stateKey)
    }

    // MARK: - Constants

    /// Maximum time to wait for transcription result within the tap's event context
    private static let insertionTimeout: TimeInterval = 15
    /// Polling interval while waiting for result
    private static let pollInterval: TimeInterval = 0.1

    // MARK: - Commands

    /// Sends a stop command and polls for the transcription result within the
    /// button tap's UIKit event context. By never returning from the tap handler,
    /// the input connection stays alive so `insertText()` works — single-tap insert.
    /// `RunLoop.main.run(until:)` keeps UI events processing (animations stay alive).
    /// Falls back to `.ready` state if the result doesn't arrive within the timeout.
    func stopAndWaitForResult() {
        SharedConstants.sharedDefaults.set(
            RecordingCommand.stopRecording.rawValue,
            forKey: SharedConstants.commandKey
        )
        DarwinNotificationCenter.post(SharedConstants.commandNotificationName)
        dictationState = .transcribing

        let deadline = Date().addingTimeInterval(Self.insertionTimeout)
        let idlePrefix = "\(RecordingState.idle.rawValue)|"

        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(Self.pollInterval))

            guard let raw = SharedConstants.sharedDefaults.string(forKey: SharedConstants.stateKey),
                  raw.hasPrefix(idlePrefix) else { continue }

            let text = String(raw.dropFirst(idlePrefix.count))
            guard !text.isEmpty else { continue }

            // Result arrived — insert while the tap's event context is still active
            textDocumentProxy.insertText(text)
            SharedConstants.sharedDefaults.set(RecordingState.idle.rawValue, forKey: SharedConstants.stateKey)
            pendingText = nil
            dictationState = .idle
            return
        }

        // Timeout — show ready button as fallback for manual tap-to-insert
        refreshState()
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
