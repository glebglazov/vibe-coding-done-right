import KeyboardKit
import SwiftUI

class KeyboardViewController: KeyboardInputViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        setup(for: .vcdr)

        // Listen for transcription results via Darwin notification
        DarwinNotificationCenter.observe(SharedConstants.darwinNotificationName)

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
            VStack(spacing: 0) {
                DictateBarView(hasFullAccess: fullAccess)
                KeyboardView(
                    services: controller.services,
                    buttonContent: { $0.view },
                    buttonView: { $0.view },
                    collapsedView: { $0.view },
                    emojiKeyboard: { $0.view },
                    toolbar: { $0.view }
                )
            }
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
