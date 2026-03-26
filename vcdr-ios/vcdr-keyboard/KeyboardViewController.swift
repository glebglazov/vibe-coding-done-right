import KeyboardKit
import SwiftUI
import OSLog

private let kbLogger = Logger(subsystem: "glebglazov.vcdr-ios.keyboard", category: "controller")

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
        // Capture a weak ref to self for the openURL callback
        let openURL: (URL) -> Void = { [weak self] url in
            kbLogger.info("[Controller] Opening URL via extensionContext: \(url.absoluteString)")
            self?.extensionContext?.open(url) { success in
                kbLogger.info("[Controller] extensionContext.open completed — success=\(success)")
            }
        }

        setupKeyboardView { controller in
            KeyboardView(
                services: controller.services,
                buttonContent: { $0.view },
                buttonView: { $0.view },
                collapsedView: { $0.view },
                emojiKeyboard: { $0.view },
                toolbar: { params in
                    HStack(spacing: 0) {
                        params.view
                        DictateBarView(hasFullAccess: fullAccess, openURL: openURL)
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

        kbLogger.info("[Controller] Inserting transcription: \(text.prefix(50))...")
        textDocumentProxy.insertText(text)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.transcriptionResultKey)
    }
}
