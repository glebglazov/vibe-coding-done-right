# Xcode-Style Settings Window Implementation Plan

## Overview

Redesign the VCDR settings window to match Xcode's Settings layout: a permanent sidebar with icon+label tabs on the left, content area on the right. The Modes tab gets a NavigationStack-based list where each mode is a NavigationLink row with a chevron, pushing to a detail view with back/forward toolbar buttons. Home tab gets a "Quick Actions" section with the recording button and active mode hint.

## Current State Analysis

- `MainWindowView` uses a plain `TabView` with three `.tabItem` tabs (Home, Modes, Transcription)
- `ModesTabView` uses `NavigationSplitView` with its own sidebar list + detail pane
- `HomeTabView` has permissions, recording button, and shortcut sections in a flat `Form`
- Window is defined in `vcdrApp.swift` as `Window("VCDR", id: "main")`

### Key Discoveries:
- `ModesTabView` already has `NavigationSplitView` — this creates a nested sidebar problem. Replacing the outer `TabView` with `NavigationSplitView` means Modes must switch to `NavigationStack` internally
- `MainWindowView.swift:7-16` — the `TabView` with no selection binding
- `ModesTabView.swift:8-43` — the `NavigationSplitView` that needs to be replaced
- `HomeTabView.swift:51-66` — the recording button section to restructure

## What We're NOT Doing

- Not changing app functionality or business logic
- Not modifying `AppDependencies`, `AppSettings`, `Mode`, `PushToTalkCoordinator`
- Not changing the `MenuBarExtra` scene
- Not adding forward navigation button (only back — we have a single-level push, so forward doesn't apply)

## Desired End State

The settings window has:
1. **Permanent sidebar** (left) with three items: Home (house icon), Modes (list.bullet icon), Transcription (waveform icon)
2. **Content area** (right) that changes based on sidebar selection
3. **Modes content**: A list of mode rows, each with name + action type subtitle + chevron. Clicking a row pushes to a detail form. A toolbar back button (`< Modes`) returns to the list. A "+" button in the toolbar or below the list adds new modes.
4. **Home content**: Permissions section (when needed), then "Quick Actions" section with recording button + active mode hint, then Shortcuts section
5. **Transcription content**: Same as now (model status)

### Verification:
- Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- Sidebar tabs switch content correctly
- Modes list shows all modes with chevrons
- Clicking a mode pushes to detail with back button
- Back button returns to modes list
- Home tab shows "Quick Actions" with recording button and active mode name
- Window looks like Xcode Settings (sidebar + content, no nested sidebars)

## Implementation Approach

Replace the `TabView` in `MainWindowView` with a `NavigationSplitView` that has a sidebar `List` of tabs. The detail column hosts the content for the selected tab. For Modes, embed a `NavigationStack` inside the detail column so mode rows can push to detail views with a back button.

## Phase 1: Restructure MainWindowView as NavigationSplitView

### Overview
Replace `TabView` with `NavigationSplitView` + sidebar `List`. Add a `SettingsTab` enum for sidebar items.

### Changes Required:

#### 1. MainWindowView.swift — complete rewrite

**File**: `vcdr/vcdr/UI/MainWindowView.swift`

Replace the `TabView` with:

```swift
import SwiftUI

struct MainWindowView: View {
    let dependencies: AppDependencies

    enum Tab: String, CaseIterable, Hashable {
        case home
        case modes
        case transcription

        var title: String {
            switch self {
            case .home: "Home"
            case .modes: "Modes"
            case .transcription: "Transcription"
            }
        }

        var systemImage: String {
            switch self {
            case .home: "house"
            case .modes: "list.bullet"
            case .transcription: "waveform"
            }
        }
    }

    // MARK: - Constants
    private static let sidebarWidth: CGFloat = 180
    private static let windowMinWidth: CGFloat = 550
    private static let windowMinHeight: CGFloat = 400

    @State private var selection: Tab? = .home
    @State private var modesPath = NavigationPath()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.doubleColumn)) {
            List(Tab.allCases, id: \.self, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
        } detail: {
            switch selection {
            case .home:
                HomeTabView(dependencies: dependencies)
            case .modes:
                NavigationStack(path: $modesPath) {
                    ModesListView(settings: dependencies.settings)
                        .navigationDestination(for: UUID.self) { modeID in
                            if let index = dependencies.settings.modes.firstIndex(where: { $0.id == modeID }) {
                                ModeDetailView(
                                    mode: Binding(
                                        get: { dependencies.settings.modes[index] },
                                        set: { dependencies.settings.modes[index] = $0 }
                                    ),
                                    modesPath: $modesPath
                                )
                            }
                        }
                }
            case .transcription:
                TranscriptionTabView(dependencies: dependencies)
            case .none:
                Text("Select a section")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: Self.windowMinWidth, minHeight: Self.windowMinHeight)
        .onChange(of: selection) {
            // Reset modes navigation when switching tabs
            modesPath = NavigationPath()
        }
    }
}
```

The `modesPath` is owned here so it resets when switching sidebar tabs.

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Sidebar shows three items with icons
- [ ] Clicking sidebar items switches the content area
- [ ] Sidebar is permanently visible (no toggle button)

---

## Phase 2: Rewrite ModesTabView as flat list with NavigationLink rows

### Overview
Replace `ModesTabView`'s `NavigationSplitView` with a flat `ModesListView` that renders `NavigationLink` rows (chevron disclosure). Extract `ModeDetailView` to accept a `NavigationPath` binding for the back button.

### Changes Required:

#### 1. ModesTabView.swift — rewrite as ModesListView + ModeDetailView

**File**: `vcdr/vcdr/UI/ModesTabView.swift`

Replace entirely with:

```swift
import SwiftUI

/// List of modes with NavigationLink rows (chevrons).
/// Lives inside a NavigationStack owned by MainWindowView.
struct ModesListView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        List {
            ForEach(settings.modes) { mode in
                NavigationLink(value: mode.id) {
                    ModeRowView(
                        mode: mode,
                        isActive: mode.id == settings.activeModeID
                    )
                }
                .contextMenu {
                    Button("Set as Active") {
                        settings.activeModeID = mode.id
                    }
                    .disabled(mode.id == settings.activeModeID)

                    Divider()

                    Button("Delete", role: .destructive) {
                        deleteMode(mode)
                    }
                    .disabled(settings.modes.count <= 1)
                }
            }
        }
        .navigationTitle("Modes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addMode) {
                    Image(systemName: "plus")
                }
                .help("Add new mode")
            }
        }
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

    private func deleteMode(_ mode: Mode) {
        guard settings.modes.count > 1 else { return }
        settings.modes.removeAll { $0.id == mode.id }
        // If we deleted the active mode, activate the first remaining
        if settings.activeModeID == mode.id {
            settings.activeModeID = settings.modes.first?.id ?? UUID()
        }
    }
}

// MARK: - Mode Row

private struct ModeRowView: View {
    let mode: Mode
    let isActive: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(mode.name)
                Text(mode.actionType == .paste ? "Paste" : "Script")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Mode Detail View (pushed via NavigationLink)

struct ModeDetailView: View {
    @Binding var mode: Mode
    @Binding var modesPath: NavigationPath

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $mode.name)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Action") {
                Picker("Type", selection: $mode.actionType) {
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
        .formStyle(.grouped)
        .navigationTitle(mode.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    modesPath.removeLast()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .fontWeight(.semibold)
                        Text("Modes")
                    }
                }
                .disabled(modesPath.isEmpty)
            }
        }
    }
}
```

Key changes from current `ModesTabView`:
- No more `NavigationSplitView` — it's a flat `List` with `NavigationLink(value:)` rows
- Each row shows mode name, action type subtitle, and "Active" badge
- `NavigationLink` provides the chevron `>` automatically
- Detail view has a `< Modes` back button via `ToolbarItem(placement: .navigation)`
- Mode CRUD: "+" in toolbar, delete via context menu, set active via context menu

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Modes list shows all modes with chevrons
- [ ] Clicking a mode pushes to detail view
- [ ] Back button (`< Modes`) returns to list
- [ ] "+" button adds a new mode
- [ ] Right-click context menu works (Set as Active, Delete)
- [ ] Active mode shows "Active" badge

---

## Phase 3: Restructure HomeTabView with Quick Actions section

### Overview
Reorganize `HomeTabView` to have a dedicated "Quick Actions" section with the recording button and a hint about which mode is currently active.

### Changes Required:

#### 1. HomeTabView.swift — reorganize sections

**File**: `vcdr/vcdr/UI/HomeTabView.swift`

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
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Microphone")
                                    .fontWeight(.medium)
                                Text("Required to record your voice for transcription.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Grant Access") {
                                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                            }
                            .controlSize(.small)
                        }
                    }
                    if !dependencies.hasAccessibilityPermission {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Accessibility")
                                    .fontWeight(.medium)
                                Text("Required to paste transcribed text into active apps.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open Settings") {
                                NSWorkspace.shared.open(
                                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                                )
                            }
                            .controlSize(.small)
                        }
                    }
                } header: {
                    Label("Permissions Required", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Quick Actions") {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Button(action: { dependencies.coordinator.toggleRecording() }) {
                            Label(
                                isRecording ? "Stop Recording" : "Start Recording",
                                systemImage: isRecording ? "stop.circle.fill" : "record.circle"
                            )
                            .font(.title3)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isRecording ? .red : .accentColor)
                        .disabled(!canToggleRecording)

                        Text("Active mode: \(dependencies.settings.activeMode.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
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

    private var isRecording: Bool {
        dependencies.coordinator.state == .recording
    }

    private var canToggleRecording: Bool {
        let state = dependencies.coordinator.state
        return state == .idle || state == .recording
    }
}
```

Key changes:
- Recording button section renamed from unnamed to "Quick Actions"
- Added `Text("Active mode: \(dependencies.settings.activeMode.name)")` hint below the button
- Wrapped button + hint in a `VStack` with spacing

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Home tab shows "Quick Actions" section header
- [ ] Recording button is centered with active mode hint below it
- [ ] Active mode name updates when changing modes

---

## Phase 4: Update vcdrApp window sizing

### Overview
Adjust window default size to accommodate the sidebar layout.

### Changes Required:

#### 1. vcdrApp.swift — update window size

**File**: `vcdr/vcdr/vcdrApp.swift`

Change `.defaultSize(width: 500, height: 450)` to `.defaultSize(width: 650, height: 450)` to accommodate the sidebar width.

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Window opens at a comfortable size with sidebar visible
- [ ] Content area has enough space for mode detail forms

---

## Testing Strategy

### Manual Testing Steps:
1. Launch app — main window should open with sidebar on left
2. Click each sidebar item — content area switches correctly
3. Go to Modes — see list of modes with chevron disclosure indicators
4. Click a mode — detail view pushes in with `< Modes` back button
5. Click back — returns to modes list
6. Click "+" — new mode appears in list
7. Right-click a mode — context menu with "Set as Active" and "Delete"
8. Go to Home — see Quick Actions with recording button and active mode hint
9. Switch sidebar tabs rapidly — no crashes, modes navigation resets
10. Resize window — sidebar stays visible, content reflows

## References

- Xcode Settings screenshot (user-provided) — target visual reference
- `NavigationSplitView` + `NavigationStack` pattern for macOS settings windows
- `ToolbarItem(placement: .navigation)` for macOS back button
- `NavigationLink(value:)` + `.navigationDestination(for:)` for push navigation
