import UIKit
import SwiftUI

class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(rootView: makeKeyboardView())
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear

        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        hostingController = host

        // Start listening for transcription results via Darwin notification
        DarwinNotificationCenter.observe(SharedConstants.darwinNotificationName)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTranscriptionReady),
            name: .darwinTranscriptionReady, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Update Full Access state each time keyboard appears
        hostingController?.rootView = makeKeyboardView()

        // Check for pending transcription on every appearance
        // (fallback if Darwin notification was missed while suspended)
        checkPendingTranscription()
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

    private func makeKeyboardView() -> KeyboardView {
        KeyboardView(
            onNextKeyboard: { [weak self] in
                self?.advanceToNextInputMode()
            },
            onDeleteBackward: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
            },
            onNewline: { [weak self] in
                self?.textDocumentProxy.insertText("\n")
            },
            needsInputModeSwitchKey: needsInputModeSwitchKey,
            hasFullAccess: hasFullAccess
        )
    }
}
