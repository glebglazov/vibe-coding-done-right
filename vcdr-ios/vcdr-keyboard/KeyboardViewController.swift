import KeyboardKit
import SwiftUI

class KeyboardViewController: KeyboardInputViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        setup(for: .vcdr)

        // Observe Darwin notifications for state changes and transcription results
        DarwinNotificationCenter.observe(SharedConstants.stateNotificationName, localName: .darwinStateChanged)
        DarwinNotificationCenter.observe(SharedConstants.transcriptionNotificationName, localName: .darwinTranscriptionReady)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTranscriptionReady),
            name: .darwinTranscriptionReady, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        checkPendingTranscription()
    }

    override func viewWillSetupKeyboardView() {
        let fullAccess = hasFullAccess
        setupKeyboardView { controller in
            KeyboardView(
                services: controller.services,
                buttonContent: { $0.view },
                buttonView: { $0.view },
                collapsedView: { $0.view },
                emojiKeyboard: { $0.view },
                toolbar: { params in
                    // Autocomplete suggestions + mic/stop icon on the right
                    HStack(spacing: 0) {
                        params.view
                        DictateBarView(hasFullAccess: fullAccess)
                    }
                }
            )
        }
    }

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
