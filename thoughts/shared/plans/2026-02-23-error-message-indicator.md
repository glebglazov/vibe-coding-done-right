# Error Message Below Indicator — Implementation Plan

## Overview

Show a descriptive error message as a pill below the floating indicator when any error occurs during the recording/transcription/action pipeline. Currently the indicator shows a red X but no text — the user has to check the menu bar or Console.app to understand what went wrong.

## Current State Analysis

The floating indicator (`RecordingIndicatorPanel`) is a 48x48 borderless NSPanel positioned below the menu bar center. It shows icons for four phases: recording (waveform), processing (spinner), success (checkmark), error (xmark). The error phase shows a red X for 2 seconds, then the panel hides.

There are 5 error paths in `RecordingCoordinator`:

| # | Error | Location | Indicator shown? |
|---|-------|----------|-----------------|
| 1 | "Model still loading..." | `onHotkeyDown` line 100 | No |
| 2 | "Failed to start recording" | `onHotkeyDown` line 137 | No |
| 3 | "No audio recorded" | `stopRecordingAndTranscribe` line 161 | Yes |
| 4 | "No speech detected" | `processTranscription` line 188 | Yes |
| 5 | `error.localizedDescription` | `processTranscription` catch, line 248 | Yes |

Errors 1-2 never show the indicator. Errors 3-5 show the indicator with a red X but no text.

### Key Discoveries:
- `IndicatorPhaseState` at `RecordingIndicator.swift:13-18` has only `phase` and `rejectCount` — no message field
- `update(phase:)` at line 63 takes only the phase enum, no message parameter
- Panel is created at 48x48 in `show()` at line 32 and positioned at `screenFrame.midX - 24` (line 54)
- Panel uses `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = true` — shadow follows content shapes on non-opaque windows
- `show()` resets phase to `.recording` at line 28 even if panel already exists (for re-entry during error display)

## Desired End State

When any of the 5 error paths fire, the floating indicator shows:
1. The red X icon in the circle (existing behavior)
2. A material-backed pill below the circle with the error message text

The pill uses `.ultraThinMaterial` background (matching the circle style), with small caption text. The panel resizes dynamically to accommodate the pill and re-centers horizontally. After 2 seconds (existing `errorIndicatorDuration`), the panel hides as before.

### Verification:
- Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- All 5 error paths show the indicator with both the red X and error text pill
- Pre-recording errors (model loading, mic failure) now show the indicator
- Panel resizes correctly and stays centered under the menu bar
- When a new recording starts while error is showing, the panel shrinks back to 48x48 and shows the waveform

## What We're NOT Doing

- Not adding error history or persistent error display
- Not changing error messages themselves
- Not adding error details or "retry" buttons
- Not modifying the success/processing/recording indicator appearance

## Implementation Approach

Expand the indicator's data model to carry an optional error message. When in error phase with a message, the SwiftUI view renders a pill below the circle. The NSPanel resizes dynamically to fit the pill, keeping the circle anchored at the same screen position.

## Phase 1: Update RecordingIndicatorPanel and View

### Overview
Add error message support to the indicator state, panel resizing, and SwiftUI view.

### Changes Required:

#### 1. IndicatorPhaseState — add error message
**File**: `vcdr/UI/RecordingIndicator.swift`
**Lines**: 13-18

Add `errorMessage` property to `IndicatorPhaseState`:

```swift
@Observable
@MainActor
final class IndicatorPhaseState {
    var phase: IndicatorPhase = .recording
    var rejectCount: Int = 0
    var errorMessage: String?
}
```

#### 2. RecordingIndicatorPanel — add message parameter and panel resizing
**File**: `vcdr/UI/RecordingIndicator.swift`
**Lines**: 22-80

Add constants for error panel dimensions:

```swift
// MARK: - Constants

private static let normalPanelSize: CGFloat = 48
private static let errorPanelWidth: CGFloat = 220
private static let errorPanelHeight: CGFloat = 76
/// Gap between bottom of menu bar and top of indicator panel
private static let menuBarGap: CGFloat = 8
```

Note: `menuBarGap` replaces the current magic number in the positioning formula. Currently `56 = 48 (panel height) + 8 (gap)`. With the named constant: `normalPanelSize + menuBarGap`.

Update `show()` to clear error message and resize back to normal when panel is reused:

```swift
func show() {
    phaseState.phase = .recording
    phaseState.errorMessage = nil
    guard panel == nil else {
        resizePanel(forError: false)
        return
    }
    // ... rest unchanged
}
```

Also update the positioning line in `show()` to use the new constants:
```swift
let x = screenFrame.midX - Self.normalPanelSize / 2
let y = screenFrame.maxY - menuBarHeight - Self.normalPanelSize - Self.menuBarGap
```

Change `update(phase:)` to accept an optional message:

```swift
func update(phase: IndicatorPhase, message: String? = nil) {
    phaseState.errorMessage = (phase == .error) ? message : nil
    phaseState.phase = phase
    if phase == .error && message != nil {
        resizePanel(forError: true)
    } else {
        resizePanel(forError: false)
    }
}
```

Add the `resizePanel` helper:

```swift
/// Resize and reposition the panel, keeping the top-center anchored
private func resizePanel(forError: Bool) {
    guard let panel else { return }
    let currentTopCenter = NSPoint(x: panel.frame.midX, y: panel.frame.maxY)
    let newWidth = forError ? Self.errorPanelWidth : Self.normalPanelSize
    let newHeight = forError ? Self.errorPanelHeight : Self.normalPanelSize
    let newFrame = NSRect(
        x: currentTopCenter.x - newWidth / 2,
        y: currentTopCenter.y - newHeight,
        width: newWidth,
        height: newHeight
    )
    panel.setFrame(newFrame, display: true)
}
```

#### 3. RecordingIndicatorView — add error pill
**File**: `vcdr/UI/RecordingIndicator.swift`
**Lines**: 84-133

Add constants for the error pill:

```swift
private static let errorPillSpacing: CGFloat = 4
private static let errorPillHPadding: CGFloat = 8
private static let errorPillVPadding: CGFloat = 3
private static let errorPillCornerRadius: CGFloat = 6
private static let errorPillFontSize: CGFloat = 11
```

Wrap the existing `ZStack` in a `VStack` and add the conditional error pill:

```swift
var body: some View {
    VStack(spacing: Self.errorPillSpacing) {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: Self.circleSize, height: Self.circleSize)

            switch phaseState.phase {
            case .recording:
                // ... existing code unchanged
            case .processing:
                // ... existing code unchanged
            case .success:
                // ... existing code unchanged
            case .error:
                // ... existing code unchanged
            }
        }

        if let message = phaseState.errorMessage, phaseState.phase == .error {
            Text(message)
                .font(.system(size: Self.errorPillFontSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Self.errorPillHPadding)
                .padding(.vertical, Self.errorPillVPadding)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.errorPillCornerRadius))
                .transition(.opacity)
        }
    }
    .modifier(ShakeEffect(shakeCount: phaseState.rejectCount))
    .animation(.easeInOut(duration: Self.phaseTransitionDuration), value: phaseState.phase)
    .animation(.default, value: phaseState.rejectCount)
    .onAppear { animating = true }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Error indicator shows pill with message below the red X circle
- [ ] Pill uses material background matching the circle
- [ ] Long error messages truncate with ellipsis
- [ ] Panel resizes correctly — circle stays at the same screen position
- [ ] Non-error phases (recording, processing, success) show normally at 48x48 with no pill

**Implementation Note**: After completing this phase, pause for manual testing before proceeding.

---

## Phase 2: Wire All Error Paths in RecordingCoordinator

### Overview
Pass error messages through `update(phase:message:)` and show the indicator for pre-recording errors.

### Changes Required:

#### 1. Pre-recording errors — add indicator show + message
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

**Error 1: Model still loading (line 100)**

Change from:
```swift
state = .error("Model still loading...")
resetAfterDelay()
```

To:
```swift
state = .error("Model still loading...")
recordingIndicator.show()
recordingIndicator.update(phase: .error, message: "Model still loading...")
dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
resetAfterDelay()
```

Note: `show()` sets phase to `.recording`, then `update()` immediately overrides to `.error`. Both calls are synchronous on the main thread, so no intermediate frame renders the recording icon.

**Error 2: Failed to start recording (line 137)**

Change from:
```swift
state = .error("Failed to start recording")
Logger.app.error("Push-to-talk: failed to start recording")
resetAfterDelay()
```

To:
```swift
state = .error("Failed to start recording")
recordingIndicator.show()
recordingIndicator.update(phase: .error, message: "Failed to start recording")
dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
Logger.app.error("Push-to-talk: failed to start recording")
resetAfterDelay()
```

#### 2. Existing error paths — add message parameter
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

**Error 3: No audio recorded (line 162)**

Change:
```swift
recordingIndicator.update(phase: .error)
```
To:
```swift
recordingIndicator.update(phase: .error, message: "No audio recorded")
```

**Error 4: No speech detected (line 189)**

Change:
```swift
recordingIndicator.update(phase: .error)
```
To:
```swift
recordingIndicator.update(phase: .error, message: "No speech detected")
```

**Error 5: Catch block (line 249)**

Change:
```swift
recordingIndicator.update(phase: .error)
```
To:
```swift
recordingIndicator.update(phase: .error, message: error.localizedDescription)
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] "No speech detected" — hold hotkey briefly without speaking, see error pill with message
- [ ] Transcription/action failure — trigger a bash action that fails, see error pill with error description
- [ ] "Model still loading..." — press hotkey before model finishes loading (requires fresh launch), see error pill
- [ ] Starting a new recording while error is displayed — error pill disappears, indicator shrinks back to circle, shows waveform
- [ ] Error indicator auto-hides after 2 seconds, state resets after 3 seconds (existing behavior preserved)

## Testing Strategy

### Manual Testing Steps:
1. **No speech**: Hold hotkey for 1 second in silence, release → should show red X + "No speech detected" pill
2. **Bash failure**: Create a mode with `exit 1` as the bash command, dictate something → should show red X + exit code message
3. **Model loading**: Launch app fresh, immediately press hotkey before "Ready" appears → should show red X + "Model still loading..." pill
4. **Quick re-record**: Trigger an error, then immediately press hotkey again → error pill should disappear, waveform should appear, indicator should be 48x48 again
5. **Long error message**: Create a bash mode with a command that produces a long error → pill should truncate with ellipsis

## References

- Indicator panel: `vcdr/UI/RecordingIndicator.swift`
- Error paths: `vcdr/Orchestration/RecordingCoordinator.swift:100, 137, 161, 188, 248`
