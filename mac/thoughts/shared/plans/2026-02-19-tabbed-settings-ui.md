# Tabbed Settings UI with Modes Implementation Plan

## Overview

Replace the current single-pane Settings window with a tabbed main window (Home, Modes, Transcription) that auto-opens on launch. Introduce a "Mode" data model to decouple action configuration from global settings, enabling multiple named modes with different post-transcription behaviors.

## Current State Analysis

- **App entry point** (`vcdrApp.swift`): `MenuBarExtra` + `Window("VCDR Settings", id: "settings")`
- **Settings window** (`SettingsView.swift`): Single form with hotkey recorder, action picker, status section
- **Settings model** (`AppSettings.swift`): Stores `hotkeyKeyCode`, `hotkeyModifiers`, `actionType`, `bashCommand` flat in UserDefaults
- **Coordinator** (`PushToTalkCoordinator.swift:138-145`): `makeAction()` reads `settings.actionType` and `settings.bashCommand` directly
- **ShortcutRecorderRow** (`ShortcutRecorderRow.swift`): No reset/unassign capability; creates a throwaway `GlobalHotkeyManager()` for display string (line 41) — wasteful but harmless
- **Permissions**: Requested once in `AppDependencies.requestAllPermissions()` but status not exposed as observable state

### Key Discoveries:
- `AppSettings` stores action config flat — needs to move into `Mode` structs
- `ShortcutRecorderRow` (line 41) and `MenuBarView` (line 61) both create throwaway `GlobalHotkeyManager()` just to call `shortcutDisplayString` — this method should be a static/free function
- No existing concept of "modes" — this is entirely new
- `ParakeetProvider` exposes `name = "Parakeet Multilingual v3"` and `isReady` — enough for Transcription tab status
- `AppDependencies.initializationStatus` tracks "Downloading Parakeet model..." / "Ready" / "Failed: ..." — can derive download state from this

## Desired End State

A main window opens on app launch with three tabs:

1. **Home** — Permissions status (conditional red banner) + Push-to-talk shortcut recorder with reset
2. **Modes** — List of modes with inline expansion editor (name, action type). "+" to add, first mode is always active
3. **Transcription** — Parakeet model with version and download status indicator

The `MenuBarExtra` dropdown remains as-is but its "Settings..." button opens this same window.

### How to verify:
- App launches → main window appears with 3 tabs
- Permissions section appears red only when mic or accessibility is missing
- Hotkey can be recorded, reset, and unassigned
- Default mode exists on first launch; can be renamed, action changed
- New modes can be added via "+"
- Transcription tab shows Parakeet status correctly
- Push-to-talk still works end-to-end using first mode's action config

## What We're NOT Doing

- Active mode selector (always first mode for now)
- Mode deletion (can be added later)
- Mode reordering
- Multiple transcription models / model switching
- Model download management (download-on-demand) — Parakeet auto-downloads on launch as before

## Implementation Approach

Bottom-up: data model first, then UI, then wiring. This lets us build incrementally and test each layer.

---

## Phase 1: Mode Data Model + Settings Migration

### Overview
Create the `Mode` struct, migrate `AppSettings` to store modes, and keep backward compatibility with existing UserDefaults data.

### Changes Required:

#### 1. New file: `Core/Settings/Mode.swift`

```swift
import Foundation

struct Mode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var actionType: PostTranscriptionActionType
    var bashCommand: String

    static func makeDefault() -> Mode {
        Mode(
            id: UUID(),
            name: "Default",
            actionType: .paste,
            bashCommand: "echo {}"
        )
    }
}
```

#### 2. Update `Core/Settings/AppSettings.swift`

Replace flat `actionType`/`bashCommand` with `modes: [Mode]` array. Keep `hotkeyKeyCode`/`hotkeyModifiers` as global (they're not per-mode). Add computed `activeMode` returning first mode.

```swift
@Observable
final class AppSettings {
    var hotkeyKeyCode: UInt16 {
        didSet { save() }
    }
    var hotkeyModifiers: UInt64 {
        didSet { save() }
    }
    var modes: [Mode] {
        didSet { save() }
    }

    // Active mode is always the first mode
    var activeMode: Mode {
        get { modes.first ?? Mode.makeDefault() }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let savedKeyCode = userDefaults.integer(forKey: "hotkeyKeyCode")
        self.hotkeyKeyCode = savedKeyCode != 0 ? UInt16(savedKeyCode) : 49

        let savedModifiers = userDefaults.integer(forKey: "hotkeyModifiers")
        if savedModifiers != 0 {
            self.hotkeyModifiers = UInt64(savedModifiers)
        } else {
            self.hotkeyModifiers = UInt64(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue)
        }

        // Migrate from flat actionType/bashCommand or load modes
        if let modesData = userDefaults.data(forKey: "modes"),
           let decoded = try? JSONDecoder().decode([Mode].self, from: modesData),
           !decoded.isEmpty {
            self.modes = decoded
        } else {
            // Migration: read old flat values into a Default mode
            let oldActionType = PostTranscriptionActionType(
                rawValue: userDefaults.string(forKey: "actionType") ?? ""
            ) ?? .paste
            let oldBashCommand = userDefaults.string(forKey: "bashCommand") ?? "echo {}"
            self.modes = [Mode(
                id: UUID(),
                name: "Default",
                actionType: oldActionType,
                bashCommand: oldBashCommand
            )]
        }
    }

    private func save() {
        userDefaults.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode")
        userDefaults.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers")
        if let encoded = try? JSONEncoder().encode(modes) {
            userDefaults.set(encoded, forKey: "modes")
        }
        Logger.settings.info("Settings saved")
    }
}
```

Remove the old `actionType` and `bashCommand` stored properties entirely. The old UserDefaults keys (`actionType`, `bashCommand`) are read once for migration, then `modes` takes over.

#### 3. Update `PushToTalkCoordinator.swift` — `makeAction()`

Change from reading `settings.actionType` / `settings.bashCommand` to reading `settings.activeMode`:

```swift
private func makeAction() -> any PostTranscriptionAction {
    let mode = settings.activeMode
    switch mode.actionType {
    case .paste:
        PasteAction()
    case .bash:
        BashAction(commandTemplate: mode.bashCommand)
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- [ ] No compiler warnings related to removed `actionType`/`bashCommand` properties

#### Manual Verification:
- [ ] Existing UserDefaults data migrates correctly (old action type preserved in Default mode)
- [ ] Push-to-talk still works end-to-end

---

## Phase 2: Extract `shortcutDisplayString` + Enhance ShortcutRecorderRow

### Overview
Make `shortcutDisplayString` a static utility (stop creating throwaway `GlobalHotkeyManager` instances). Add reset/unassign to the shortcut recorder.

### Changes Required:

#### 1. Move display helpers to static methods on `GlobalHotkeyManager`

In `Hotkeys/GlobalHotkeyManager.swift`, make `shortcutDisplayString` and `keyNameForCode` static:

```swift
static func shortcutDisplayString(keyCode: CGKeyCode, modifiers: CGEventFlags) -> String {
    var parts: [String] = []
    if modifiers.contains(.maskControl) { parts.append("\u{2303}") }
    if modifiers.contains(.maskAlternate) { parts.append("\u{2325}") }
    if modifiers.contains(.maskShift) { parts.append("\u{21E7}") }
    if modifiers.contains(.maskCommand) { parts.append("\u{2318}") }
    parts.append(keyNameForCode(keyCode))
    return parts.joined()
}

static func keyNameForCode(_ keyCode: CGKeyCode) -> String { ... }
```

Keep the instance methods as wrappers if needed internally, or update all call sites to use the static versions.

Update call sites:
- `MenuBarView.swift:61` — use `GlobalHotkeyManager.shortcutDisplayString(...)`
- `ShortcutRecorderRow.swift:41` — use `GlobalHotkeyManager.shortcutDisplayString(...)`

#### 2. Enhance `ShortcutRecorderRow` with reset/unassign

Add a "clear" button (X icon) that sets keyCode=0 and modifiers=0. Display "Not set" when unassigned.

Use sentinel value `keyCode == 0 && modifiers == 0` to mean "no hotkey assigned".

```swift
struct ShortcutRecorderRow: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt64
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    private static let unassignedKeyCode: UInt16 = 0
    private static let unassignedModifiers: UInt64 = 0

    private var isAssigned: Bool {
        keyCode != Self.unassignedKeyCode || modifiers != Self.unassignedModifiers
    }

    var body: some View {
        HStack {
            Button(action: { toggleRecording() }) {
                Text(isRecording ? "Press a key combo..." : displayString)
                    .frame(minWidth: 140)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            // ... existing styling ...

            if isAssigned && !isRecording {
                Button(action: { clearShortcut() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }

            if isRecording {
                Button("Cancel") { stopRecording() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayString: String {
        guard isAssigned else { return "Not set" }
        return GlobalHotkeyManager.shortcutDisplayString(
            keyCode: CGKeyCode(keyCode),
            modifiers: CGEventFlags(rawValue: modifiers)
        )
    }

    private func clearShortcut() {
        keyCode = Self.unassignedKeyCode
        modifiers = Self.unassignedModifiers
    }
    // ... rest unchanged ...
}
```

#### 3. Update hotkey registration to handle "unassigned"

In `PushToTalkCoordinator.setupHotkey()`, skip registration when keyCode is 0:

```swift
func setupHotkey() {
    let keyCode = CGKeyCode(settings.hotkeyKeyCode)
    guard keyCode != 0 else {
        hotkeyManager.unregister()
        Logger.hotkeys.info("Hotkey unassigned, unregistered")
        return
    }
    // ... existing registration code ...
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Shortcut shows "Not set" when cleared
- [ ] X button clears the shortcut
- [ ] Hotkey unregisters when cleared
- [ ] Re-recording a new shortcut works after clearing

---

## Phase 3: Permission Monitoring

### Overview
Add observable permission state so the Home tab can show/hide the permissions section.

### Changes Required:

#### 1. Add permission state to `AppDependencies`

Add observable properties and a polling mechanism:

```swift
// In AppDependencies.swift
private(set) var hasMicrophonePermission = false
private(set) var hasAccessibilityPermission = false

var needsPermissionAttention: Bool {
    !hasMicrophonePermission || !hasAccessibilityPermission
}

func initialize() async {
    checkPermissions()
    startPermissionPolling()
    // ... existing initialization ...
}

private func checkPermissions() {
    hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    hasAccessibilityPermission = AXIsProcessTrusted()
}

private static let permissionPollInterval: TimeInterval = 2

private func startPermissionPolling() {
    Timer.scheduledTimer(withTimeInterval: Self.permissionPollInterval, repeats: true) { [weak self] timer in
        guard let self else { timer.invalidate(); return }
        self.checkPermissions()
        // Stop polling once both are granted
        if self.hasMicrophonePermission && self.hasAccessibilityPermission {
            timer.invalidate()
        }
    }
}
```

Also consolidate the existing accessibility polling (`setupHotkeyWhenAccessible`) into this single timer — when accessibility becomes granted, also trigger `coordinator.setupHotkey()`.

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds

#### Manual Verification:
- [ ] Permission states update within 2 seconds of granting

---

## Phase 4: Tabbed Main Window UI

### Overview
Create the 3-tab main window and wire it to open on app launch. Replace the old `SettingsView`.

### Changes Required:

#### 1. New file: `UI/MainWindowView.swift`

```swift
import SwiftUI

struct MainWindowView: View {
    let dependencies: AppDependencies

    var body: some View {
        TabView {
            HomeTabView(dependencies: dependencies)
                .tabItem { Label("Home", systemImage: "house") }

            ModesTabView(settings: dependencies.settings)
                .tabItem { Label("Modes", systemImage: "list.bullet") }

            TranscriptionTabView(dependencies: dependencies)
                .tabItem { Label("Transcription", systemImage: "waveform") }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
```

#### 2. New file: `UI/HomeTabView.swift`

```swift
import SwiftUI
import AVFoundation

struct HomeTabView: View {
    let dependencies: AppDependencies

    var body: some View {
        Form {
            if dependencies.needsPermissionAttention {
                Section {
                    if !dependencies.hasMicrophonePermission {
                        LabeledContent("Microphone") {
                            Button("Grant Access") {
                                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                            }
                        }
                        Text("Required to record your voice for transcription.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !dependencies.hasAccessibilityPermission {
                        LabeledContent("Accessibility") {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(
                                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                                )
                            }
                        }
                        Text("Required to paste transcribed text into active apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Permissions Required", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Shortcuts") {
                ShortcutRecorderRow(
                    keyCode: Binding(
                        get: { dependencies.settings.hotkeyKeyCode },
                        set: {
                            dependencies.settings.hotkeyKeyCode = $0
                            dependencies.coordinator.updateHotkey()
                        }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.hotkeyModifiers },
                        set: {
                            dependencies.settings.hotkeyModifiers = $0
                            dependencies.coordinator.updateHotkey()
                        }
                    )
                )
            }
        }
        .formStyle(.grouped)
    }
}
```

The Permissions section uses a red-tinted header and only appears when at least one permission is missing.

#### 3. New file: `UI/ModesTabView.swift`

```swift
import SwiftUI

struct ModesTabView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach($settings.modes) { $mode in
                    DisclosureGroup {
                        ModeEditorContent(mode: $mode)
                    } label: {
                        HStack {
                            Text(mode.name)
                            Spacer()
                            Text(mode.actionType == .paste ? "Paste" : "Script")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Modes")
                    Spacer()
                    Button(action: { addMode() }) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addMode() {
        let newMode = Mode(
            id: UUID(),
            name: "New Mode",
            actionType: .paste,
            bashCommand: "echo {}"
        )
        settings.modes.append(newMode)
    }
}

private struct ModeEditorContent: View {
    @Binding var mode: Mode

    var body: some View {
        TextField("Name", text: $mode.name)
            .textFieldStyle(.roundedBorder)

        Picker("Action", selection: $mode.actionType) {
            Text("Paste (Cmd+V)").tag(PostTranscriptionActionType.paste)
            Text("Custom script").tag(PostTranscriptionActionType.bash)
        }
        .pickerStyle(.radioGroup)

        if mode.actionType == .bash {
            TextField("Command (use {} for text)", text: $mode.bashCommand)
                .textFieldStyle(.roundedBorder)
                .help("Use {} as placeholder for transcribed text")
        }
    }
}
```

#### 4. New file: `UI/TranscriptionTabView.swift`

```swift
import SwiftUI

struct TranscriptionTabView: View {
    let dependencies: AppDependencies

    var body: some View {
        Form {
            Section("Models") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Parakeet v3")
                            .font(.headline)
                        Text("Multilingual speech-to-text (CoreML)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    ModelStatusBadge(
                        isReady: dependencies.isTranscriptionReady,
                        statusText: dependencies.initializationStatus
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelStatusBadge: View {
    let isReady: Bool
    let statusText: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(badgeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(badgeColor.opacity(0.1))
        .cornerRadius(12)
    }

    private var badgeColor: Color {
        if isReady { return .green }
        if statusText.hasPrefix("Failed") { return .red }
        return .gray
    }

    private var badgeText: String {
        if isReady { return "Downloaded" }
        if statusText.hasPrefix("Failed") { return "Error" }
        return "Downloading..."
    }
}
```

#### 5. Update `vcdrApp.swift`

Replace the `Window("VCDR Settings", ...)` with the new main window. Open it on launch from the MenuBarExtra task.

```swift
@main
struct vcdrApp: App {
    @State private var dependencies = AppDependencies()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(dependencies: dependencies)
                .task {
                    await dependencies.initialize()
                }
        } label: {
            Image(systemName: dependencies.coordinator.menuBarIcon)
        }

        Window("VCDR", id: "main") {
            MainWindowView(dependencies: dependencies)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 450)
    }
}
```

Note: `@Environment(\.openWindow)` is not available directly in `App` body. To auto-open on launch, we'll use one of these approaches (try in order):
1. Call `openWindow(id: "main")` from `MenuBarView`'s `.task` modifier (it has access to `@Environment`)
2. If that doesn't work, use an `NSApplicationDelegateAdaptor` to send an `NSNotification` that triggers opening

Update `MenuBarView` to open the main window instead of settings:

```swift
// In MenuBarView.swift
Button("Settings...") {
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
}
```

#### 6. Delete `UI/SettingsView.swift`

All its functionality is now in `HomeTabView` (shortcuts) and `ModesTabView` (action config). The status section is split across Home (permissions) and Transcription (model status).

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- [ ] No references to old `SettingsView` remain

#### Manual Verification:
- [ ] App launch → main window appears with 3 tabs
- [ ] Home tab shows permissions section (red) when mic or accessibility missing
- [ ] Home tab hides permissions section when both granted
- [ ] Shortcut recorder works with reset/unassign
- [ ] Modes tab shows "Default" mode, expandable inline
- [ ] Can rename Default mode, change action type
- [ ] "+" adds a new mode
- [ ] Transcription tab shows Parakeet status
- [ ] Menu bar "Settings..." opens the same window
- [ ] Push-to-talk works end-to-end using first mode's config

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding.

---

## Files Summary

### New Files (5):
- `Core/Settings/Mode.swift` — Mode data model
- `UI/MainWindowView.swift` — Tab container
- `UI/HomeTabView.swift` — Permissions + shortcuts
- `UI/ModesTabView.swift` — Mode list with inline editor
- `UI/TranscriptionTabView.swift` — Model status display

### Modified Files (6):
- `Core/Settings/AppSettings.swift` — Modes array, migration, remove flat action props
- `Hotkeys/GlobalHotkeyManager.swift` — Static display helpers
- `UI/ShortcutRecorderRow.swift` — Add reset/unassign, use static helper
- `UI/MenuBarView.swift` — Use static helper, open main window
- `Orchestration/PushToTalkCoordinator.swift` — Use activeMode
- `vcdrApp.swift` — New window scene, auto-open

### Deleted Files (1):
- `UI/SettingsView.swift` — Replaced by tab views

## References
- Current settings: `vcdr/vcdr/Core/Settings/AppSettings.swift`
- Current UI: `vcdr/vcdr/UI/SettingsView.swift`
- Coordinator action logic: `vcdr/vcdr/Orchestration/PushToTalkCoordinator.swift:138-145`
