import CoreGraphics
import Foundation
import Testing
@testable import vcdr_mac

/// The mode switcher's shortcut goes through the injected `HotkeyRegistry`, so
/// these press the combination the way the system would rather than calling
/// `showSwitcher()` behind its back. Opening and closing is observed through the
/// delegate, which is what the rest of the app hears.
@Suite("ModeSwitcherCoordinator — Hotkey")
@MainActor
struct ModeSwitcherCoordinatorHotkeyTests {

    /// Records the open/close notifications the coordinator sends out.
    private final class DelegateSpy: ModeSwitcherCoordinatorDelegate {
        var isRecordingActive = false
        var showCount = 0
        var hideCount = 0

        func modeSwitcherWillShow() { showCount += 1 }
        func modeSwitcherDidHide() { hideCount += 1 }
    }

    private struct Environment {
        let coordinator: ModeSwitcherCoordinator
        let settings: AppSettings
        let registry: FakeHotkeyRegistry
        let delegate: DelegateSpy
    }

    private static let binding = HotkeyBinding(
        keyCode: KeyCodeMap.escapeKeyCode,
        modifiers: UInt64(CGEventFlags.maskControl.rawValue)
    )

    private func makeEnvironment(modeCount: Int = 1) -> Environment {
        let settings = AppSettings(userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!, secretStore: InMemorySecretStore())
        settings.hotkeySettings.modeSwitcherHotkey = Self.binding
        // The switcher refuses to open with nothing to switch between, and a fresh
        // settings store has no template modes available.
        var mode = settings.activeMode
        mode.templateID = nil
        mode.processingType = .none
        settings.modes = [mode] + (1..<modeCount).map { Mode(id: UUID(), name: "Mode \($0 + 1)") }
        settings.activeModeID = mode.id

        let registry = FakeHotkeyRegistry()
        let coordinator = ModeSwitcherCoordinator(
            settings: settings,
            hotkeyRegistry: registry,
            overrides: SessionOverrides(),
            styleResolution: StyleResolutionPipeline(
                styleRegistry: StyleRegistry(),
                frontmostAppMonitor: FrontmostAppMonitor(),
                userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
            )
        )
        let delegate = DelegateSpy()
        coordinator.delegate = delegate
        return Environment(coordinator: coordinator, settings: settings, registry: registry, delegate: delegate)
    }

    @Test("Pressing the bound combination opens the switcher, and pressing it again closes it")
    func pressOpensAndClosesTheSwitcher() async {
        let env = makeEnvironment()
        defer { env.coordinator.hideSwitcher() }

        #expect(await waitFor { env.registry.claimedBindings == [Self.binding] })
        #expect(env.registry.press(Self.binding))
        #expect(env.delegate.showCount == 1)

        #expect(env.registry.press(Self.binding))
        #expect(env.delegate.hideCount == 1)
    }

    @Test("Re-binding the switcher shortcut takes effect for the next key press")
    func rebindingAppliesWithoutRelaunch() async {
        let env = makeEnvironment()
        defer { env.coordinator.hideSwitcher() }

        let newBinding = HotkeyBinding(
            keyCode: KeyCodeMap.escapeKeyCode,
            modifiers: UInt64(CGEventFlags.maskCommand.rawValue)
        )
        env.settings.hotkeySettings.modeSwitcherHotkey = newBinding

        #expect(await waitFor { env.registry.press(newBinding) })
        #expect(env.delegate.showCount == 1)
    }

    @Test("A digit picks a mode while the switcher is open, with push-to-talk modifiers still held")
    func aDigitPicksAModeUnderHeldModifiers() async {
        let env = makeEnvironment(modeCount: 2)
        defer { env.coordinator.hideSwitcher() }

        #expect(await waitFor { env.registry.claimedBindings == [Self.binding] })
        #expect(env.registry.press(Self.binding))

        let secondMode = env.settings.modes[1].id
        let digitTwo = HotkeyBinding(
            keyCode: KeyCodeMap.digitKeyCodes[1],
            modifiers: UInt64(CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue)
        )
        #expect(env.registry.press(digitTwo))

        #expect(env.settings.activeModeID == secondMode)
        #expect(env.delegate.hideCount == 1)
    }

    @Test("Closing the switcher hands every navigation key back to the frontmost app")
    func closingReleasesTheNavigationKeys() async {
        let env = makeEnvironment(modeCount: 2)

        #expect(await waitFor { env.registry.claimedBindings == [Self.binding] })
        #expect(env.registry.press(Self.binding))
        #expect(env.registry.claimedBindings.count > 1)

        env.coordinator.hideSwitcher()

        #expect(env.registry.claimedBindings == [Self.binding])
    }

    @Test("Clearing the switcher shortcut hands the combination back")
    func clearingReleasesTheClaim() async {
        let env = makeEnvironment()

        env.settings.hotkeySettings.modeSwitcherHotkey = .unassigned

        #expect(await waitFor { env.registry.claimedBindings.isEmpty })
        #expect(!env.registry.press(Self.binding))
        #expect(env.delegate.showCount == 0)
    }
}
