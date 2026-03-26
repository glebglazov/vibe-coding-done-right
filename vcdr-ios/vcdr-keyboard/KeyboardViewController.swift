import KeyboardKit
import OSLog
import SwiftUI

class KeyboardViewController: KeyboardInputViewController {

    /// Whether the main app is currently recording in the background.
    /// Updated via Darwin notifications from the main app.
    var isAppRecording = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setup(for: .vcdr)

        // Listen for state changes from the main app
        DarwinNotificationCenter.observe(
            SharedConstants.stateNotificationName,
            localName: .darwinStateChanged
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleStateChanged),
            name: .darwinStateChanged, object: nil
        )

        // Listen for transcription results
        DarwinNotificationCenter.observe(
            SharedConstants.transcriptionNotificationName,
            localName: .darwinTranscriptionReady
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTranscriptionReady),
            name: .darwinTranscriptionReady, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        writeHostBundleID()
        refreshRecordingState()
        checkPendingTranscription()
    }

    // MARK: - Host App Detection

    private func writeHostBundleID() {
        if let bundleID = hostApplicationBundleId {
            SharedConstants.sharedDefaults.set(bundleID, forKey: SharedConstants.hostBundleIDKey)
        }
    }

    // MARK: - Recording State

    @objc private func handleStateChanged() {
        refreshRecordingState()
    }

    private func refreshRecordingState() {
        if let rawState = SharedConstants.sharedDefaults.string(forKey: SharedConstants.stateKey),
           let state = RecordingState(rawValue: rawState) {
            isAppRecording = (state == .recording)
        } else {
            isAppRecording = false
        }
    }

    /// Sends a start command to the main app (session already active, no flash needed)
    func sendStartCommand() {
        SharedConstants.sharedDefaults.set(
            RecordingCommand.startRecording.rawValue,
            forKey: SharedConstants.commandKey
        )
        DarwinNotificationCenter.post(SharedConstants.commandNotificationName)
        isAppRecording = true
    }

    /// Sends a stop command to the main app via App Group + Darwin notification
    func sendStopCommand() {
        SharedConstants.sharedDefaults.set(
            RecordingCommand.stopRecording.rawValue,
            forKey: SharedConstants.commandKey
        )
        DarwinNotificationCenter.post(SharedConstants.commandNotificationName)
        isAppRecording = false
    }

    // MARK: - Keyboard View Setup

    override func viewWillSetupKeyboardView() {
        let fullAccess = hasFullAccess
        setupKeyboardView { [weak self] controller in
            KeyboardView(
                services: controller.services,
                buttonContent: { $0.view },
                buttonView: { $0.view },
                collapsedView: { $0.view },
                emojiKeyboard: { $0.view },
                toolbar: { params in
                    HStack(spacing: 0) {
                        params.view
                        DictateBarView(
                            hasFullAccess: fullAccess,
                            keyboardController: self
                        )
                    }
                }
            )
        }
    }

    // MARK: - Transcription Handling

    @objc private func handleTranscriptionReady() {
        checkPendingTranscription()
    }

    private func checkPendingTranscription() {
        guard let text = SharedConstants.sharedDefaults.string(forKey: SharedConstants.transcriptionResultKey),
              !text.isEmpty else { return }

        textDocumentProxy.insertText(text)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.transcriptionResultKey)
    }
}
