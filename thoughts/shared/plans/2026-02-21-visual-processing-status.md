# Visual Processing Status in Floating Indicator — Implementation Plan

## Overview

Add visual feedback to the floating indicator panel (`RecordingIndicatorPanel`) so it stays visible through the entire recording pipeline — recording, processing, and result — with distinct animations for each phase.

## Current State Analysis

- `RecordingIndicatorPanel` (in `vcdr/UI/RecordingIndicator.swift`) shows a 48x48 floating pill with a red animated waveform **only during the recording state**
- The panel is created fresh each `show()` call and destroyed on `hide()`
- `RecordingCoordinator` calls `show()` when recording starts and `hide()` immediately when recording stops — **before** transcription begins
- After recording stops, the user has zero visual feedback in the floating indicator about what's happening

### Key Discoveries:
- Panel is owned by `RecordingCoordinator` as `private let recordingIndicator = RecordingIndicatorPanel()` (line 24)
- `hide()` is called unconditionally at the top of `stopRecordingAndTranscribe()` (line 138), before the state guard
- The SwiftUI view (`RecordingIndicatorView`) is private and self-contained with `@State animating`
- All coordinator state mutations happen on the main thread (CGEvent tap callback or `@MainActor` Tasks)

## Desired End State

After implementation, the floating indicator will:

1. **Recording phase**: Show the existing red waveform animation (unchanged)
2. **Processing phase** (transcribing + executing): Show a spinning circular progress indicator with a **red border** around the circle to signal "busy"
3. **Success**: Show a green checkmark for 2 seconds, then auto-dismiss
4. **Error**: Show a red cross for 2 seconds, then auto-dismiss (coordinator's separate 3s error state reset continues independently)
5. **Reject feedback**: If user presses hotkey during processing, the indicator shakes (buzz animation) to signal "can't start now"
6. **Override**: Starting a new dictation while success/error is showing immediately resets the indicator to the recording phase

Transitions between phases will be smoothly animated with an opacity crossfade.

### How to verify:
- Hold hotkey to record → see red waveform (existing)
- Release hotkey → waveform smoothly transitions to spinning indicator with red border
- After successful transcription → spinner transitions to green checkmark (no red border) → panel dismisses after 2 seconds
- If transcription fails → spinner transitions to red cross → panel dismisses after 2 seconds
- Press hotkey during processing → indicator shakes to reject the attempt
- Start new dictation while success/error popup is showing → popup immediately switches to recording waveform

## What We're NOT Doing

- Not changing the menu bar icon behavior (it already reflects state)
- Not adding sound effects or haptic feedback
- Not changing the panel size, position, or material
- Not adding a text label to the indicator (keeping it icon-only)
- Not persisting error details in the indicator (the menu bar status text already shows error messages)

## Implementation Approach

Introduce an `@Observable` phase state object that bridges between `RecordingCoordinator` (imperative updates) and the SwiftUI view (reactive rendering). The panel stays alive through the full flow instead of being destroyed when recording stops.

## Phase 1: Extend RecordingIndicator

### Overview
Add phase tracking and update the SwiftUI view to render different content per phase.

### Changes Required:

#### 1. Add IndicatorPhase enum and observable state
**File**: `vcdr/UI/RecordingIndicator.swift`

Add at the top of the file (before `RecordingIndicatorPanel`):

```swift
enum IndicatorPhase: Equatable {
    case recording
    case processing
    case success
    case error
}

@Observable
@MainActor
final class IndicatorPhaseState {
    var phase: IndicatorPhase = .recording
    var rejectCount: Int = 0  // Increment to trigger shake animation
}
```

#### 2. Update RecordingIndicatorPanel to support phase updates
**File**: `vcdr/UI/RecordingIndicator.swift`

Add a stored `phaseState` property and an `update(phase:)` method. Pass `phaseState` to the SwiftUI view on creation:

```swift
@MainActor
final class RecordingIndicatorPanel {
    private var panel: NSPanel?
    private let phaseState = IndicatorPhaseState()

    func show() {
        phaseState.phase = .recording
        guard panel == nil else { return }

        let hostingView = NSHostingView(rootView: RecordingIndicatorView(phaseState: phaseState))
        hostingView.frame = NSRect(x: 0, y: 0, width: 48, height: 48)

        // ... panel construction unchanged ...

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(phase: IndicatorPhase) {
        phaseState.phase = phase
    }

    /// Trigger a shake animation to reject a hotkey press during processing
    func buzz() {
        phaseState.rejectCount += 1
    }

    var currentPhase: IndicatorPhase {
        phaseState.phase
    }

    func hide() {
        panel?.close()
        panel = nil
    }
}
```

Key detail: `show()` resets `phaseState.phase = .recording` at the top, so even though we reuse the `phaseState` object, each new recording cycle starts fresh.

#### 3. Update RecordingIndicatorView for multi-phase rendering
**File**: `vcdr/UI/RecordingIndicator.swift`

Replace the current single-state view with a phase-driven view that includes:
- Red border overlay during processing phase
- Shake animation triggered by `rejectCount` changes

```swift
private struct RecordingIndicatorView: View {
    // MARK: - Constants

    private static let circleSize: CGFloat = 44
    private static let iconSize: CGFloat = 20
    private static let borderWidth: CGFloat = 2
    private static let shakeAmplitude: CGFloat = 4
    private static let phaseTransitionDuration: Double = 0.2

    let phaseState: IndicatorPhaseState
    @State private var animating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: Self.circleSize, height: Self.circleSize)

            // Red border overlay — visible only during processing
            Circle()
                .stroke(.red.opacity(0.7), lineWidth: Self.borderWidth)
                .frame(width: Self.circleSize, height: Self.circleSize)
                .opacity(phaseState.phase == .processing ? 1 : 0)
                .animation(.easeInOut(duration: Self.phaseTransitionDuration), value: phaseState.phase)

            switch phaseState.phase {
            case .recording:
                Image(systemName: "waveform")
                    .font(.system(size: Self.iconSize, weight: .medium))
                    .foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: animating)
                    .transition(.opacity)

            case .processing:
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
                    .transition(.opacity)

            case .success:
                Image(systemName: "checkmark")
                    .font(.system(size: Self.iconSize, weight: .semibold))
                    .foregroundStyle(.green)
                    .transition(.opacity)

            case .error:
                Image(systemName: "xmark")
                    .font(.system(size: Self.iconSize, weight: .semibold))
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .modifier(ShakeEffect(shakeCount: phaseState.rejectCount))
        .animation(.easeInOut(duration: Self.phaseTransitionDuration), value: phaseState.phase)
        .onAppear { animating = true }
    }
}

/// Horizontal shake effect triggered by incrementing `shakeCount`.
/// Each increment produces a brief left-right oscillation.
private struct ShakeEffect: GeometryEffect {
    // MARK: - Constants

    private static let amplitude: CGFloat = 4
    private static let oscillations: CGFloat = 3

    var shakeCount: Int

    var animatableData: CGFloat {
        get { CGFloat(shakeCount) }
        set { shakeCount = Int(newValue) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = Self.amplitude * sin(animatableData * .pi * Self.oscillations)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}
```

The `ShakeEffect` works by animating from the old `shakeCount` to the new one. During that animation, `sin()` produces a brief horizontal oscillation. Once the animation settles at the new integer value, `sin(n * π * 3) = 0`, so the view returns to its original position.

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] RecordingIndicator.swift stays under 300 lines
- [ ] The view compiles and shows different content when `phaseState.phase` is changed programmatically

---

## Phase 2: Update RecordingCoordinator

### Overview
Keep the indicator visible through the full flow and update its phase at each state transition. Auto-dismiss after success/error with appropriate delays.

### Changes Required:

#### 1. Add success display duration constant
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Add alongside existing `errorDisplayDuration`:

```swift
// MARK: - Constants

private static let errorDisplayDuration: Duration = .seconds(3)
private static let successIndicatorDuration: Duration = .seconds(2)
private static let errorIndicatorDuration: Duration = .seconds(2)
```

#### 2. Update stopRecordingAndTranscribe()
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Instead of hiding the indicator, transition it to `.processing` phase. Keep the unconditional cleanup for the non-recording guard path:

```swift
private func stopRecordingAndTranscribe() {
    Logger.app.debug("[stopRecordingAndTranscribe] enter — state=\(String(describing: self.state))")
    mediaPlaybackController.resumeIfNeeded()
    guard state == .recording else {
        Logger.app.debug("[stopRecordingAndTranscribe] state is not .recording, returning early")
        recordingIndicator.hide()
        return
    }

    guard let audioURL = audioRecorder.stopRecording() else {
        state = .error("No audio recorded")
        recordingIndicator.update(phase: .error)
        dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
        resetAfterDelay()
        return
    }

    state = .transcribing
    recordingIndicator.update(phase: .processing)
    Logger.app.info("Push-to-talk: transcribing...")

    Task { @MainActor in await self.processTranscription(audioURL: audioURL) }
}
```

Key changes:
- Removed `recordingIndicator.hide()` from the top — moved to the guard-else path only
- Added `recordingIndicator.update(phase: .processing)` when transitioning to transcribing
- Added `recordingIndicator.update(phase: .error)` + dismiss for the "no audio" error case

#### 3. Update processTranscription() — success and error paths
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Add indicator phase updates at the success and error exit points:

**Success path** (after `state = .idle`):
```swift
state = .idle
recordingIndicator.update(phase: .success)
dismissIndicatorAfterDelay(Self.successIndicatorDuration)
Logger.app.info("Push-to-talk: complete")
```

**Empty text path** (after `state = .error("No speech detected")`):
```swift
capturedSelection = nil
state = .error("No speech detected")
recordingIndicator.update(phase: .error)
dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
resetAfterDelay()
return
```

**Catch block** (after `state = .error(...)`):
```swift
capturedSelection = nil
state = .error(error.localizedDescription)
recordingIndicator.update(phase: .error)
dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
Logger.app.error("Push-to-talk failed: \(error)")
resetAfterDelay()
```

#### 4. Add dismissIndicatorAfterDelay helper
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Add near the existing `resetAfterDelay()`:

```swift
private func dismissIndicatorAfterDelay(_ duration: Duration) {
    Task {
        try? await Task.sleep(for: duration)
        recordingIndicator.hide()
    }
}
```

#### 5. Add reject feedback in onHotkeyDown
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

When the hotkey is pressed during `transcribing` or `executing` states, buzz the indicator to give visual rejection feedback. Update the `guard state == .idle` block:

```swift
guard state == .idle else {
    Logger.app.warning("Hotkey pressed but not idle (state: \(String(describing: self.state)))")
    // Buzz the indicator to signal "busy, can't start now"
    if state == .transcribing || state == .executing {
        recordingIndicator.buzz()
    }
    return
}
```

The two error paths in `onHotkeyDown()` (model not loaded, failed to start recording) happen **before** the indicator is shown, so they don't need indicator updates. No changes needed there.

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- [ ] RecordingCoordinator.swift stays under 300 lines

#### Manual Verification:
- [ ] Hold hotkey → red waveform appears (no border)
- [ ] Release hotkey → waveform transitions smoothly to spinning indicator with red border
- [ ] After successful transcription → spinner transitions to green checkmark (no red border) → panel dismisses after 2 seconds
- [ ] When transcription fails or produces empty text → spinner transitions to red cross → panel dismisses after 2 seconds
- [ ] Quick tap (very short recording) → indicator still shows full flow (processing → result)
- [ ] Press hotkey during processing → indicator shakes left-right briefly (reject buzz)
- [ ] Starting a new recording while success/error indicator is still showing → indicator resets to recording phase cleanly (dismiss timer is canceled by the phase guard)

---

## Edge Cases

1. **New dictation overrides success/error popup**: If user starts a new recording while the success/error indicator is still showing, `show()` resets `phaseState.phase = .recording` at the top (before the `panel == nil` guard), so the existing panel immediately switches to recording mode. The panel is reused, not recreated.

2. **Hotkey during processing is rejected**: The `guard state == .idle` in `onHotkeyDown()` blocks new recordings. The added `recordingIndicator.buzz()` call gives visual feedback. The state machine prevents any state corruption.

3. **stopRecordingAndTranscribe called when not recording**: The guard-else path calls `recordingIndicator.hide()` to clean up any orphaned panel from a partially started recording.

4. **dismissIndicatorAfterDelay race condition**: If a new recording starts before the dismiss timer fires, `hide()` would close the panel mid-recording. Fix: check phase before hiding:

```swift
private func dismissIndicatorAfterDelay(_ duration: Duration) {
    Task {
        try? await Task.sleep(for: duration)
        // Only dismiss if still showing a terminal phase — a new recording
        // may have started and reset the phase to .recording
        let phase = recordingIndicator.currentPhase
        if phase == .success || phase == .error {
            recordingIndicator.hide()
        }
    }
}
```

5. **ShakeEffect rejectCount accumulation**: `rejectCount` only increases, never resets. This is fine — `ShakeEffect` animates from old value to new value, and the `sin()` function always returns to 0 at integer multiples, so the view settles back to center regardless of the absolute count.

## References

- Current RecordingIndicator: `vcdr/UI/RecordingIndicator.swift`
- Current RecordingCoordinator: `vcdr/Orchestration/RecordingCoordinator.swift`
