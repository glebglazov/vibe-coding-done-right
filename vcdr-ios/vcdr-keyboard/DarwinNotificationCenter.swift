import Foundation

enum DarwinNotificationCenter {
    static func post(_ name: String) {
        guard let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Observes a Darwin notification and rebroadcasts it as a local Notification.
    /// Each Darwin name maps to a distinct local Notification.Name.
    static func observe(_ darwinName: String, localName: Notification.Name) {
        guard let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }

        notificationMap[darwinName] = localName

        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, cfName, _, _ in
                guard let cfName,
                      let name = cfName.rawValue as String?,
                      let localName = DarwinNotificationCenter.notificationMap[name]
                else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: localName, object: nil)
                }
            },
            darwinName as CFString, nil, .deliverImmediately
        )
    }

    // nonisolated(unsafe) because accessed from C callback on arbitrary threads.
    // Safe because we only write during setup (viewDidLoad) before notifications fire.
    private nonisolated(unsafe) static var notificationMap: [String: Notification.Name] = [:]
}

extension Notification.Name {
    static let darwinCommand = Notification.Name("darwinCommand")
    static let darwinStateChanged = Notification.Name("darwinStateChanged")
}
