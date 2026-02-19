# Home Recording Button + Modes Navigation + Active Mode Selection

## Overview

Three enhancements: (1) add a Start/Stop recording button to the Home tab, (2) replace inline mode editing with navigation to a separate detail pane, (3) add active mode selection so the user can pick which mode is used during recording.

## Current State

- `HomeTabView.swift` — Permissions section + Shortcuts section, no recording controls
- `ModesTabView.swift` — Uses `DisclosureGroup` for inline editing
- `AppSettings.activeMode` — Returns first mode (no user selection)
- `PushToTalkCoordinator` — `onHotkeyDown()`/`onHotkeyUp()` are private; no way to trigger recording from UI

## Desired End State

1. Home tab has a prominent Start/Stop recording button between permissions and shortcuts
2. Modes tab shows a list; clicking a mode navigates to a detail pane with the edit form + a back button
3. Modes tab lets user mark a mode as "active" (checkmark); active mode is used by the coordinator
4. `AppSettings` persists `activeModeID`

## What We're NOT Doing

- Recording from the Modes or Transcription tabs
- Mode deletion or reordering (future)

## Phase 1: Expose Recording Controls on PushToTalkCoordinator

### Changes Required:

#### `Orchestration/PushToTalkCoordinator.swift`

Add two public methods that the UI button can call. These mirror `onHotkeyDown`/`onHotkeyUp` but are intended for manual (non-push-to-talk) triggering:

```swift
/// Start recording via UI button (not push-to-talk)
func startRecording() async {
    await onHotkeyDown()
}

/// Stop recording via UI button (not push-to-talk)
func stopRecording() async {
    await onHotkeyUp()
}
```

The existing `onHotkeyDown`/`onHotkeyUp` already handle state guards and error cases, so the public methods just delegate.

### Success Criteria:
- [ ] Build succeeds

---

## Phase 2: Add Recording Button to Home Tab

### Changes Required:

#### `UI/HomeTabView.swift`

Add a section between Permissions and Shortcuts with a recording toggle button:

```swift
Section {
    HStack {
        Spacer()
        Button(action: { Task { await toggleRecording() } }) {
            Label(
                dependencies.coordinator.state == .recording ? "Stop Recording" : "Start Recording",
                systemImage: dependencies.coordinator.state == .recording ? "stop.circle.fill" : "record.circle"
            )
            .font(.title3)
        }
        .buttonStyle(.borderedProminent)
        .tint(dependencies.coordinator.state == .recording ? .red : .accentColor)
        .disabled(!canToggleRecording)
        Spacer()
    }
}

// computed properties:
private var canToggleRecording: Bool {
    let state = dependencies.coordinator.state
    return state == .idle || state == .recording
}

private func toggleRecording() async {
    if dependencies.coordinator.state == .recording {
        await dependencies.coordinator.stopRecording()
    } else {
        await dependencies.coordinator.startRecording()
    }
}
```

The button shows "Start Recording" when idle (accent color) and "Stop Recording" when recording (red). Disabled during transcribing/executing/error states.

### Success Criteria:
- [ ] Build succeeds
- [ ] Button starts recording, button stops recording, transcription runs

---

## Phase 3: Active Mode Selection in AppSettings

### Changes Required:

#### `Core/Settings/AppSettings.swift`

Add `activeModeID: UUID` stored property. Change `activeMode` computed property to look up by ID with fallback to first mode:

```swift
var activeModeID: UUID {
    didSet { save() }
}

var activeMode: Mode {
    modes.first(where: { $0.id == activeModeID }) ?? modes.first ?? Mode.makeDefault()
}
```

In `init`, load `activeModeID` from UserDefaults. If not found, use the first mode's ID:

```swift
// After loading modes:
if let savedActiveID = userDefaults.string(forKey: "activeModeID"),
   let uuid = UUID(uuidString: savedActiveID) {
    self.activeModeID = uuid
} else {
    self.activeModeID = self.modes.first?.id ?? UUID()
}
```

In `save()`:
```swift
userDefaults.set(activeModeID.uuidString, forKey: "activeModeID")
```

### Success Criteria:
- [ ] Build succeeds
- [ ] Active mode persists across app restarts

---

## Phase 4: Modes Tab — Navigation to Detail Pane + Active Mode Picker

### Changes Required:

#### `UI/ModesTabView.swift`

Replace `DisclosureGroup` with `NavigationSplitView` (list + detail). Each mode row shows name, action type badge, and a checkmark if it's the active mode. Clicking a row navigates to the detail pane.

```swift
struct ModesTabView: View {
    @Bindable var settings: AppSettings
    @State private var selectedModeID: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedModeID) {
                Section {
                    ForEach(settings.modes) { mode in
                        ModeRow(
                            mode: mode,
                            isActive: mode.id == settings.activeModeID,
                            onSetActive: { settings.activeModeID = mode.id }
                        )
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
        } detail: {
            if let selectedID = selectedModeID,
               let index = settings.modes.firstIndex(where: { $0.id == selectedID }) {
                ModeDetailView(mode: $settings.modes[index])
            } else {
                Text("Select a mode to edit")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

`ModeRow`: Shows mode name, action type label, and a checkmark button to set as active.

`ModeDetailView`: The edit form (name, action picker, bash command) — same content as the old `ModeEditorContent` but in a full pane with a header.

### Success Criteria:
- [ ] Build succeeds
- [ ] Clicking a mode in the list shows its detail pane
- [ ] Checkmark sets the active mode
- [ ] "+" creates a new mode and it appears in the list
- [ ] Active mode persists and is used by push-to-talk

---

## Files Summary

### Modified:
- `Orchestration/PushToTalkCoordinator.swift` — Add public `startRecording()`/`stopRecording()`
- `UI/HomeTabView.swift` — Add recording button section
- `Core/Settings/AppSettings.swift` — Add `activeModeID`, change `activeMode` lookup
- `UI/ModesTabView.swift` — Replace DisclosureGroup with NavigationSplitView + active mode picker
