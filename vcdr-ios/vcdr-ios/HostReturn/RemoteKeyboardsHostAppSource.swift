import Foundation
import Observation
import OSLog

/// Reads the host app from UIKit's private remote-keyboard state. Since iOS
/// 26.4 the keyboard extension no longer learns its host, but the containing
/// app still receives `_UIRemoteKeyboards.currentState.sourceBundleIdentifier`
/// shortly after the keyboard opens it. The value is transient, so it is
/// observed from launch rather than read on demand.
///
/// An unguarded KVC read of a missing key raises an Objective-C exception that
/// Swift cannot catch, so every hop is checked first. When one is missing the
/// source stays `.inert` and the user swipes back by hand, as before.
@MainActor
@Observable
final class RemoteKeyboardsHostAppSource: NSObject, HostAppSource {
    // MARK: - Constants

    nonisolated private static let remoteKeyboardsClassName = "_UIRemoteKeyboards"
    nonisolated private static let sharedSelectorName = "sharedRemoteKeyboards"
    nonisolated private static let currentStateKey = "currentState"
    nonisolated private static let sourceBundleKey = "sourceBundleIdentifier"

    private(set) var state: HostAppSourceState = .inert

    @ObservationIgnored private let ownBundleID: String
    @ObservationIgnored private var remoteKeyboards: NSObject?
    @ObservationIgnored private var didStart = false

    init(ownBundleID: String) {
        self.ownBundleID = ownBundleID
        super.init()
    }

    isolated deinit {
        remoteKeyboards?.removeObserver(self, forKeyPath: Self.currentStateKey)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        guard let remoteKeyboardsClass = NSClassFromString(Self.remoteKeyboardsClassName) as? NSObject.Type else {
            Logger.app.notice("Host Return: \(Self.remoteKeyboardsClassName) is missing, host detection is off")
            return
        }
        let sharedSelector = NSSelectorFromString(Self.sharedSelectorName)
        guard remoteKeyboardsClass.responds(to: sharedSelector),
              let shared = remoteKeyboardsClass.perform(sharedSelector)?.takeUnretainedValue() as? NSObject,
              shared.responds(to: NSSelectorFromString(Self.currentStateKey))
        else {
            Logger.app.notice("Host Return: \(Self.sharedSelectorName).\(Self.currentStateKey) is missing, host detection is off")
            return
        }
        remoteKeyboards = shared
        state = .observing(latest: nil)
        shared.addObserver(self, forKeyPath: Self.currentStateKey, options: [.initial, .new], context: nil)
        Logger.app.info("Host Return: observing the remote keyboard's host")
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        let observedAt = Date()
        let rawBundleID = Self.sourceBundleIdentifier(in: change?[.newKey])
        Task { @MainActor [weak self] in
            self?.record(rawBundleID, observedAt: observedAt)
        }
    }

    /// UIKit clears the state to `NSNull` once processed; that reads as nil
    /// because `NSNull` does not respond to the getter.
    nonisolated private static func sourceBundleIdentifier(in state: Any?) -> String? {
        guard let state = state as? NSObject,
              state.responds(to: NSSelectorFromString(sourceBundleKey))
        else { return nil }
        return state.value(forKey: sourceBundleKey) as? String
    }

    private func record(_ rawBundleID: String?, observedAt: Date) {
        guard let host = rawBundleID.flatMap(HostBundleID.init),
              !host.belongs(toApp: ownBundleID)
        else { return }
        state = .observing(latest: HostObservation(host: host, observedAt: observedAt))
        Logger.app.info("Host Return: saw host=\(host)")
    }
}
