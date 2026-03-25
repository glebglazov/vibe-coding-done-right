import Foundation

enum DarwinNotificationCenter {
    static func post(_ name: String) {
        guard let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    static func observe(_ name: String) {
        guard let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }

        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                // Darwin notification callbacks arrive on arbitrary threads
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .darwinTranscriptionReady, object: nil)
                }
            },
            name as CFString, nil, .deliverImmediately
        )
    }
}

extension Notification.Name {
    static let darwinTranscriptionReady = Notification.Name("darwinTranscriptionReady")
}
