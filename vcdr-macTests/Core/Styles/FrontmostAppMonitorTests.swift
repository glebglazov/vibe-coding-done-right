import Foundation
import Testing
@testable import vcdr_mac

// MARK: - FrontmostAppMonitor Tests

@Suite("FrontmostAppMonitor")
@MainActor
struct FrontmostAppMonitorTests {

    @Test("Initial state has no current bundle ID")
    func initialStateHasNoBundleID() async throws {
        let monitor = FrontmostAppMonitor()

        #expect(monitor.currentBundleID == nil)
    }

    @Test("Mock monitor can simulate app changes")
    func mockMonitorCanSimulateChanges() async throws {
        let monitor = MockFrontmostAppMonitor(initialBundleID: nil)

        #expect(monitor.currentBundleID == nil)

        monitor.simulateAppChange(bundleID: "com.apple.Safari")
        #expect(monitor.currentBundleID == "com.apple.Safari")

        monitor.simulateAppChange(bundleID: "com.apple.Mail")
        #expect(monitor.currentBundleID == "com.apple.Mail")
    }

    @Test("Mock monitor can simulate permission changes")
    func mockMonitorCanSimulatePermissionChanges() async throws {
        let monitor = MockFrontmostAppMonitor(
            initialBundleID: nil,
            hasAccessibilityPermission: true
        )

        #expect(monitor.hasAccessibilityPermission == true)

        monitor.simulatePermissionChange(granted: false)
        #expect(monitor.hasAccessibilityPermission == false)

        monitor.simulatePermissionChange(granted: true)
        #expect(monitor.hasAccessibilityPermission == true)
    }

    @Test("Mock monitor stream yields current value on subscription")
    func mockStreamYieldsCurrentValue() async throws {
        let monitor = MockFrontmostAppMonitor(initialBundleID: "com.test.app")

        let stream = monitor.bundleIDStream
        var values: [String?] = []

        let task = Task {
            for await bundleID in stream {
                values.append(bundleID)
                if values.count >= 1 { break }
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        #expect(values.count == 1)
        #expect(values[0] == "com.test.app")
    }

    @Test("Mock monitor stream updates on app change")
    func mockStreamUpdatesOnChange() async throws {
        let monitor = MockFrontmostAppMonitor(initialBundleID: nil)

        let stream = monitor.bundleIDStream
        var values: [String?] = []

        let task = Task {
            for await bundleID in stream {
                values.append(bundleID)
                if values.count >= 2 { break }
            }
        }

        // Wait for initial value
        try? await Task.sleep(for: .milliseconds(10))

        // Simulate change
        monitor.simulateAppChange(bundleID: "com.apple.Safari")

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        #expect(values.count >= 2)
        #expect(values[0] == nil)
        #expect(values[1] == "com.apple.Safari")
    }

    @Test("Monitor conforms to FrontmostAppMonitoring protocol")
    func monitorConformsToProtocol() async throws {
        let monitor: any FrontmostAppMonitoring = FrontmostAppMonitor()

        // Verify protocol methods exist and can be called
        _ = monitor.currentBundleID
        _ = monitor.hasAccessibilityPermission
        _ = monitor.bundleIDStream
        _ = monitor.checkAccessibilityPermission()

        await monitor.startMonitoring()
        monitor.stopMonitoring()
    }

    @Test("Mock monitor conforms to FrontmostAppMonitoring protocol")
    func mockMonitorConformsToProtocol() async throws {
        let monitor: any FrontmostAppMonitoring = MockFrontmostAppMonitor()

        _ = monitor.currentBundleID
        _ = monitor.hasAccessibilityPermission
        _ = monitor.bundleIDStream

        await monitor.startMonitoring()
        monitor.stopMonitoring()
    }
}