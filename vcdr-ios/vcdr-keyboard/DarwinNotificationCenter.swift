import Foundation

enum DarwinNotificationCenter {
    static func post(_ name: String) {
        guard let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    static func observe(_ name: String, localName: Notification.Name) {
        guard let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }

        // Store the local name mapping so the C callback can look it up
        notificationMap[name] = localName

        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, cfName, _, _ in
                guard let cfName,
                      let name = cfName.rawValue as String?,
                      let localName = DarwinNotificationCenter.notificationMap[name] else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: localName, object: nil)
                }
            },
            name as CFString, nil, .deliverImmediately
        )
    }

    // nonisolated(unsafe) because accessed from C callback on arbitrary threads.
    // Safe because we only write during setup (viewDidLoad/task) before any notifications fire.
    private nonisolated(unsafe) static var notificationMap: [String: Notification.Name] = [:]
}

extension Notification.Name {
    static let darwinCommand = Notification.Name("darwinCommand")
    static let darwinStateChanged = Notification.Name("darwinStateChanged")
    static let darwinTranscriptionReady = Notification.Name("darwinTranscriptionReady")
}
