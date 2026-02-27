# Output Panel Destination Implementation Plan

## Overview

Add a new built-in output destination type: **Output Panel** — a floating overlay that displays the processed text after transcription. The user can review the text, then press "c" to copy, press another destination's activation key to fire that destination (e.g., "p" for paste), or press Escape to dismiss.

## Current State Analysis

Output destinations are typed via `OutputDestinationType` (`.paste`, `.bashScript`) in `OutputDestination.swift:3`. Each destination has a `name`, `symbol`, `activationKey`, and `type`. The built-in Paste destination has a well-known UUID (`builtInPasteID` at `OutputDestination.swift:34`).

The pipeline flows through `RecordingCoordinator.processTranscription()` (`RecordingCoordinator.swift:216`): transcribe → preprocess → process → `makeOutputAction().execute(text:)`. The same pattern exists in `PushToTypeCoordinator.submitText()` (`PushToTypeCoordinator.swift:94`).

Floating panels use `NSPanel` + `NSHostingView` with a `KeyablePanel` subclass for keyboard input. Established patterns in `ModeSwitcherPanel.swift` and `PushToTypePanel.swift`.

### Key Discoveries:
- `RecordingCoordinator.makeOutputAction()` (`RecordingCoordinator.swift:290`) resolves destination by UUID and switches on type
- `PushToTypeCoordinator.makeOutputAction()` (`PushToTypeCoordinator.swift:150`) is an identical copy
- `OutputDestination.isBuiltIn` (`OutputDestination.swift:28`) currently checks `type == .paste`
- `AppSettings` loads destinations from UserDefaults (`AppSettings.swift:178–184`), defaulting to `[makeDefaultPaste()]`
- `KeyablePanel` (NSPanel subclass, `ModeSwitcherPanel.swift:183`) overrides `canBecomeKey` for keyboard input
- Both coordinators store `previousActiveApp` PID for focus restoration during paste

## Desired End State

After implementation:
- A new built-in "Output Panel" destination appears in the output destinations list alongside "Paste"
- When selected (via mode default or mode switcher override), transcription results appear in a floating overlay below the menu bar
- Keyboard shortcuts: **c** = copy to clipboard (panel stays open), **Esc** = dismiss, **destination activation keys** = fire that destination and close panel
- Paste from the output panel targets the app that was active before recording started
- The output panel replaces the recording indicator's success state — no success checkmark is shown

### Verification:
1. Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
2. Record with Output Panel as destination → overlay shows processed text
3. Press "c" → text copied to clipboard, panel stays open with feedback
4. Press "p" (paste activation key) → text pasted into previously active app, panel closes
5. Press Escape → panel dismissed
6. Output Panel appears in settings as a built-in destination with symbol and activation key

## What We're NOT Doing

- No text editing in the output panel (read-only display)
- No mouse-based text selection (keyboard-driven only)
- No drag-and-drop from the output panel
- No persistence of the output panel state across recordings
- No resizing of the output panel

## Implementation Approach

The Output Panel is a floating `NSPanel` with a `KeyablePanel` subclass, following the established pattern from `ModeSwitcherPanel`. Instead of creating a `PostTranscriptionAction` that suspends (which would block the coordinator in `.executing` state), we handle the `.outputPanel` destination type as a special case in the coordinator pipeline — hide the recording indicator, show the output panel, and transition to `.idle`. The panel manages its own lifecycle and can independently create and execute `PasteAction`/`OutputBashAction` when the user fires a destination.

---

## Phase 1: Data Model Changes

### Overview
Add the `.outputPanel` case to `OutputDestinationType`, create the built-in factory, and handle migration for existing users.

### Changes Required:

#### 1. OutputDestinationType
**File**: `vcdr/Core/Settings/OutputDestination.swift`

Add `.outputPanel` case and update `displayName`:

```swift
enum OutputDestinationType: String, Codable, CaseIterable {
    case paste
    case bashScript
    case outputPanel

    /// Types available for user-created destinations (excludes special built-in types)
    static var userCreatable: [OutputDestinationType] {
        [.bashScript]
    }

    var displayName: String {
        switch self {
        case .paste: "Paste (Cmd+V)"
        case .bashScript: "Bash Script"
        case .outputPanel: "Output Panel"
        }
    }
}
```

#### 2. OutputDestination built-in factory
**File**: `vcdr/Core/Settings/OutputDestination.swift`

Add a well-known UUID and factory method:

```swift
static let builtInOutputPanelID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

static func makeDefaultOutputPanel() -> OutputDestination {
    OutputDestination(
        id: builtInOutputPanelID,
        name: "Output Panel",
        type: .outputPanel,
        bashCommand: "",
        symbol: "👁",
        activationKey: "o"
    )
}
```

#### 3. Update `isBuiltIn`
**File**: `vcdr/Core/Settings/OutputDestination.swift`

```swift
var isBuiltIn: Bool { type == .paste || type == .outputPanel }
```

#### 4. AppSettings migration
**File**: `vcdr/Core/Settings/AppSettings.swift`

After loading destinations from UserDefaults, ensure the output panel destination exists (for existing users upgrading):

```swift
// In init(), after loading outputDestinations:
// Ensure built-in Output Panel destination exists (migration for existing installs)
if !outputDestinations.contains(where: { $0.id == OutputDestination.builtInOutputPanelID }) {
    outputDestinations.append(OutputDestination.makeDefaultOutputPanel())
}
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Output Panel appears in the output destinations list in settings
- [ ] Output Panel is marked as "Built-in" and cannot be deleted
- [ ] Output Panel can be selected as default destination for a mode

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation.

---

## Phase 2: Output Panel UI

### Overview
Create the floating panel that displays processed text with keyboard shortcuts for copy, redirect, and dismiss.

### Changes Required:

#### 1. OutputPanelPanel
**File**: `vcdr/UI/OutputPanelPanel.swift` (new file)

A `KeyablePanel`-based overlay following the patterns in `ModeSwitcherPanel.swift`:

```swift
import AppKit
import SwiftUI
import OSLog

@MainActor
final class OutputPanelPanel {
    private var panel: NSPanel?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    // MARK: - Constants

    private static let panelWidth: CGFloat = 400
    private static let panelMinHeight: CGFloat = 80
    private static let panelMaxHeight: CGFloat = 300
    private static let panelOffsetBelowMenuBar: CGFloat = 8
    private static let copiedFeedbackDuration: Duration = .seconds(1)

    func show(
        text: String,
        outputDestinations: [OutputDestination],
        targetAppPID: pid_t?,
        onDismiss: (() -> Void)? = nil
    ) {
        hide()

        let viewModel = OutputPanelViewModel(
            text: text,
            outputDestinations: outputDestinations.filter { $0.type != .outputPanel },
            onCopy: { [weak self] in
                self?.copyToClipboard(text)
            },
            onFireDestination: { [weak self] destination in
                self?.fireDestination(destination, text: text, targetAppPID: targetAppPID)
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let view = OutputPanelView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        let panelHeight = // calculate based on text length, clamped
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: panelHeight)

        let panel = KeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        // Standard panel configuration (isOpaque, backgroundColor, level, etc.)
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        // Install event monitors (local for keys, global for click-outside dismiss)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel] event in
            guard let viewModel else { return event }
            return viewModel.handleKeyEvent(event) ? nil : event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        // Remove event monitors, close panel
        // Call onDismiss if panel was visible
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Logger.actions.info("Output panel: text copied to clipboard")
    }

    private func fireDestination(_ destination: OutputDestination, text: String, targetAppPID: pid_t?) {
        hide()
        Task {
            do {
                let action: any PostTranscriptionAction = switch destination.type {
                case .paste:
                    PasteAction(targetAppPID: targetAppPID)
                case .bashScript:
                    OutputBashAction(name: destination.name, commandTemplate: destination.bashCommand)
                case .outputPanel:
                    return  // Should not happen — filtered out
                }
                try await action.execute(text: text)
                Logger.actions.info("Output panel: fired destination '\(destination.name)'")
            } catch {
                Logger.actions.error("Output panel: destination failed: \(error)")
            }
        }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
```

#### 2. OutputPanelViewModel
**File**: `vcdr/UI/OutputPanelPanel.swift` (same file, following ModeSwitcherPanel pattern)

```swift
@Observable
private final class OutputPanelViewModel {
    let text: String
    let outputDestinations: [OutputDestination]
    let onCopy: () -> Void
    let onFireDestination: (OutputDestination) -> Void
    let onDismiss: () -> Void

    /// Brief "Copied!" feedback
    var showCopiedFeedback = false

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers ?? ""

        switch event.keyCode {
        case 53: // Escape
            onDismiss()
            return true
        default:
            if chars == "c" {
                onCopy()
                showCopiedFeedback = true
                // Auto-hide feedback after delay
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    showCopiedFeedback = false
                }
                return true
            }
            // Check destination activation keys
            if let char = chars.first {
                let key = String(char)
                if let destination = outputDestinations.first(where: { $0.activationKey == key }) {
                    onFireDestination(destination)
                    return true
                }
            }
            return false
        }
    }
}
```

#### 3. OutputPanelView
**File**: `vcdr/UI/OutputPanelPanel.swift` (same file)

```swift
private struct OutputPanelView: View {
    let viewModel: OutputPanelViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable text content
            ScrollView {
                Text(viewModel.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            Divider()

            // Hint bar showing available shortcuts
            HStack(spacing: 12) {
                hintLabel("c", "copy")
                ForEach(viewModel.outputDestinations.filter { !$0.activationKey.isEmpty }) { dest in
                    hintLabel(dest.activationKey, dest.name.lowercased())
                }
                Spacer()
                hintLabel("esc", "dismiss")

                if viewModel.showCopiedFeedback {
                    Text("Copied!")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func hintLabel(_ key: String, _ label: String) -> some View {
        HStack(spacing: 2) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Output Panel overlay appears below menu bar, centered
- [ ] Text is displayed in monospaced font, scrollable for long text
- [ ] Hint bar shows available shortcuts
- [ ] "c" copies text and shows "Copied!" feedback, panel stays open
- [ ] Destination activation keys fire the corresponding action and close the panel
- [ ] Escape closes the panel
- [ ] Clicking outside closes the panel

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation.

---

## Phase 3: Coordinator Integration

### Overview
Wire `OutputPanelPanel` through dependency injection and handle the `.outputPanel` destination type in both coordinators' pipelines.

### Changes Required:

#### 1. RecordingCoordinator
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Add `outputPanel` as a dependency:

```swift
private let outputPanel: OutputPanelPanel

init(
    // ... existing params ...
    outputPanel: OutputPanelPanel
) {
    // ... existing assignments ...
    self.outputPanel = outputPanel
}
```

Refactor `processTranscription()` to extract destination resolution and handle `.outputPanel`:

```swift
// In processTranscription(), replace lines 257-259 (Step 3):

// Step 3: Output
let destinationID = outputDestinationOverride ?? mode.defaultOutputDestinationID
outputDestinationOverride = nil
let destination = settings.outputDestination(for: destinationID)

if destination.type == .outputPanel {
    // Output panel handles its own lifecycle — no success indicator needed
    recordingIndicator.hide()
    outputPanel.show(
        text: processedText,
        outputDestinations: settings.outputDestinations,
        targetAppPID: previousActiveApp?.processIdentifier
    )
} else {
    let action = makeOutputAction(for: destination)
    try await action.execute(text: processedText)
    recordingIndicator.update(phase: .success)
    dismissIndicatorAfterDelay(Self.successIndicatorDuration)
}
```

Update `makeOutputAction()` to accept a destination parameter (lines 290–308):

```swift
private func makeOutputAction(for destination: OutputDestination) -> any PostTranscriptionAction {
    let targetPID = previousActiveApp?.processIdentifier

    switch destination.type {
    case .paste:
        return PasteAction(targetAppPID: targetPID)
    case .bashScript:
        return OutputBashAction(
            name: destination.name,
            commandTemplate: destination.bashCommand
        )
    case .outputPanel:
        // Handled separately in processTranscription — should not reach here
        Logger.app.warning("makeOutputAction called for outputPanel type — falling back to paste")
        return PasteAction(targetAppPID: targetPID)
    }
}
```

Move destination resolution out of `makeOutputAction` and into the calling code. Also update `cancelRecording()` (line 378) and the empty-text guard (line 227) which clear `outputDestinationOverride` — no changes needed there.

#### 2. PushToTypeCoordinator
**File**: `vcdr/Orchestration/PushToTypeCoordinator.swift`

Same pattern — add `outputPanel` dependency and handle `.outputPanel` in `submitText()`:

```swift
private let outputPanel: OutputPanelPanel

init(
    // ... existing params ...
    outputPanel: OutputPanelPanel
) {
    // ...
    self.outputPanel = outputPanel
}
```

In `submitText()`, replace the output step (lines 121–123):

```swift
// Step 3: Output
let destinationID = outputDestinationOverride ?? mode.defaultOutputDestinationID
outputDestinationOverride = nil
let destination = settings.outputDestination(for: destinationID)

if destination.type == .outputPanel {
    recordingIndicator.hide()
    outputPanel.show(
        text: processedText,
        outputDestinations: settings.outputDestinations,
        targetAppPID: previousActiveApp?.processIdentifier
    )
} else {
    let action = makeOutputAction(for: destination)
    try await action.execute(text: processedText)
    recordingIndicator.update(phase: .success)
    dismissIndicatorAfterDelay(Self.successIndicatorDuration)
}
```

Update `makeOutputAction()` to take a destination parameter (same as RecordingCoordinator).

#### 3. AppDependencies
**File**: `vcdr/App/AppDependencies.swift`

Create and inject `OutputPanelPanel`:

```swift
let outputPanel = OutputPanelPanel()

self.coordinator = RecordingCoordinator(
    // ... existing params ...
    outputPanel: outputPanel
)

self.pushToTypeCoordinator = PushToTypeCoordinator(
    // ... existing params ...
    outputPanel: outputPanel
)
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Push-to-talk with Output Panel destination shows the output panel
- [ ] Push-to-type with Output Panel destination shows the output panel
- [ ] Mode switcher can override destination to Output Panel during recording
- [ ] Pressing "p" in the output panel pastes to the previously active app
- [ ] Pressing a bash script's activation key fires the script and closes the panel
- [ ] Recording indicator is hidden when output panel is shown (no double-overlay)
- [ ] Text in the output panel matches expected pipeline output (preprocessing + processing applied)
- [ ] After dismissing the output panel, new recordings work normally

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation.

---

## Testing Strategy

### Manual Testing Steps:
1. **Basic flow**: Set Output Panel as default destination for a mode → record → verify text appears in overlay
2. **Copy**: Press "c" → verify clipboard contents match → verify panel stays open → verify "Copied!" feedback
3. **Paste redirect**: Press "p" → verify text is pasted into the previously active app → verify panel closes
4. **Bash redirect**: Create a bash destination with activation key "b" → press "b" from output panel → verify script runs → verify panel closes
5. **Dismiss**: Press Escape → verify panel closes
6. **Click outside**: Click anywhere outside the panel → verify it dismisses
7. **Mode switcher override**: During recording, use mode switcher to override to Output Panel → verify output panel appears
8. **Push-to-type**: Use push-to-type with Output Panel destination → verify output panel appears
9. **Long text**: Record a long transcription → verify scrolling works in the output panel
10. **Settings**: Verify Output Panel appears as built-in, can't be deleted, symbol/activation key editable

## Performance Considerations

- The output panel is created on-demand (like ModeSwitcherPanel) — no persistent overhead
- Text rendering uses standard SwiftUI `Text` — should handle typical transcription lengths without issue
- For very long transcriptions, the `ScrollView` with max height cap (300pt) prevents the panel from growing unbounded

## References

- Existing panel pattern: `vcdr/UI/ModeSwitcherPanel.swift`
- Destination model: `vcdr/Core/Settings/OutputDestination.swift`
- Coordinator pipeline: `vcdr/Orchestration/RecordingCoordinator.swift:216`
- PushToType pipeline: `vcdr/Orchestration/PushToTypeCoordinator.swift:94`
- DI container: `vcdr/App/AppDependencies.swift`
