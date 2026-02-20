# Mode Switcher Popup Implementation Plan

## Overview

Add quick mode switching via: (1) a clickable picker below the "Start Recording" button on the Home tab, and (2) a global hotkey that opens a floating popup (same placement as the recording indicator) showing all modes with keyboard navigation (j/k, arrows, 1-9 number keys, Enter to confirm, Escape to dismiss).

## Current State Analysis

- Modes are stored in `AppSettings.modes: [Mode]` with `activeModeID: UUID` selecting the active one
- Home tab shows `Text("Active mode: \(dependencies.settings.activeMode.name)")` as static text (line 79 of HomeTabView.swift)
- `RecordingIndicatorPanel` positions a floating `NSPanel` at top-center below the menu bar — we model the mode switcher panel after this
- `GlobalHotkeyManager` handles one hotkey (push-to-talk) via a CGEvent tap — we need a second independent hotkey manager for mode switching
- `AppSettings` stores hotkey as `hotkeyKeyCode`/`hotkeyModifiers` — we add a parallel pair for the mode switcher
- `ShortcutRecorderRow` is a reusable shortcut recorder — we reuse it for the new hotkey
- Max 9 modes enforced by the 1-9 number key binding

### Key Discoveries:
- `RecordingIndicatorPanel` at `RecordingIndicator.swift:4` — panel creation pattern to follow
- `GlobalHotkeyManager` at `GlobalHotkeyManager.swift:6` — reusable for a second hotkey since it's not a singleton
- `ShortcutRecorderRow` at `ShortcutRecorderRow.swift:4` — already generic, just needs bindings
- `AppSettings` at `AppSettings.swift:11` — already at 5 observable properties (the CLAUDE.md limit), so the two new hotkey properties must be collapsed into a struct or we use computed properties backed by a single stored struct

## What We're NOT Doing

- Reordering modes from the popup — just selection
- Adding/editing modes from the popup — that stays in Settings > Modes tab
- Changing the recording indicator to show the active mode name

## Approach

### AppSettings property limit workaround

AppSettings is at 5 `@Observable` properties (the CLAUDE.md limit). We need 2 more (mode switcher keyCode + modifiers). Solution: combine all hotkey settings into a single stored struct, with computed accessors for backward compatibility. This replaces 2 properties with 1 struct, netting us room for the mode switcher hotkey.

```swift
struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
}

// Properties become:
var pushToTalkHotkey: HotkeyBinding { didSet { save() } }     // replaces hotkeyKeyCode + hotkeyModifiers
var modeSwitcherHotkey: HotkeyBinding { didSet { save() } }   // new
var modes: [Mode] { didSet { save() } }
var activeModeID: UUID { didSet { save() } }
var preferredInputDeviceID: String? { didSet { save() } }
// = 5 observable properties, at the limit
```

Existing code that reads `settings.hotkeyKeyCode` / `settings.hotkeyModifiers` gets updated to `settings.pushToTalkHotkey.keyCode` / `.modifiers`.

## Implementation Order

### Phase 1: Refactor AppSettings hotkey storage

**File**: `vcdr/vcdr/Core/Settings/AppSettings.swift`

Add `HotkeyBinding` struct. Replace `hotkeyKeyCode`/`hotkeyModifiers` with `pushToTalkHotkey: HotkeyBinding`. Add `modeSwitcherHotkey: HotkeyBinding`. Migrate UserDefaults keys (read old keys as fallback, write new keys). Default mode switcher hotkey: unassigned (keyCode 0, modifiers 0).

**Files to update for the rename** (mechanical — `hotkeyKeyCode` → `pushToTalkHotkey.keyCode`, `hotkeyModifiers` → `pushToTalkHotkey.modifiers`):
- `PushToTalkCoordinator.swift` — `setupHotkey()` reads keyCode/modifiers
- `HomeTabView.swift` — ShortcutRecorderRow bindings
- `MenuBarView.swift` — `hotkeyDisplay` computed property

### Phase 2: Mode Switcher Panel

**New file**: `vcdr/vcdr/UI/ModeSwitcherPanel.swift` (~120 lines)

`ModeSwitcherPanel` class — same pattern as `RecordingIndicatorPanel`:
- `show(modes: [Mode], activeModeID: UUID, onSelect: (UUID) -> Void)`
- `hide()`
- Creates `NSPanel` with same positioning logic as recording indicator but wider
- Hosts `ModeSwitcherView` SwiftUI view
- Panel uses `.nonactivatingPanel` so the frontmost app keeps focus

`ModeSwitcherView` (private struct inside same file):
- Shows each mode as a row: `[1] Mode Name` with highlight on the selected row
- `@State var highlightedIndex` initialized to current active mode index
- Keyboard handling via `.onKeyPress` (macOS 14+):
  - `j` / `↓` — move highlight down
  - `k` / `↑` — move highlight up
  - `1`–`9` — jump to mode by number and confirm immediately
  - `Return` — confirm highlighted mode
  - `Escape` — dismiss without changing
- Mouse: clicking a row selects it immediately

### Phase 3: Mode Switcher Coordinator

**New file**: `vcdr/vcdr/Orchestration/ModeSwitcherCoordinator.swift` (~60 lines)

`@Observable @MainActor` class:
- Owns a `GlobalHotkeyManager` instance (for the mode switcher hotkey)
- Owns a `ModeSwitcherPanel` instance
- `init(settings: AppSettings)` — stores settings reference
- `setupHotkey()` — registers mode switcher hotkey, on key-down toggles the popup
- `updateHotkey()` — re-registers
- `showSwitcher()` — public, for the debug UI button
- `isVisible: Bool` — tracks popup state

On hotkey press:
- If popup is visible → hide it
- If popup is hidden → show it with current modes + activeModeID
- `onSelect` callback sets `settings.activeModeID` and hides the popup

### Phase 4: Wire into AppDependencies

**File**: `vcdr/vcdr/App/AppDependencies.swift`

Add `let modeSwitcherCoordinator: ModeSwitcherCoordinator`, created in `init()`. Call `modeSwitcherCoordinator.setupHotkey()` alongside the push-to-talk hotkey setup in `initialize()`.

### Phase 5: Update Home tab UI

**File**: `vcdr/vcdr/UI/HomeTabView.swift`

1. Replace the static `Text("Active mode: ...")` with a `Picker` (menu style) bound to `settings.activeModeID`
2. Add a second `ShortcutRecorderRow` in the Shortcuts section for the mode switcher hotkey
3. Add a debug-only button to trigger the mode switcher popup:

```swift
#if DEBUG
Button("Test Mode Switcher") {
    dependencies.modeSwitcherCoordinator.showSwitcher()
}
#endif
```

### Phase 6: Update MenuBarView

**File**: `vcdr/vcdr/UI/MenuBarView.swift`

Update `hotkeyDisplay` to use `pushToTalkHotkey.keyCode` / `.modifiers`.

## Verification

- `xcodebuild -scheme vcdr -destination 'platform=macOS' build` succeeds
- Home tab shows a mode picker instead of static text below the recording button
- Changing the picker immediately switches the active mode
- Shortcuts section shows two rows: Push-to-Talk and Mode Switcher
- Pressing the mode switcher hotkey shows a floating popup at the top-center of the screen
- Popup lists all modes with 1-9 numbers
- j/k and arrow keys navigate the highlight
- Number keys jump to that mode and dismiss
- Enter confirms, Escape dismisses
- The previously active app retains focus (panel is non-activating)
- `#if DEBUG` button appears only in debug builds
