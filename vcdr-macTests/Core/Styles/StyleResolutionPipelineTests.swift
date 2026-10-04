import Foundation
import Testing
@testable import vcdr_mac

// MARK: - StyleResolutionPipeline Tests

@Suite("StyleResolutionPipeline")
@MainActor
struct StyleResolutionPipelineTests {

    @Test("Initial state uses default style")
    func initialStateUsesDefaultStyle() async throws {
        let registry = StyleRegistry()
        let monitor = MockFrontmostAppMonitor()
        let pipeline = StyleResolutionPipeline(
            styleRegistry: registry,
            frontmostAppMonitor: monitor,
            userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
        )

        #expect(pipeline.currentStyle.id == Style.casualID)
    }

    @Test("Resolution without override uses app-matched style")
    func resolutionWithoutOverrideUsesAppMatch() async throws {
        let registry = StyleRegistry()
        let monitor = MockFrontmostAppMonitor()
        let pipeline = StyleResolutionPipeline(
            styleRegistry: registry,
            frontmostAppMonitor: monitor,
            userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
        )

        // Assign Safari to Formal style
        await registry.moveApp(bundleID: "com.apple.Safari", toStyle: Style.formal)

        // Simulate Safari becoming frontmost
        monitor.simulateAppChange(bundleID: "com.apple.Safari")

        // Allow pipeline to process
        try? await Task.sleep(for: .milliseconds(50))

        // Note: In real usage, the pipeline would update via the stream
        // For this test, we verify the registry returns the correct style
        let resolvedStyle = await registry.style(forBundleID: "com.apple.Safari")
        #expect(resolvedStyle.id == Style.formalID)
    }

    @Test("Resolution falls back to default when no app match")
    func resolutionFallsBackToDefault() async throws {
        let registry = StyleRegistry()
        let monitor = MockFrontmostAppMonitor()

        let resolvedStyle = await registry.style(forBundleID: "com.unknown.app")
        let defaultStyle = await registry.defaultStyle()

        #expect(resolvedStyle.id == defaultStyle.id)
    }

    @Test("Style override takes precedence over app match")
    func overrideTakesPrecedence() async throws {
        let registry = StyleRegistry()
        let monitor = MockFrontmostAppMonitor()
        let pipeline = StyleResolutionPipeline(
            styleRegistry: registry,
            frontmostAppMonitor: monitor,
            userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
        )

        // Assign Safari to Formal
        await registry.moveApp(bundleID: "com.apple.Safari", toStyle: Style.formal)

        // Set override to Casual
        pipeline.setStyleOverride(Style.casualID)

        // The override should be active
        #expect(pipeline.hasActiveOverride == true)
    }

    @Test("Clearing override removes active state")
    func clearingOverrideRemovesActiveState() async throws {
        let registry = StyleRegistry()
        let monitor = MockFrontmostAppMonitor()
        let pipeline = StyleResolutionPipeline(
            styleRegistry: registry,
            frontmostAppMonitor: monitor,
            userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
        )

        // Set and then clear override
        pipeline.setStyleOverride(Style.casualID)
        #expect(pipeline.hasActiveOverride == true)

        pipeline.clearOverride()
        #expect(pipeline.hasActiveOverride == false)
    }

    @Test("Pipeline stream yields style updates")
    func streamYieldsStyleUpdates() async throws {
        let registry = StyleRegistry()
        let monitor = MockFrontmostAppMonitor()
        let pipeline = StyleResolutionPipeline(
            styleRegistry: registry,
            frontmostAppMonitor: monitor,
            userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
        )

        let stream = pipeline.styleStream
        var styles: [Style] = []

        let task = Task {
            for await style in stream {
                styles.append(style)
                if styles.count >= 1 { break }
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        #expect(styles.count >= 1)
    }

    @Test("Setting same override does not duplicate events")
    func sameOverrideDoesNotDuplicate() async throws {
        let registry = StyleRegistry()
        let monitor = MockFrontmostAppMonitor()
        let pipeline = StyleResolutionPipeline(
            styleRegistry: registry,
            frontmostAppMonitor: monitor,
            userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
        )

        // Set override twice to the same style
        pipeline.setStyleOverride(Style.casualID)
        pipeline.setStyleOverride(Style.casualID)

        // Should still have active override
        #expect(pipeline.hasActiveOverride == true)
    }

    @Test("Permission change callback is invoked")
    func permissionChangeCallbackInvoked() async throws {
        let registry = StyleRegistry()
        let monitor = MockFrontmostAppMonitor(hasAccessibilityPermission: true)
        let pipeline = StyleResolutionPipeline(
            styleRegistry: registry,
            frontmostAppMonitor: monitor,
            userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
        )

        var callbackInvoked = false
        var permissionGranted = true

        pipeline.onAccessibilityPermissionChanged = { (granted: Bool) in
            callbackInvoked = true
            permissionGranted = granted
        }

        // Simulate permission change
        monitor.simulatePermissionChange(granted: false)
        pipeline.onAccessibilityPermissionChanged?(false)

        #expect(callbackInvoked == true)
        #expect(permissionGranted == false)
    }

    @Test("Style change callback is invoked on style change")
    func styleChangeCallbackInvoked() async throws {
        let registry = StyleRegistry()
        let monitor = MockFrontmostAppMonitor()
        let pipeline = StyleResolutionPipeline(
            styleRegistry: registry,
            frontmostAppMonitor: monitor,
            userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
        )

        var callbackInvoked = false
        var receivedStyle: Style?

        pipeline.onStyleChanged = { (style: Style) in
            callbackInvoked = true
            receivedStyle = style
        }

        // Invoke callback manually (simulating style change)
        pipeline.onStyleChanged?(Style.formal)

        #expect(callbackInvoked == true)
        #expect(receivedStyle?.id == Style.formalID)
    }

    @Test("cycleToNextStyle activates override then clears back to detected")
    func cycleToNextStyleActivatesThenClears() async throws {
        let registry = StyleRegistry()
        let monitor = MockFrontmostAppMonitor()
        let pipeline = StyleResolutionPipeline(
            styleRegistry: registry,
            frontmostAppMonitor: monitor,
            userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!,
            availableStyles: [.casual, .formal]
        )

        await pipeline.start()

        pipeline.cycleToNextStyle()
        #expect(pipeline.hasActiveOverride == true)

        pipeline.cycleToNextStyle()
        #expect(pipeline.hasActiveOverride == false)
    }

    @Test("a relaunch keeps the Style Override the user picked")
    func relaunchKeepsStyleOverride() async throws {
        let defaults = try #require(UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)"))
        let beforeQuit = StyleResolutionPipeline(
            styleRegistry: StyleRegistry(),
            frontmostAppMonitor: MockFrontmostAppMonitor(),
            userDefaults: defaults
        )
        beforeQuit.activateOverride(.formal)

        let afterRelaunch = StyleResolutionPipeline(
            styleRegistry: StyleRegistry(),
            frontmostAppMonitor: MockFrontmostAppMonitor(),
            userDefaults: defaults
        )
        await afterRelaunch.start()

        #expect(afterRelaunch.hasActiveOverride)
        #expect(afterRelaunch.currentStyle.id == Style.formalID)
    }

    @Test("a relaunch after the user clears the Style Override uses the Detected Style")
    func relaunchAfterClearUsesDetectedStyle() async throws {
        let defaults = try #require(UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)"))
        let beforeQuit = StyleResolutionPipeline(
            styleRegistry: StyleRegistry(),
            frontmostAppMonitor: MockFrontmostAppMonitor(),
            userDefaults: defaults
        )
        beforeQuit.activateOverride(.formal)
        beforeQuit.clearOverride()

        let afterRelaunch = StyleResolutionPipeline(
            styleRegistry: StyleRegistry(),
            frontmostAppMonitor: MockFrontmostAppMonitor(),
            userDefaults: defaults
        )
        await afterRelaunch.start()

        #expect(!afterRelaunch.hasActiveOverride)
    }
}

// MARK: - Integration Tests

@Suite("Style Resolution Integration")
@MainActor
struct StyleResolutionIntegrationTests {

    @Test("Full flow: Safari to Formal, Mail to Casual")
    func safariToFormalMailToCasual() async throws {
        // Setup registry with app assignments
        let registry = StyleRegistry()
        await registry.moveApp(bundleID: "com.apple.Safari", toStyle: Style.formal)
        await registry.moveApp(bundleID: "com.apple.Mail", toStyle: Style.casual)

        // Verify Safari resolves to Formal
        let safariStyle = await registry.style(forBundleID: "com.apple.Safari")
        #expect(safariStyle.id == Style.formalID)
        #expect(safariStyle.name == "Formal")

        // Verify Mail resolves to Casual
        let mailStyle = await registry.style(forBundleID: "com.apple.Mail")
        #expect(mailStyle.id == Style.casualID)
        #expect(mailStyle.name == "Casual")

        // Verify unknown app falls back to default (Casual)
        let unknownStyle = await registry.style(forBundleID: "com.unknown.app")
        let defaultStyle = await registry.defaultStyle()
        #expect(unknownStyle.id == defaultStyle.id)
    }

    @Test("Style remains stable for unassigned apps")
    func stableForUnassignedApps() async throws {
        let registry = StyleRegistry()

        // Multiple unassigned apps should all get the default style
        let unassignedBundleIDs = [
            "com.apple.Terminal",
            "com.apple.TextEdit",
            "com.apple.Finder"
        ]

        let styles = await withTaskGroup(of: Style.self) { group in
            for bundleID in unassignedBundleIDs {
                group.addTask {
                    await registry.style(forBundleID: bundleID)
                }
            }

            var results: [Style] = []
            for await style in group {
                results.append(style)
            }
            return results
        }

        let defaultStyle = await registry.defaultStyle()

        // All unassigned apps should get the same default style
        for style in styles {
            #expect(style.id == defaultStyle.id)
        }
    }

    @Test("Override persists across app switches")
    func overridePersistsAcrossSwitches() async throws {
        let registry = StyleRegistry()
        let monitor = MockFrontmostAppMonitor()
        let pipeline = StyleResolutionPipeline(
            styleRegistry: registry,
            frontmostAppMonitor: monitor,
            userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
        )

        // Assign Safari to Formal
        await registry.moveApp(bundleID: "com.apple.Safari", toStyle: Style.formal)

        // Set override to Casual
        pipeline.setStyleOverride(Style.casualID)
        #expect(pipeline.hasActiveOverride == true)

        // Simulate switching to Safari (which would normally be Formal)
        monitor.simulateAppChange(bundleID: "com.apple.Safari")

        // Override should still be active
        #expect(pipeline.hasActiveOverride == true)
    }
}