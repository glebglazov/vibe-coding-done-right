import Foundation
@testable import vcdr_ios

enum SharedSettingsTestIsolation {
    private final class Lock: @unchecked Sendable {
        let value = NSLock()
    }

    private static let lock = Lock()

    static func withCleanStyleSlots<T>(_ operation: () throws -> T) rethrows -> T {
        lock.value.lock()
        defer { lock.value.unlock() }

        let defaults = SharedConstants.sharedDefaults
        let originalDefault = defaults.string(forKey: SharedConstants.defaultTextStyleKey)
        let originalSession = defaults.string(forKey: SharedConstants.sessionTextStyleKey)

        clearStyleSlots(in: defaults)
        defer {
            restore(originalDefault, forKey: SharedConstants.defaultTextStyleKey, in: defaults)
            restore(originalSession, forKey: SharedConstants.sessionTextStyleKey, in: defaults)
            defaults.synchronize()
        }

        return try operation()
    }

    private static func clearStyleSlots(in defaults: UserDefaults) {
        defaults.removeObject(forKey: SharedConstants.defaultTextStyleKey)
        defaults.removeObject(forKey: SharedConstants.sessionTextStyleKey)
        defaults.synchronize()
    }

    private static func restore(_ value: String?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
