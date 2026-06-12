import Foundation
import OSLog

enum BackgroundModelWarmTriggerReason: String, Sendable {
    case appVersionChanged
    case osVersionChanged
    case rebootDetected
    case coldSpecializeVerdict
    case reschedule
}

protocol BackgroundModelWarmTriggerStoring: Sendable {
    func hasPendingPurgeTrigger() async -> Bool
    func markPurgeTrigger(_ reason: BackgroundModelWarmTriggerReason) async
    func clearPendingPurgeTrigger() async
}

struct UserDefaultsBackgroundModelWarmTriggerStore: BackgroundModelWarmTriggerStoring {
    private static let pendingTriggerKey = "backgroundModelWarm.pendingPurgeTrigger"
    private static let triggerReasonKey = "backgroundModelWarm.pendingReason"
    private static let appVersionKey = "backgroundModelWarm.lastAppVersion"
    private static let osVersionKey = "backgroundModelWarm.lastOSVersion"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasPendingPurgeTrigger() async -> Bool {
        defaults.bool(forKey: Self.pendingTriggerKey)
    }

    func markPurgeTrigger(_ reason: BackgroundModelWarmTriggerReason) async {
        defaults.set(true, forKey: Self.pendingTriggerKey)
        defaults.set(reason.rawValue, forKey: Self.triggerReasonKey)
        Logger.app.info("Background model warm trigger marked reason=\(reason.rawValue)")
    }

    func clearPendingPurgeTrigger() async {
        defaults.removeObject(forKey: Self.pendingTriggerKey)
        defaults.removeObject(forKey: Self.triggerReasonKey)
        Logger.app.info("Background model warm trigger cleared")
    }

    func markVersionPurgeTriggersIfNeeded(
        appVersion: String,
        osVersion: String,
        rebootedSinceLastRecord: Bool
    ) async {
        let previousAppVersion = defaults.string(forKey: Self.appVersionKey)
        let previousOSVersion = defaults.string(forKey: Self.osVersionKey)
        defaults.set(appVersion, forKey: Self.appVersionKey)
        defaults.set(osVersion, forKey: Self.osVersionKey)

        let reason: BackgroundModelWarmTriggerReason?
        if let previousAppVersion, previousAppVersion != appVersion {
            reason = .appVersionChanged
        } else if let previousOSVersion, previousOSVersion != osVersion {
            reason = .osVersionChanged
        } else if rebootedSinceLastRecord {
            reason = .rebootDetected
        } else {
            reason = nil
        }

        if let reason {
            await markPurgeTrigger(reason)
        }
    }
}
