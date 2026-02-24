# Push-to-Type Implementation Plan

## Overview

Add a "Push-to-Type" feature — a text input alternative to Push-to-Talk. When the user presses a dedicated hotkey, a floating overlay with a text field appears. The user types their query, presses Return to submit, and the text flows through the same Mode transform → Action pipeline as voice transcription. The existing mode switcher hotkey works while the overlay is open, allowing mode switching mid-query. Selected text from the frontmost app is captured before the overlay appears, and the processing/success/error indicator shows after submission.

## Current State Analysis

The app has a well-established pattern for:
- **Global hotkeys** via `GlobalHotkeyManager` (CGEvent tap per instance) — `RecordingCoordinator` and `ModeSwitcherCoordinator` each own one
- **Floating panels** via `NSPanel` subclass `KeyablePanel` (`.nonActivatingPanel`, `.borderless`, `canBecomeKey = true`) — proven in `ModeSwitcherPanel`
- **Text transformation** via `Mode.transformTranscription(_:capturedSelection:)` — works on any string, not coupled to transcription
- **Post-transcription actions** via `PostTranscriptionAction` protocol (`PasteAction`, `BashAction`) — take a string and execute
- **Visual feedback** via `RecordingIndicatorPanel` — show/update(phase:)/hide lifecycle
- **Selection capture** via `SelectionCapturer` — reads highlighted text via Accessibility API
- **DI wiring** via `AppDependencies` — all services created and injected in init()

### Key Discoveries:
- `Mode.transformTranscription` at `Mode.swift:23` is a pure function on the Mode struct — any coordinator can call it
- `RecordingCoordinator.makeAction()` at `RecordingCoordinator.swift:266` is a 13-line private method reading `settings.activeMode` and `previousActiveApp` — will be replicated in the new coordinator
- `RecordingIndicatorPanel.show()` at `RecordingIndicator.swift:40` always sets phase to `.recording`, but calling `update(phase: .processing)` immediately after on the same MainActor turn means SwiftUI only renders the `.processing` state
- `ModeSwitcherPanel` at `ModeSwitcherPanel.swift:4` provides the exact pattern for an interactive floating panel with keyboard handling
- `TranscriptionRecord` at `TranscriptionRecord.swift:3` has `modelName` and `recordingDuration` fields — PTT entries will use `"Push-to-Type"` and `0` respectively

## Desired End State

A new global hotkey triggers a floating text field overlay. The user types, optionally switches modes via the existing mode switcher hotkey, and presses Return to submit. The text is transformed by the active mode and executed by the active action (paste or bash). The indicator shows processing/success/error feedback. The feature is fully wired into settings with a configurable hotkey.

### Verification:
- Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- Pressing the Push-to-Type hotkey shows a floating text field overlay
- Typing and pressing Return submits the text through the mode pipeline
- The mode switcher hotkey works while the overlay is open
- Escape and clicking outside dismiss the overlay without action
- Selected text from the frontmost app is captured and appended by the mode
- The indicator shows processing → success/error after submission
- The entry appears in transcription history

## What We're NOT Doing

- No changes to the Push-to-Talk (voice) flow
- No changes to the Mode struct or transform pipeline
- No changes to PostTranscriptionAction implementations
- No inline mode picker in the overlay (using existing mode switcher hotkey instead)
- No multi-line auto-resize of the panel (fixed size)
- No rich text or markdown support in the text field

## Implementation Approach

Follow the established patterns exactly: new coordinator owns a `GlobalHotkeyManager`, new panel follows `ModeSwitcherPanel`'s `KeyablePanel` pattern, share the `RecordingIndicatorPanel` instance between both coordinators for visual feedback. Five files touched total (2 new, 3 modified).

---

## Phase 1: Add Push-to-Type Hotkey Setting

### Overview
Add `pushToTypeHotkey: HotkeyBinding` to AppSettings with UserDefaults persistence and Codable migration.

### Changes Required:

#### 1. AppSettings
**File**: `vcdr/Core/Settings/AppSettings.swift`

Add the new property after `modeSwitcherHotkey` (line 44):

```swift
var pushToTypeHotkey: HotkeyBinding {
    didSet { save() }
}
```

Add the UserDefaults key in `Keys` enum (after line 66):

```swift
static let pushToTypeHotkey = "pushToTypeHotkey"
```

Add loading in `init()` (after the mode switcher hotkey loading block, after line 104):

```swift
// Load push-to-type hotkey (default: unassigned)
if let data = userDefaults.data(forKey: Keys.pushToTypeHotkey),
   let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
    self.pushToTypeHotkey = decoded
} else {
    self.pushToTypeHotkey = .unassigned
}
```

Add persistence in `save()` (after line 152):

```swift
if let encoded = try? JSONEncoder().encode(pushToTypeHotkey) {
    userDefaults.set(encoded, forKey: Keys.pushToTypeHotkey)
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

---

## Phase 2: Push-to-Type Panel (UI)

### Overview
Create the floating overlay panel with a text field, mode name display, and keyboard handling (Return to submit, Shift+Return for newline, Escape to dismiss).

### Changes Required:

#### 1. PushToTypePanel
**File**: `vcdr/UI/PushToTypePanel.swift` (new file)

The panel follows `ModeSwitcherPanel`'s architecture: a manager class owns an `NSPanel`, a `@Observable` view model bridges NSEvent handling and SwiftUI, and a private SwiftUI view renders the UI.

```swift
import AppKit
import SwiftUI
import OSLog

final class PushToTypePanel {
    private var panel: NSPanel?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    // MARK: - Constants

    private static let panelWidth: CGFloat = 320
    private static let panelHeight: CGFloat = 100
    private static let panelOffsetBelowMenuBar: CGFloat = 8

    func show(modeName: String, onSubmit: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        hide()

        let viewModel = PushToTypeViewModel(
            modeName: modeName,
            onSubmit: { [weak self] text in
                onSubmit(text)
                self?.hide()
            },
            onDismiss: { [weak self] in
                onDismiss()
                self?.hide()
            }
        )

        let view = PushToTypeView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)

        let panel = KeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = hostingView
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        // Position at top center, just below the menu bar
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let screenFrame = screen.frame
            let visibleFrame = screen.visibleFrame
            let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
            let x = screenFrame.midX - Self.panelWidth / 2
            let y = screenFrame.maxY - menuBarHeight - Self.panelHeight - Self.panelOffsetBelowMenuBar
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        // Intercept Return (submit) and Escape (dismiss) before they reach the text field
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel] event in
            guard let viewModel else { return event }
            if viewModel.handleKeyEvent(event) {
                return nil
            }
            return event
        }

        // Dismiss if the user clicks outside the panel
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        panel?.close()
        panel = nil
    }

    var isVisible: Bool { panel != nil }
}

// MARK: - NSPanel subclass that accepts key events

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - View Model

@Observable
private final class PushToTypeViewModel {
    var text: String = ""
    var modeName: String
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    init(modeName: String, onSubmit: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.modeName = modeName
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
    }

    /// Returns true if the event was handled (consumed)
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36: // Return
            // Shift+Return inserts newline (pass through to text field)
            if event.modifierFlags.contains(.shift) {
                return false
            }
            // Plain Return submits
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true } // ignore empty submit
            onSubmit(trimmed)
            return true
        case 53: // Escape
            onDismiss()
            return true
        default:
            return false
        }
    }
}

// MARK: - SwiftUI View

private struct PushToTypeView: View {
    @Bindable var viewModel: PushToTypeViewModel
    @FocusState private var isTextFieldFocused: Bool

    // MARK: - Constants

    private static let cornerRadius: CGFloat = 10
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 10
    private static let modeNameFontSize: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(viewModel.modeName)
                    .font(.system(size: Self.modeNameFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("↵ submit")
                    .font(.system(size: Self.modeNameFontSize))
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $viewModel.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($isTextFieldFocused)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .onAppear {
            isTextFieldFocused = true
        }
    }
}
```

**Key design decisions:**
- `KeyablePanel` is duplicated (3 lines) rather than extracted to a shared file — avoids coupling for trivial code
- `TextEditor` instead of `TextField` to support Shift+Return newlines naturally
- `@FocusState` + `.focused()` + `.onAppear { isTextFieldFocused = true }` to auto-focus the text field when the panel appears
- The local event monitor intercepts Return (without Shift) before it reaches the TextEditor
- Mode name is displayed read-only at the top — the user switches modes via the existing mode switcher hotkey
- The `modeName` property on the view model allows the coordinator to update it when the mode changes

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

---

## Phase 3: Push-to-Type Coordinator

### Overview
Create the orchestrator that manages the hotkey, overlay lifecycle, selection capture, text submission pipeline, and indicator feedback.

### Changes Required:

#### 1. PushToTypeCoordinator
**File**: `vcdr/Orchestration/PushToTypeCoordinator.swift` (new file)

```swift
import Foundation
import AppKit
import OSLog

@Observable
@MainActor
final class PushToTypeCoordinator {
    private let settings: AppSettings
    private let hotkeyManager = GlobalHotkeyManager()
    private let panel = PushToTypePanel()
    private let recordingIndicator: RecordingIndicatorPanel
    private let selectionCapturer: SelectionCapturer
    private let transcriptionHistory: TranscriptionHistory

    private var previousActiveApp: NSRunningApplication?
    private var capturedSelection: String?

    // MARK: - Constants

    private static let successIndicatorDuration: Duration = .seconds(2)
    private static let errorIndicatorDuration: Duration = .seconds(10)

    init(
        settings: AppSettings,
        recordingIndicator: RecordingIndicatorPanel,
        selectionCapturer: SelectionCapturer,
        transcriptionHistory: TranscriptionHistory
    ) {
        self.settings = settings
        self.recordingIndicator = recordingIndicator
        self.selectionCapturer = selectionCapturer
        self.transcriptionHistory = transcriptionHistory
    }

    func setupHotkey() {
        let binding = settings.pushToTypeHotkey
        guard binding.isAssigned else {
            hotkeyManager.unregister()
            Logger.hotkeys.info("Push-to-type hotkey unassigned, unregistered")
            return
        }

        hotkeyManager.onKeyDown = { [weak self] in
            Task { @MainActor in
                self?.toggleOverlay()
            }
        }
        hotkeyManager.onKeyUp = nil

        let keyCode = CGKeyCode(binding.keyCode)
        let modifiers = CGEventFlags(rawValue: binding.modifiers)
        _ = hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
    }

    func updateHotkey() {
        setupHotkey()
    }

    // MARK: - Overlay Lifecycle

    private func toggleOverlay() {
        if panel.isVisible {
            panel.hide()
            Logger.app.info("Push-to-type: overlay dismissed via hotkey")
        } else {
            showOverlay()
        }
    }

    private func showOverlay() {
        // Capture context from the frontmost app before showing the overlay
        previousActiveApp = NSWorkspace.shared.frontmostApplication
        capturedSelection = selectionCapturer.capture()

        panel.show(
            modeName: settings.activeMode.name,
            onSubmit: { [weak self] text in
                self?.submitText(text)
            },
            onDismiss: { [weak self] in
                self?.capturedSelection = nil
                self?.previousActiveApp = nil
                Logger.app.info("Push-to-type: overlay dismissed")
            }
        )
        Logger.app.info("Push-to-type: overlay shown")
    }

    // MARK: - Text Submission Pipeline

    private func submitText(_ text: String) {
        let mode = settings.activeMode
        let transformedText = mode.transformTranscription(text, capturedSelection: capturedSelection)
        capturedSelection = nil

        // Show processing indicator
        recordingIndicator.show()
        recordingIndicator.update(phase: .processing)
        Logger.app.info("Push-to-type: executing action")

        Task { @MainActor in
            do {
                let action = makeAction()
                let actionResult = try await action.execute(text: transformedText)

                // Record in history
                let trimmedResult = actionResult?.trimmingCharacters(in: .whitespacesAndNewlines)
                let record = TranscriptionRecord(
                    text: text,
                    modelName: "Push-to-Type",
                    recordingDuration: 0,
                    actionResult: trimmedResult?.isEmpty == false ? trimmedResult : nil
                )
                transcriptionHistory.addRecord(record)

                recordingIndicator.update(phase: .success)
                dismissIndicatorAfterDelay(Self.successIndicatorDuration)
                Logger.app.info("Push-to-type: complete")
            } catch {
                recordingIndicator.update(phase: .error, message: error.localizedDescription)
                dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
                Logger.app.error("Push-to-type failed: \(error)")
            }

            previousActiveApp = nil
        }
    }

    private func makeAction() -> any PostTranscriptionAction {
        let mode = settings.activeMode
        let targetPID = previousActiveApp?.processIdentifier
        switch mode.actionType {
        case .paste:
            return PasteAction(targetAppPID: targetPID)
        case .bash:
            return BashAction(
                commandTemplate: mode.bashCommand,
                pasteOutput: mode.pasteScriptOutput,
                targetAppPID: targetPID
            )
        }
    }

    private func dismissIndicatorAfterDelay(_ duration: Duration) {
        Task {
            try? await Task.sleep(for: duration)
            let phase = recordingIndicator.currentPhase
            if phase == .success || phase == .error {
                recordingIndicator.hide()
            }
        }
    }
}
```

**Key design decisions:**
- Follows `ModeSwitcherCoordinator`'s pattern exactly: owns its own `GlobalHotkeyManager`, toggle behavior on hotkey press
- Shares `RecordingIndicatorPanel` with `RecordingCoordinator` for consistent visual feedback — no simultaneous conflicts because you can't submit text and record at the same instant
- `makeAction()` is duplicated from `RecordingCoordinator` (13 lines) — extraction would create coupling for minimal code savings
- `dismissIndicatorAfterDelay()` is duplicated from `RecordingCoordinator` (8 lines) — same reasoning
- Selection is captured once when the overlay opens (not on submit), matching PTT behavior
- `previousActiveApp` is captured when overlay opens — the `.nonActivatingPanel` keeps the target app frontmost, so `PasteAction.activate()` restores focus correctly after panel dismissal
- History entries use `modelName: "Push-to-Type"` and `recordingDuration: 0` to distinguish from voice entries

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

---

## Phase 4: AppDependencies Wiring

### Overview
Share `RecordingIndicatorPanel` between both coordinators, create `PushToTypeCoordinator`, and wire hotkey setup into the initialization lifecycle.

### Changes Required:

#### 1. AppDependencies
**File**: `vcdr/App/AppDependencies.swift`

Add stored property (after `modeSwitcherCoordinator` on line 13):

```swift
let pushToTypeCoordinator: PushToTypeCoordinator
```

In `init()`, pass `recordingIndicator` and `selectionCapturer` to the new coordinator (after line 53):

```swift
self.pushToTypeCoordinator = PushToTypeCoordinator(
    settings: settings,
    recordingIndicator: recordingIndicator,
    selectionCapturer: selectionCapturer,
    transcriptionHistory: history
)
```

Note: `recordingIndicator` and `selectionCapturer` are already created as local variables at lines 39-40. They are currently passed only to `RecordingCoordinator`. Now they are also passed to `PushToTypeCoordinator`. No changes needed to `RecordingCoordinator`'s init call.

In `initialize()`, add `pushToTypeCoordinator.setupHotkey()` alongside the other two (after line 84):

```swift
pushToTypeCoordinator.setupHotkey()
```

In the permission polling callback, add the same call (after line 115):

```swift
self.pushToTypeCoordinator.setupHotkey()
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

---

## Phase 5: Settings UI

### Overview
Add a ShortcutRecorderRow for the Push-to-Type hotkey in the Home tab's Shortcuts section.

### Changes Required:

#### 1. HomeTabView
**File**: `vcdr/UI/HomeTabView.swift`

Add a new `ShortcutRecorderRow` in the "Shortcuts" section (after the Mode Switcher row, after line 111):

```swift
ShortcutRecorderRow(
    label: "Push-to-Type",
    keyCode: Binding(
        get: { dependencies.settings.pushToTypeHotkey.keyCode },
        set: {
            dependencies.settings.pushToTypeHotkey.keyCode = $0
            dependencies.pushToTypeCoordinator.updateHotkey()
        }
    ),
    modifiers: Binding(
        get: { dependencies.settings.pushToTypeHotkey.modifiers },
        set: {
            dependencies.settings.pushToTypeHotkey.modifiers = $0
            dependencies.pushToTypeCoordinator.updateHotkey()
        }
    )
)
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Push-to-Type hotkey appears in Settings > Home > Shortcuts
- [ ] Assigning a hotkey and pressing it shows the floating text field overlay
- [ ] The mode name displayed in the overlay matches the active mode
- [ ] Typing text and pressing Return submits — the text gets pasted into the target app (for paste mode) or processed by bash command (for bash mode)
- [ ] Shift+Return inserts a newline in the text field
- [ ] Escape dismisses the overlay without executing any action
- [ ] Clicking outside the overlay dismisses it
- [ ] Pressing the Push-to-Type hotkey while the overlay is open dismisses it (toggle behavior)
- [ ] The mode switcher hotkey works while the overlay is open — after selecting a mode, the overlay remains usable (test by checking the mode name doesn't update live, but the submitted text uses the newly selected mode)
- [ ] Selected text in the frontmost app is captured and appended by the mode's transform pipeline
- [ ] The indicator shows processing → success after submission
- [ ] The indicator shows processing → error when an action fails
- [ ] The entry appears in the History tab with "Push-to-Type" as the model name
- [ ] No interference with Push-to-Talk — both hotkeys work independently

**Implementation Note**: After completing all phases and automated verification passes, pause for manual confirmation that all manual tests pass.

---

## Testing Strategy

### Manual Testing Steps:
1. **Basic paste flow**: Set mode to Default (paste), assign PTT hotkey, press it, type "hello world", press Return → verify "hello world" is pasted into the previously active text editor
2. **Bash flow**: Set mode to a bash mode with `echo {}`, enable paste output, type "test query", submit → verify "test query" is pasted
3. **Mode switching**: Open PTT overlay, press mode switcher hotkey, select a different mode, type and submit → verify the new mode's transform and action are used
4. **Selection capture**: Select text in a text editor, press PTT hotkey, type a query, submit with a bash mode that uses `{}` → verify the selected text is included
5. **Terminator**: Enable terminator on active mode, type via PTT, submit → verify terminator is applied to the typed text
6. **System prompt**: Enable system prompt on a bash mode, type via PTT, submit → verify system prompt is prepended
7. **Dismiss paths**: Test Escape, click-outside, and hotkey-toggle all dismiss without action
8. **Empty submit**: Press Return with empty text field → verify nothing happens
9. **Concurrent PTT**: While PTT overlay is open, start a voice recording via Push-to-Talk → verify both work without crashes

## Performance Considerations

- The `PushToTypePanel` creates and destroys the `NSPanel` on each show/hide cycle (same as `ModeSwitcherPanel` and `RecordingIndicatorPanel`) — no persistent resource usage when the overlay is not visible
- No model loading, audio processing, or network calls — Push-to-Type is effectively instant
- The `RecordingIndicatorPanel` is shared by reference, not duplicated — no extra memory for the indicator

## References

- ModeSwitcherPanel pattern: `vcdr/UI/ModeSwitcherPanel.swift`
- ModeSwitcherCoordinator pattern: `vcdr/Orchestration/ModeSwitcherCoordinator.swift`
- RecordingCoordinator (action pipeline): `vcdr/Orchestration/RecordingCoordinator.swift:266-279`
- RecordingIndicatorPanel: `vcdr/UI/RecordingIndicator.swift`
- AppSettings: `vcdr/Core/Settings/AppSettings.swift`
- AppDependencies: `vcdr/App/AppDependencies.swift`
