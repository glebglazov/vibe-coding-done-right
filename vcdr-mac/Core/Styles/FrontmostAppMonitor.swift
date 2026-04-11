import Foundation
import Combine
import AppKit
import OSLog

// MARK: - FrontmostAppMonitoring Protocol

/// Protocol for frontmost app monitoring.
/// Allows for mocking in tests and platform-specific implementations.
public protocol FrontmostAppMonitoring: Sendable {
    /// The current frontmost application bundle ID, or nil if unavailable.
    var currentBundleID: String? { get }

    /// Whether accessibility permission is currently granted.
    var hasAccessibilityPermission: Bool { get }

    /// AsyncStream of bundle ID changes.
    var bundleIDStream: AsyncStream<String?> { get }

    /// Callback for permission state changes.
    var onPermissionChanged: ((Bool) -> Void)? { get set }

    /// Start monitoring frontmost application changes.
    func startMonitoring() async

    /// Stop monitoring frontmost application changes.
    func stopMonitoring()

    /// Check current accessibility permission status.
    func checkAccessibilityPermission() -> Bool
}

// MARK: - FrontmostAppMonitor

/// Monitors the frontmost application using NSWorkspace notifications.
///
/// This class:
/// - Listens for `NSWorkspace.didActivateApplicationNotification`
/// - Publishes bundle ID changes via AsyncStream
/// - Handles Accessibility permission state gracefully
/// - Falls back to polling if notifications are unreliable
///
/// ## Permission Handling
/// - Requires Accessibility permission for reliable frontmost app detection
/// - If permission denied: `currentBundleID` returns nil, stream yields nil
/// - UI should show warning when permission is denied
@MainActor
public final class FrontmostAppMonitor: FrontmostAppMonitoring {

    // MARK: - Constants

    /// Polling interval when using fallback polling mechanism.
    private static let pollingInterval: Duration = .milliseconds(100)

    /// Debounce interval for rapid app switches.
    private static let debounceInterval: Duration = .milliseconds(50)

    // MARK: - Properties

    /// The current frontmost application bundle ID, or nil if unavailable.
    @Published
    public private(set) var currentBundleID: String?

    /// Whether accessibility permission is currently granted.
    @Published
    public private(set) var hasAccessibilityPermission: Bool

    /// AsyncStream of bundle ID changes.
    public var bundleIDStream: AsyncStream<String?> {
        AsyncStream { continuation in
            let id = UUID()
            streamContinuations[id] = continuation

            // Yield current value immediately
            continuation.yield(currentBundleID)

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.streamContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Callback for permission state changes.
    public var onPermissionChanged: ((Bool) -> Void)?

    private var streamContinuations: [UUID: AsyncStream<String?>.Continuation] = [:]
    private var notificationObserver: NSObjectProtocol?
    private var pollingTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isMonitoring = false

    // MARK: - Initialization

    /// Creates a new frontmost app monitor.
    public init() {
        self.hasAccessibilityPermission = Self.checkAccessibilityPermissionStatic()
        self.currentBundleID = nil
    }

    // Note: deinit cannot access @MainActor isolated members
    // Cleanup is handled via task cancellation and explicit stopMonitoring() calls

    // MARK: - Public Methods

    /// Starts monitoring frontmost application changes.
    ///
    /// Uses NSWorkspace notifications if available, falls back to polling.
    public func startMonitoring() async {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Check initial permission state
        updatePermissionState()

        // Set up notification observer
        setupNotificationObserver()

        // Start polling as fallback/verification
        startPolling()

        // Fetch initial frontmost app
        await updateFrontmostApp()

        Logger.styles.info("FrontmostAppMonitor started monitoring")
    }

    /// Stops monitoring frontmost application changes.
    public func stopMonitoring() {
        isMonitoring = false

        // Remove notification observer
        if let observer = notificationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            notificationObserver = nil
        }

        // Cancel polling task
        pollingTask?.cancel()
        pollingTask = nil

        // Cancel any pending debounce
        debounceTask?.cancel()
        debounceTask = nil

        // Terminate all stream continuations
        for (_, continuation) in streamContinuations {
            continuation.finish()
        }
        streamContinuations.removeAll()

        Logger.styles.info("FrontmostAppMonitor stopped monitoring")
    }

    /// Checks current accessibility permission status.
    public func checkAccessibilityPermission() -> Bool {
        let granted = Self.checkAccessibilityPermissionStatic()
        if granted != hasAccessibilityPermission {
            hasAccessibilityPermission = granted
            onPermissionChanged?(granted)
        }
        return granted
    }

    // MARK: - Private Methods

    private static func checkAccessibilityPermissionStatic() -> Bool {
        return AXIsProcessTrusted()
    }

    private func updatePermissionState() {
        let granted = Self.checkAccessibilityPermissionStatic()
        if granted != hasAccessibilityPermission {
            hasAccessibilityPermission = granted
            onPermissionChanged?(granted)
            Logger.styles.info("Accessibility permission changed: \(granted ? "granted" : "denied")")
        }
    }

    private func setupNotificationObserver() {
        notificationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                await self?.handleAppActivationNotification(notification)
            }
        }
    }

    private func handleAppActivationNotification(_ notification: Notification) async {
        // Debounce rapid notifications
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await updateFrontmostApp()
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            var lastBundleID: String? = currentBundleID

            while !Task.isCancelled {
                // Update permission state periodically
                updatePermissionState()

                // Check if frontmost app changed
                let newBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if newBundleID != lastBundleID {
                    lastBundleID = newBundleID
                    await updateFrontmostApp(bundleID: newBundleID)
                }

                try? await Task.sleep(for: Self.pollingInterval)
            }
        }
    }

    private func updateFrontmostApp(bundleID: String? = nil) async {
        let newBundleID = bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        guard newBundleID != currentBundleID else { return }

        currentBundleID = newBundleID

        // Notify all stream continuations
        for (_, continuation) in streamContinuations {
            continuation.yield(newBundleID)
        }

        if let bundleID = newBundleID {
            Logger.styles.debug("Frontmost app changed: \(bundleID)")
        } else {
            Logger.styles.debug("Frontmost app changed: nil (permission denied or no app)")
        }
    }
}

// MARK: - Mock Implementation for Testing

#if DEBUG

/// Mock frontmost app monitor for testing.
@MainActor
public final class MockFrontmostAppMonitor: FrontmostAppMonitoring {

    @Published
    public private(set) var currentBundleID: String?

    @Published
    public private(set) var hasAccessibilityPermission: Bool

    public var bundleIDStream: AsyncStream<String?> {
        AsyncStream { continuation in
            let id = UUID()
            streamContinuations[id] = continuation
            continuation.yield(currentBundleID)

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.streamContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public var onPermissionChanged: ((Bool) -> Void)?

    private var streamContinuations: [UUID: AsyncStream<String?>.Continuation] = [:]

    /// Creates a mock monitor with initial values.
    public init(
        initialBundleID: String? = nil,
        hasAccessibilityPermission: Bool = true
    ) {
        self.currentBundleID = initialBundleID
        self.hasAccessibilityPermission = hasAccessibilityPermission
    }

    /// Simulate a frontmost app change.
    public func simulateAppChange(bundleID: String?) {
        currentBundleID = bundleID

        for (_, continuation) in streamContinuations {
            continuation.yield(bundleID)
        }
    }

    /// Simulate accessibility permission change.
    public func simulatePermissionChange(granted: Bool) {
        hasAccessibilityPermission = granted
        onPermissionChanged?(granted)
    }

    public func startMonitoring() async {
        // No-op for mock
    }

    public func stopMonitoring() {
        // Finish all continuations
        for (_, continuation) in streamContinuations {
            continuation.finish()
        }
        streamContinuations.removeAll()
    }

    public func checkAccessibilityPermission() -> Bool {
        return hasAccessibilityPermission
    }
}

#endif