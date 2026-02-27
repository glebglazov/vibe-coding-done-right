# Modes Form UX Improvements

## Overview

Two small UX fixes for the Modes settings tab:
1. Clicking "+" should immediately navigate to the new mode's detail form, with auto-generated unique names
2. TextField text content should be left-aligned (currently right-aligned in grouped form, making spaces invisible)

## Current State Analysis

### "+" button behavior
- `ModesListView.addMode()` appends a new mode with hardcoded name `"New Mode"` but doesn't navigate to it
- The `NavigationPath` lives in `MainWindowView` (`@State private var path`) and isn't accessible from `ModesListView`
- Navigation to a mode detail works by pushing a `UUID` onto `path`

### TextField alignment
- All TextFields in `ModeDetailView` use `.textFieldStyle(.roundedBorder)` inside `Form { ... }.formStyle(.grouped)`
- macOS grouped forms right-align text content inside TextFields by default
- This makes trailing spaces invisible and feels unnatural for text input

### Key Discoveries:
- `MainWindowView` line 37: `@State private var path = NavigationPath()`
- `MainWindowView` line 57: `ModesListView(settings: dependencies.settings)` — no path passed
- `ModesTabView.swift` line 51-58: `addMode()` — hardcoded name, no navigation
- `ModesTabView.swift` lines 103, 115, 138: TextFields without `.multilineTextAlignment`

## What We're NOT Doing

- Changing the form layout (labels stay where they are)
- Adding mode name validation/deduplication beyond the "+" button
- Changing any other form styling

## Implementation Approach

Both changes are in `ModesTabView.swift` and `MainWindowView.swift` only. Minimal surface area.

## Phase 1: Auto-navigate to new mode on "+"

### Changes Required:

#### 1. Pass NavigationPath to ModesListView
**File**: `vcdr/UI/MainWindowView.swift`

Pass the `path` binding so `ModesListView` can push navigation programmatically:

```swift
// Line 57: change from
ModesListView(settings: dependencies.settings)
// to
ModesListView(settings: dependencies.settings, path: $path)
```

#### 2. Accept path binding and navigate after add
**File**: `vcdr/UI/ModesTabView.swift`

Add `path` parameter to `ModesListView` and use it in `addMode()`:

```swift
struct ModesListView: View {
    @Bindable var settings: AppSettings
    @Binding var path: NavigationPath
    // ...
}
```

#### 3. Generate unique mode names
**File**: `vcdr/UI/ModesTabView.swift`

Update `addMode()` to:
- Check existing mode names for conflicts
- Use "New Mode", "New Mode (1)", "New Mode (2)", etc.
- Push the new mode's UUID onto `path` after appending

```swift
private static let newModeBaseName = "New Mode"

private func addMode() {
    let name = nextUniqueModeName()
    let newMode = Mode(
        id: UUID(),
        name: name,
        actionType: .paste,
        bashCommand: "echo {}"
    )
    settings.modes.append(newMode)
    path.append(newMode.id)
}

private func nextUniqueModeName() -> String {
    let existingNames = Set(settings.modes.map(\.name))
    if !existingNames.contains(Self.newModeBaseName) {
        return Self.newModeBaseName
    }
    var counter = 1
    while existingNames.contains("\(Self.newModeBaseName) (\(counter))") {
        counter += 1
    }
    return "\(Self.newModeBaseName) (\(counter))"
}
```

## Phase 2: Fix TextField text alignment

### Changes Required:

#### 1. Add `.multilineTextAlignment(.leading)` to all TextFields
**File**: `vcdr/UI/ModesTabView.swift`

Add the modifier to each TextField in `ModeDetailView`:

- Line 103: Name field
- Line 115: Bash command field
- Line 138: Terminator template field

```swift
TextField("Name", text: $mode.name)
    .textFieldStyle(.roundedBorder)
    .multilineTextAlignment(.leading)
```

Same pattern for the other two TextFields.

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Clicking "+" navigates to the new mode's detail form immediately
- [ ] First new mode is named "New Mode"
- [ ] If "New Mode" exists, next one is "New Mode (1)", then "New Mode (2)", etc.
- [ ] Text in all TextFields is left-aligned
- [ ] Typing a space in a TextField is immediately visible
- [ ] Existing navigation (clicking a mode row) still works
- [ ] Switching tabs and back resets navigation correctly
