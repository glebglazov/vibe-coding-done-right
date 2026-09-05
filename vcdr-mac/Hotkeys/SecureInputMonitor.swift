import AppKit
import Carbon
import CoreGraphics
import Foundation
import OSLog

/// Watches macOS Secure Event Input, a process-global flag that starves every
/// session-level CGEvent tap on the machine for as long as any process holds it.
///
/// This exists because the failure is otherwise invisible. Secure Input does not
/// disable a tap — `EventTapManager` keeps reporting `isInstalled`, and no
/// `tapDisabledByTimeout` callback ever reaches `GlobalHotkeyManager` — macOS simply
/// stops delivering key events to it. Every VCDR hotkey goes dead with nothing written
/// to the log and nothing changed in the UI. Password managers are the usual holder,
/// and 1Password has a known defect where it keeps the flag after it is backgrounded.
@MainActor
@Observable
final class SecureInputMonitor {

    // MARK: - Constants

    /// Matches the permission poll cadence in `AppDependencies`. Secure Input is held
    /// for seconds to minutes at a time, so a tighter poll would buy nothing.
    private static let pollInterval: Duration = .seconds(2)

    /// The window server's name for the process credited with holding the flag.
    private static let secureInputPIDKey = "kCGSSessionSecureInputPID"

    /// Whether macOS is currently withholding key events from every session event tap.
    /// While true, no VCDR hotkey can fire, however healthy its tap looks.
    private(set) var isActive = false

    /// The app holding Secure Input, when macOS names one — so the user knows which
    /// app to focus or quit rather than being told only that something is wrong.
    private(set) var holderName: String?

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// The two system reads, injected so tests can drive a transition without a real
    /// Secure Input holder — nothing else in the app may substitute them.
    @ObservationIgnored private let readIsActive: @MainActor () -> Bool
    @ObservationIgnored private let readHolderName: @MainActor () -> String?

    init(
        readIsActive: @escaping @MainActor () -> Bool = { IsSecureEventInputEnabled() },
        readHolderName: @escaping @MainActor () -> String? = { SecureInputMonitor.currentHolderName() }
    ) {
        self.readIsActive = readIsActive
        self.readHolderName = readHolderName
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Reads the flag and reports only the transitions, so the log carries the two
    /// moments that matter rather than one line every poll.
    /// Internal rather than private so a test can step it without waiting on the poll.
    func sample() {
        let active = readIsActive()
        guard active != isActive else { return }

        isActive = active
        holderName = active ? readHolderName() : nil

        if active {
            let holder = holderName ?? "unknown app"
            Logger.hotkeys.warning("Secure Input active — hotkeys cannot fire. Held by: \(holder)")
        } else {
            Logger.hotkeys.info("Secure Input released — hotkeys live again")
        }
    }

    /// Names the process macOS credits with the flag. The window server publishes the
    /// PID in the session dictionary, but reports it wrongly often enough when a
    /// *background* app takes the flag (rdar://48953777) that this is a hint to show
    /// the user, never a fact to branch on.
    private static func currentHolderName() -> String? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = (session[Self.secureInputPIDKey] as? NSNumber)?.int32Value
        else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "PID \(pid)"
    }
}
