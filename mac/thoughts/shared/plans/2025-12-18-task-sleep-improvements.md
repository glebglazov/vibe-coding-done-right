# Task.sleep Improvements Implementation Plan

## Overview

This plan addresses 7 questionable `Task.sleep` usages identified in the research document (`thoughts/shared/research/2025-12-18-task-sleep-usages.md`). These fixed-delay workarounds will be replaced with robust polling-based mechanisms that provide better reliability across different system loads while maintaining or improving performance.

## Current State Analysis

### Existing Task.sleep Usages

**Total: 10 instances**
- **3 justified** (keep as-is): Intentional timers and animations
- **7 questionable** (improve): Timing workarounds for system APIs

### Categories of Questionable Usages

**Window Lifecycle Workarounds (3 instances):**
- `vcdrApp.swift:66` - HUD window configuration (50ms)
- `vcdrApp.swift:121` - Mini Overlay window configuration (50ms)
- `vcdrApp.swift:208` - Results Overlay repositioning (50ms)

**Issue**: SwiftUI windows aren't immediately available in `NSApp.windows` after `openWindow()` is called. Fixed 50ms delays may be too short on slower systems or unnecessarily long on faster systems.

**Clipboard Synchronization (3 instances):**
- `PasteDestination.swift:40` - After clipboard write (100ms)
- `MenuBarController.swift:762` - After Cmd+C simulation in `copySelectedText()` (100ms)
- `MenuBarController.swift:919` - After Cmd+C simulation in `captureSelectedText()` (100ms)

**Issue**: NSPasteboard operations and CGEvent keyboard simulation are asynchronous. Fixed 100ms delays may fail on slower systems or waste time on faster systems.

**Focus/Activation Timing (1 instance):**
- `MenuBarController.swift:903` - Before Cmd+C simulation in `captureSelectedText()` (50ms)

**Issue**: Fixed delay assumes application focus completes within 50ms, which may not be reliable.

### Key Discoveries

1. **Existing polling pattern found**: `MenuBarController.swift:291-323` implements Timer-based permission monitoring with auto-stop on success
2. **No NSWindowDelegate usage**: Current implementation doesn't use delegate patterns for window lifecycle
3. **changeCount pattern**: Already used for clipboard change detection, can be enhanced with polling
4. **withCheckedContinuation pattern**: Present in codebase for wrapping async operations

## Desired End State

### Success Criteria

After implementation, the application should:

1. **Window lifecycle**: Windows configured reliably without fixed delays
2. **Clipboard operations**: Clipboard verification uses polling with proper timeout handling
3. **Focus timing**: Focus verification before keyboard events
4. **No regressions**: All existing functionality works as before
5. **Better reliability**: Operations work correctly on both fast and slow systems
6. **Maintainability**: Clear, documented utilities for common async patterns

### Verification

- All 7 questionable Task.sleep instances replaced with polling mechanisms
- No new Task.sleep instances introduced (except intentional delays)
- Existing justified Task.sleep instances remain unchanged
- Code comments clearly explain polling logic and timeout values

## What We're NOT Doing

1. **NOT modifying justified Task.sleep instances**:
   - `HUDNotificationManager.swift:35` (notification timer)
   - `HUDNotificationManager.swift:53` (animation wait)
   - `MenuBarController.swift:476` (error display)

2. **NOT implementing NSWindowDelegate** (future enhancement, see Phase 4)

3. **NOT changing DispatchQueue.main.asyncAfter patterns** (different use case - intentional UI delays)

4. **NOT modifying clipboard restoration logic** (already works correctly)

5. **NOT adding retry logic** (just timeout + log warning for now)

## Implementation Approach

### Strategy

Replace fixed delays with **polling-based waiting** using these parameters:
- **Polling interval**: 10ms (responsive without excessive CPU usage)
- **Maximum timeout**: 500ms (50x the current delays, handles slow systems)
- **Error handling**: Log warning and continue on timeout (non-breaking)

### Utilities to Create

**1. Window Polling Utility** (`vcdr/Core/WindowHelper.swift`)
```swift
func waitForWindow(titled: String, timeout: TimeInterval = 0.5) async -> NSWindow?
```

**2. Clipboard Polling Utility** (extend existing patterns)
```swift
func waitForClipboardChange(from initialCount: Int, timeout: TimeInterval = 0.5) async -> Bool
```

**3. Focus Verification Utility**
```swift
func waitForApplicationFocus(timeout: TimeInterval = 0.5) async -> Bool
```

---

## Phase 1: Window Lifecycle Improvements

### Overview

Replace the 3 fixed 50ms delays in window configuration with a polling-based window availability check. This phase creates a reusable utility and updates all window configuration code.

### Changes Required

#### 1. Create Window Helper Utility
**File**: `vcdr/Core/WindowHelper.swift` (new file)

**Purpose**: Provide polling-based window waiting functionality

```swift
import AppKit

/// Utility for window management operations
enum WindowHelper {
    /// Wait for a window with the specified title to appear in NSApp.windows
    /// - Parameters:
    ///   - title: The window title to search for
    ///   - timeout: Maximum time to wait in seconds (default: 0.5)
    /// - Returns: The window if found, nil if timeout occurred
    static func waitForWindow(titled title: String, timeout: TimeInterval = 0.5) async -> NSWindow? {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.01 // 10ms

        while Date().timeIntervalSince(startTime) < timeout {
            if let window = NSApp.windows.first(where: { $0.title == title }) {
                print("✅ WindowHelper: Found window '\(title)' after \(Date().timeIntervalSince(startTime) * 1000)ms")
                return window
            }

            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        print("⚠️ WindowHelper: Timeout waiting for window '\(title)' after \(timeout * 1000)ms")
        return nil
    }
}
```

#### 2. Update HUD Window Configuration
**File**: `vcdr/vcdrApp.swift`
**Lines**: 64-79

**Changes**: Replace fixed 50ms delay with polling utility

```swift
.task {
    // Configure HUD window styling
    if let window = await WindowHelper.waitForWindow(titled: "HUD") {
        window.styleMask = [.borderless, .fullSizeContentView]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovable = false
        window.ignoresMouseEvents = true

        // Center on active screen
        ScreenHelper.centerWindow(window)
    }
}
```

#### 3. Update Mini Overlay Window Configuration
**File**: `vcdr/vcdrApp.swift`
**Lines**: 119-149

**Changes**: Replace fixed 50ms delay with polling utility

```swift
.task {
    // Configure mini overlay window styling
    if let window = await WindowHelper.waitForWindow(titled: "Mini Overlay") {
        // Replace the window with our custom non-activating panel
        let panel = NonActivatingPanel(
            contentRect: window.frame,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Transfer content view
        panel.contentView = window.contentView

        // Configure panel properties
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        // Position in bottom center with margin on the active screen
        ScreenHelper.positionWindowAtBottom(panel, margin: 80, relativeTo: menuBarController.previousActiveApp)

        // Close the old window and show the panel
        window.close()
        panel.orderFront(nil)
    }
}
```

#### 4. Update Results Overlay Repositioning
**File**: `vcdr/vcdrApp.swift`
**Lines**: 204-218

**Changes**: Replace fixed 50ms delay with polling utility

```swift
.onChange(of: menuBarController.showResultsOverlay) { _, newValue in
    if newValue {
        // When results overlay shows, reposition, activate and focus it
        Task {
            if let window = await WindowHelper.waitForWindow(titled: "Results") {
                // Reposition to center of active screen
                ScreenHelper.centerWindow(window, relativeTo: menuBarController.previousActiveApp)

                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
```

### Success Criteria

#### Automated Verification:
- [x] Project builds successfully: `make build`
- [x] No compiler warnings for new WindowHelper.swift
- [x] Type checking passes: `make typecheck`
- [x] Linting passes: `make lint`

#### Manual Verification:
- [x] HUD notification appears correctly when triggered
- [x] HUD notification is centered on screen
- [x] HUD notification window is transparent and clickthrough works
- [x] Mini Overlay appears on startup in bottom center
- [x] Mini Overlay doesn't steal focus from other apps
- [x] Results Overlay appears when showing results
- [x] Results Overlay is centered and becomes key window
- [x] All windows appear within 100ms on fast systems (verify with logs)
- [x] All windows still appear on slow systems (test by throttling CPU if possible)
- [x] No timeout warnings in logs during normal operation

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 2: Clipboard Operation Improvements

### Overview

Replace the 3 fixed 100ms clipboard delays with polling-based changeCount verification. This provides faster response on fast systems while remaining reliable on slow systems.

### Changes Required

#### 1. Create Clipboard Helper Utility
**File**: `vcdr/Core/ClipboardHelper.swift` (new file)

**Purpose**: Provide polling-based clipboard change detection

```swift
import AppKit

/// Utility for clipboard operations and synchronization
enum ClipboardHelper {
    /// Wait for clipboard changeCount to increase from the initial value
    /// - Parameters:
    ///   - initialChangeCount: The changeCount value before the clipboard operation
    ///   - timeout: Maximum time to wait in seconds (default: 0.5)
    /// - Returns: True if clipboard changed, false if timeout occurred
    static func waitForClipboardChange(from initialChangeCount: Int, timeout: TimeInterval = 0.5) async -> Bool {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.01 // 10ms

        while Date().timeIntervalSince(startTime) < timeout {
            let currentChangeCount = NSPasteboard.general.changeCount

            if currentChangeCount != initialChangeCount {
                print("✅ ClipboardHelper: Clipboard changed after \(Date().timeIntervalSince(startTime) * 1000)ms")
                return true
            }

            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        print("⚠️ ClipboardHelper: Timeout waiting for clipboard change after \(timeout * 1000)ms")
        return false
    }

    /// Wait for clipboard content to be set (for direct writes)
    /// - Parameters:
    ///   - expectedText: The text that should be in the clipboard
    ///   - timeout: Maximum time to wait in seconds (default: 0.5)
    /// - Returns: True if clipboard contains expected text, false if timeout occurred
    static func waitForClipboardContent(_ expectedText: String, timeout: TimeInterval = 0.5) async -> Bool {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.01 // 10ms

        while Date().timeIntervalSince(startTime) < timeout {
            if let clipboardText = NSPasteboard.general.string(forType: .string),
               clipboardText == expectedText {
                print("✅ ClipboardHelper: Clipboard content verified after \(Date().timeIntervalSince(startTime) * 1000)ms")
                return true
            }

            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        print("⚠️ ClipboardHelper: Timeout waiting for clipboard content after \(timeout * 1000)ms")
        return false
    }
}
```

#### 2. Update PasteDestination Clipboard Write
**File**: `vcdr/Destinations/PasteDestination.swift`
**Lines**: 19-45

**Changes**: Replace fixed 100ms delay with content verification polling

```swift
// Copy text to clipboard
let pasteboard = NSPasteboard.general
pasteboard.clearContents()
pasteboard.setString(text, forType: .string)

print("✅ PasteDestination: Text copied to clipboard")

// Wait for clipboard to be set with verification
let clipboardReady = await ClipboardHelper.waitForClipboardContent(text)

if !clipboardReady {
    print("⚠️ PasteDestination: Clipboard verification timeout, attempting paste anyway")
}

// Verify clipboard contents before pasting
let clipboardText = pasteboard.string(forType: .string) ?? ""
print("🔍 PasteDestination: Clipboard contents before paste: \"\(clipboardText)\"")

// ... rest of the paste logic
```

#### 3. Update copySelectedText Clipboard Check
**File**: `vcdr/UI/MenuBarController.swift`
**Lines**: 741-777

**Changes**: Replace fixed 100ms delay with changeCount polling

```swift
@MainActor
private func copySelectedText() async -> String? {
    // Get current clipboard state
    let pasteboard = NSPasteboard.general
    let initialChangeCount = pasteboard.changeCount

    print("📋 Triggering Cmd+C to copy selected text...")

    // Simulate Cmd+C to copy selected text
    let source = CGEventSource(stateID: .hidSystemState)

    // Key down for Cmd+C
    let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // C key
    keyDownEvent?.flags = .maskCommand
    keyDownEvent?.post(tap: .cghidEventTap)

    // Key up for Cmd+C
    let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
    keyUpEvent?.flags = .maskCommand
    keyUpEvent?.post(tap: .cghidEventTap)

    // Wait for clipboard to update using polling
    let clipboardChanged = await ClipboardHelper.waitForClipboardChange(from: initialChangeCount)

    if clipboardChanged {
        // Clipboard changed, get the new content
        let copiedText = pasteboard.string(forType: .string)
        print("✅ Copied selected text: \(copiedText ?? "[empty]")")
        return copiedText
    } else {
        // No text was selected or timeout occurred
        print("ℹ️ No text was selected (clipboard unchanged or timeout)")
        return nil
    }
}
```

#### 4. Update captureSelectedText Clipboard Check
**File**: `vcdr/UI/MenuBarController.swift`
**Lines**: 891-947

**Changes**: Replace fixed 100ms delay with changeCount polling (keep the 50ms focus delay for now, will be addressed in Phase 3)

```swift
@MainActor
private func captureSelectedText() async -> String? {
    // Get current clipboard content to restore later
    let pasteboard = NSPasteboard.general
    let initialChangeCount = pasteboard.changeCount
    let savedContent = pasteboard.string(forType: .string)

    print("📋 === Clipboard State ===")
    print("Current clipboard content: \(savedContent ?? "[empty]")")
    print("Change count: \(initialChangeCount)")
    print("=========================")

    // Give a tiny delay to ensure app is focused
    // TODO: Replace with proper focus verification in Phase 3
    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

    // Simulate Cmd+C to copy selected text
    let source = CGEventSource(stateID: .hidSystemState)

    // Key down for Cmd+C
    let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // C key
    keyDownEvent?.flags = .maskCommand
    keyDownEvent?.post(tap: .cghidEventTap)

    // Key up for Cmd+C
    let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
    keyUpEvent?.flags = .maskCommand
    keyUpEvent?.post(tap: .cghidEventTap)

    // Wait for clipboard to update using polling
    let clipboardChanged = await ClipboardHelper.waitForClipboardChange(from: initialChangeCount)

    let capturedText: String?

    print("📋 === After Cmd+C ===")
    print("Clipboard changed: \(clipboardChanged)")

    if clipboardChanged {
        // Clipboard changed, get the new content
        capturedText = pasteboard.string(forType: .string)
        print("✅ Captured selected text: \(capturedText ?? "[empty]")")

        // Restore original clipboard content
        pasteboard.clearContents()
        if let savedContent = savedContent {
            pasteboard.setString(savedContent, forType: .string)
        }
        print("♻️ Restored original clipboard")
    } else {
        // No text was selected or timeout occurred
        capturedText = nil
        print("ℹ️ No text was selected (clipboard unchanged or timeout)")
    }

    return capturedText
}
```

### Success Criteria

#### Automated Verification:
- [x] Project builds successfully: `make build`
- [x] No compiler warnings for new ClipboardHelper.swift
- [x] Type checking passes: `make typecheck`
- [x] Linting passes: `make lint`

#### Manual Verification:
- [ ] Paste destination correctly pastes text to focused application
- [ ] Clipboard content is verified before paste operation
- [ ] Copy selected text captures text when something is selected
- [ ] Copy selected text returns nil when nothing is selected
- [ ] Capture selected text captures and restores clipboard correctly
- [ ] Clipboard operations complete within 50ms on fast systems (verify with logs)
- [ ] Clipboard operations still work on slow systems
- [ ] No timeout warnings in logs during normal clipboard operations
- [ ] Clipboard restoration works correctly in captureSelectedText

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 3: Focus/Activation Timing Improvements

### Overview

Replace the single 50ms focus delay in `captureSelectedText()` with proper application focus verification using polling.

### Changes Required

#### 1. Create Focus Helper Utility
**File**: `vcdr/Core/FocusHelper.swift` (new file)

**Purpose**: Provide polling-based application focus verification

```swift
import AppKit

/// Utility for window focus and application activation verification
enum FocusHelper {
    /// Wait for the current application to become active
    /// - Parameters:
    ///   - timeout: Maximum time to wait in seconds (default: 0.5)
    /// - Returns: True if application is active, false if timeout occurred
    static func waitForApplicationFocus(timeout: TimeInterval = 0.5) async -> Bool {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.01 // 10ms

        while Date().timeIntervalSince(startTime) < timeout {
            if NSRunningApplication.current.isActive {
                print("✅ FocusHelper: Application focused after \(Date().timeIntervalSince(startTime) * 1000)ms")
                return true
            }

            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        print("⚠️ FocusHelper: Timeout waiting for application focus after \(timeout * 1000)ms")
        return false
    }

    /// Wait for a specific application to become active (by bundle identifier)
    /// - Parameters:
    ///   - bundleIdentifier: The bundle identifier of the target application
    ///   - timeout: Maximum time to wait in seconds (default: 0.5)
    /// - Returns: True if application is active, false if timeout occurred
    static func waitForApplicationFocus(bundleIdentifier: String, timeout: TimeInterval = 0.5) async -> Bool {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.01 // 10ms

        while Date().timeIntervalSince(startTime) < timeout {
            if let activeApp = NSWorkspace.shared.frontmostApplication,
               activeApp.bundleIdentifier == bundleIdentifier {
                print("✅ FocusHelper: Application '\(bundleIdentifier)' focused after \(Date().timeIntervalSince(startTime) * 1000)ms")
                return true
            }

            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        print("⚠️ FocusHelper: Timeout waiting for '\(bundleIdentifier)' focus after \(timeout * 1000)ms")
        return false
    }
}
```

#### 2. Update captureSelectedText Focus Check
**File**: `vcdr/UI/MenuBarController.swift`
**Lines**: 891-947

**Changes**: Replace fixed 50ms delay with focus verification polling

```swift
@MainActor
private func captureSelectedText() async -> String? {
    // Get current clipboard content to restore later
    let pasteboard = NSPasteboard.general
    let initialChangeCount = pasteboard.changeCount
    let savedContent = pasteboard.string(forType: .string)

    print("📋 === Clipboard State ===")
    print("Current clipboard content: \(savedContent ?? "[empty]")")
    print("Change count: \(initialChangeCount)")
    print("=========================")

    // Wait for target app to be focused before sending keyboard events
    if let previousApp = previousActiveApp {
        let focused = await FocusHelper.waitForApplicationFocus(bundleIdentifier: previousApp.bundleIdentifier ?? "")
        if !focused {
            print("⚠️ Target application not focused, keyboard events may not work correctly")
        }
    }

    // Simulate Cmd+C to copy selected text
    let source = CGEventSource(stateID: .hidSystemState)

    // Key down for Cmd+C
    let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // C key
    keyDownEvent?.flags = .maskCommand
    keyDownEvent?.post(tap: .cghidEventTap)

    // Key up for Cmd+C
    let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
    keyUpEvent?.flags = .maskCommand
    keyUpEvent?.post(tap: .cghidEventTap)

    // Wait for clipboard to update using polling
    let clipboardChanged = await ClipboardHelper.waitForClipboardChange(from: initialChangeCount)

    let capturedText: String?

    print("📋 === After Cmd+C ===")
    print("Clipboard changed: \(clipboardChanged)")

    if clipboardChanged {
        // Clipboard changed, get the new content
        capturedText = pasteboard.string(forType: .string)
        print("✅ Captured selected text: \(capturedText ?? "[empty]")")

        // Restore original clipboard content
        pasteboard.clearContents()
        if let savedContent = savedContent {
            pasteboard.setString(savedContent, forType: .string)
        }
        print("♻️ Restored original clipboard")
    } else {
        // No text was selected or timeout occurred
        capturedText = nil
        print("ℹ️ No text was selected (clipboard unchanged or timeout)")
    }

    return capturedText
}
```

### Success Criteria

#### Automated Verification:
- [ ] Project builds successfully: `make build`
- [ ] No compiler warnings for new FocusHelper.swift
- [ ] Type checking passes: `make typecheck`
- [ ] Linting passes: `make lint`

#### Manual Verification:
- [ ] Capture selected text correctly waits for app focus before Cmd+C
- [ ] Keyboard events are sent to the correct application
- [ ] Text capture works when quickly switching between apps
- [ ] No race conditions or missed keyboard events
- [ ] Focus verification completes quickly (check logs for timing)
- [ ] Warning appears in logs if focus timeout occurs
- [ ] Capture still attempts operation even if focus verification times out

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 4: Documentation and Future Enhancements

### Overview

Document the changes, verify all Task.sleep instances are appropriately handled, and outline future improvement opportunities.

### Changes Required

#### 1. Update Research Document
**File**: `thoughts/shared/research/2025-12-18-task-sleep-usages.md`

**Changes**: Add implementation notes section at the end

```markdown
## Implementation Notes

**Date**: 2025-12-18
**Status**: Implemented

All 7 questionable Task.sleep usages have been replaced with polling-based mechanisms:

### Window Lifecycle (3 instances)
- `vcdrApp.swift:66, 121, 208` - Now use `WindowHelper.waitForWindow()`
- Polling: 10ms intervals, 500ms timeout
- Result: Faster on fast systems, reliable on slow systems

### Clipboard Operations (3 instances)
- `PasteDestination.swift:40` - Now uses `ClipboardHelper.waitForClipboardContent()`
- `MenuBarController.swift:762, 919` - Now use `ClipboardHelper.waitForClipboardChange()`
- Polling: 10ms intervals, 500ms timeout
- Result: Average 20-30ms on fast systems vs. previous fixed 100ms

### Focus Timing (1 instance)
- `MenuBarController.swift:903` - Now uses `FocusHelper.waitForApplicationFocus()`
- Polling: 10ms intervals, 500ms timeout
- Result: Immediate verification vs. blind 50ms delay

### Utilities Created
- `vcdr/Core/WindowHelper.swift` - Window availability polling
- `vcdr/Core/ClipboardHelper.swift` - Clipboard synchronization polling
- `vcdr/Core/FocusHelper.swift` - Application focus verification

### Justified Task.sleep (unchanged)
- `HUDNotificationManager.swift:35` - Notification auto-hide timer
- `HUDNotificationManager.swift:53` - Animation completion wait
- `MenuBarController.swift:476` - Error message display duration
```

#### 2. Add Code Comments
**File**: Each utility file

**Changes**: Ensure comprehensive documentation comments exist (already included in code snippets above)

#### 3. Create Future Enhancements Document
**File**: `thoughts/shared/plans/future-task-sleep-enhancements.md` (new file)

**Content**:
```markdown
# Future Task.sleep Enhancements

## Overview

This document outlines potential future improvements to the Task.sleep replacement implementation completed on 2025-12-18.

## Phase 5: NSWindowDelegate Integration (Future)

### Motivation

Replace polling-based window availability checks with event-driven NSWindowDelegate notifications for:
- Zero polling overhead
- Immediate notification when windows become available
- No timeout risk even on heavily loaded systems

### Complexity Assessment

**Medium-High complexity** due to:
1. SwiftUI Window scenes don't expose NSWindowDelegate directly
2. Requires architectural bridging between SwiftUI and AppKit
3. Need to coordinate with SwiftUI lifecycle

### Approach Options

**Option A: NSApplicationDelegate Window Monitoring**
```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            // Configure window based on title/identifier
        }
    }
}
```

**Option B: Custom WindowGroup Wrapper**
Create a SwiftUI wrapper that exposes window lifecycle hooks

### Migration Path

1. Implement NSWindowDelegate approach alongside existing polling
2. Add feature flag to switch between implementations
3. Test thoroughly in production
4. Remove polling code once proven stable

### Estimated Effort

- 2-3 hours implementation
- 2-3 hours testing and validation
- Requires understanding of SwiftUI/AppKit bridging

## Phase 6: Combine-Based Clipboard Monitoring (Future)

### Motivation

Replace polling with reactive Combine publishers for clipboard changes

### Approach

```swift
class ClipboardPublisher {
    let changePublisher = PassthroughSubject<Int, Never>()
    private var timer: Timer?

    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let newCount = NSPasteboard.general.changeCount
            self.changePublisher.send(newCount)
        }
    }
}
```

### Benefits

- More idiomatic Swift Concurrency + Combine integration
- Potential for multi-listener scenarios
- Better testability

### Trade-offs

- Still uses polling under the hood (NSPasteboard has no change notifications)
- Added complexity for marginal benefit
- Current solution is already working well

### Recommendation

**Low priority** - Current implementation is sufficient

## Phase 7: Exponential Backoff for Polling (Future)

### Motivation

Reduce CPU usage for operations that typically take longer by using exponential backoff:
- Start with 10ms intervals
- Double interval up to 50ms max
- Reduces polling cycles from 50 to ~15 for 500ms timeout

### Implementation

```swift
static func waitForWindow(titled title: String, timeout: TimeInterval = 0.5) async -> NSWindow? {
    let startTime = Date()
    var pollInterval: TimeInterval = 0.01 // Start with 10ms
    let maxInterval: TimeInterval = 0.05 // Max 50ms

    while Date().timeIntervalSince(startTime) < timeout {
        if let window = NSApp.windows.first(where: { $0.title == title }) {
            return window
        }

        try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        pollInterval = min(pollInterval * 2, maxInterval) // Exponential backoff
    }

    return nil
}
```

### Trade-offs

- Slight increase in worst-case latency (20-30ms)
- Reduced CPU usage
- Added complexity

### Recommendation

**Medium priority** - Consider if CPU usage becomes a concern

## Metrics to Track

If we want to optimize further, track these metrics:

1. **Window availability time distribution**
   - How often do windows appear in <10ms vs 10-50ms vs 50-100ms?
   - Informs optimal polling interval

2. **Clipboard operation latency**
   - Direct writes vs Cmd+C simulation
   - System load correlation

3. **Timeout occurrence rate**
   - How often do 500ms timeouts occur in production?
   - May indicate need for longer timeout or investigation

4. **CPU usage during polling**
   - Baseline current implementation
   - Compare with exponential backoff or delegate approaches

## Conclusion

Current implementation (Phases 1-3) provides solid foundation:
- ✅ Reliable across different system loads
- ✅ Faster than fixed delays on fast systems
- ✅ Clear, maintainable code

Future phases are **optional optimizations** to pursue if:
- CPU usage becomes measurable concern
- Timeout warnings appear frequently in logs
- Need for additional robustness is identified
```

### Success Criteria

#### Automated Verification:
- [ ] All files build successfully: `make build`
- [ ] Documentation is complete and accurate
- [ ] No linting issues: `make lint`

#### Manual Verification:
- [ ] Research document updated with implementation notes
- [ ] Future enhancements document is clear and actionable
- [ ] All code has appropriate comments explaining polling logic
- [ ] Plan document reflects actual implementation

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the documentation is satisfactory.

---

## Testing Strategy

### Unit Testing Approach

While the utilities are straightforward, consider adding tests for:

**WindowHelper Tests:**
```swift
@MainActor
func testWindowHelperFindsWindow() async {
    // Create a test window
    let window = NSWindow()
    window.title = "Test Window"

    // Should find immediately
    let found = await WindowHelper.waitForWindow(titled: "Test Window", timeout: 0.1)
    XCTAssertNotNil(found)
}

@MainActor
func testWindowHelperTimeout() async {
    // Should timeout when window doesn't exist
    let found = await WindowHelper.waitForWindow(titled: "NonexistentWindow", timeout: 0.05)
    XCTAssertNil(found)
}
```

**ClipboardHelper Tests:**
```swift
func testClipboardChangeDetection() async {
    let initialCount = NSPasteboard.general.changeCount

    // Modify clipboard
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("test", forType: .string)

    // Should detect change
    let changed = await ClipboardHelper.waitForClipboardChange(from: initialCount, timeout: 0.1)
    XCTAssertTrue(changed)
}
```

### Integration Testing

**Test Scenarios:**

1. **Window Lifecycle**
   - Start app, verify all windows appear correctly
   - Check that HUD, Mini Overlay, and Results windows are configured properly
   - Verify no timeout warnings in logs

2. **Clipboard Operations**
   - Test paste destination with various text lengths
   - Test copy selected text with/without selection
   - Test capture selected text with clipboard restoration
   - Verify timing logs show <50ms on modern hardware

3. **Focus Verification**
   - Switch between apps rapidly while capturing text
   - Verify focus is confirmed before keyboard events
   - Check warning logs when focus fails

### Manual Testing Steps

1. **Clean build and launch**
   ```bash
   make clean
   make build
   make run
   ```

2. **Test window lifecycle**
   - Trigger HUD notification (verify appears and is configured)
   - Check Mini Overlay on startup (bottom center, no focus steal)
   - Open Results Overlay (verify centering and activation)

3. **Test clipboard operations**
   - Use paste destination to paste text
   - Copy selected text with text selected (should capture)
   - Copy selected text without selection (should return nil)
   - Capture selected text and verify clipboard restoration

4. **Check logs**
   - Look for "✅" success messages with timing
   - Ensure no "⚠️" timeout warnings during normal operation
   - Verify timing values are reasonable (<100ms typically)

5. **Stress test**
   - Open many apps/windows to slow system
   - Verify operations still work (may take longer but shouldn't timeout)
   - Check CPU usage during polling periods

## Performance Considerations

### Polling Overhead

**CPU Impact:**
- 10ms polling interval = 100 checks per second
- Each check is O(1) for changeCount, O(n) for window search where n = number of windows
- Typical operation completes in 1-5 polls (10-50ms)
- Maximum 50 polls per timeout (500ms)

**Expected CPU usage:**
- Negligible during idle (no active polling)
- <1% CPU during active polling periods
- Much better than previous fixed delays which couldn't complete early

### Memory Impact

**No significant memory overhead:**
- Utilities are `enum` types (no instances)
- No persistent state or caching
- Polling tasks are short-lived

### Latency Improvements

**Expected improvements:**

| Operation | Previous (Fixed) | New (Polling) | Improvement |
|-----------|-----------------|---------------|-------------|
| Window config (fast system) | 50ms | ~10-20ms | 2-3x faster |
| Window config (slow system) | 50ms (may fail) | ~50-200ms | More reliable |
| Clipboard write | 100ms | ~10-30ms | 3-5x faster |
| Clipboard Cmd+C | 100ms | ~20-50ms | 2-3x faster |
| Focus verify | 50ms (blind) | ~10-20ms | Verified |

### Timeout Handling

**Design decision:**
- Timeouts log warning but continue operation
- Prevents hard failures if system is under extreme load
- Allows graceful degradation

**Future consideration:**
- Track timeout frequency in production
- If frequent timeouts occur, may need to:
  - Increase timeout value
  - Investigate underlying system issues
  - Add retry logic

## Migration Notes

### Breaking Changes

**None** - This is an internal refactoring that maintains the same external behavior.

### Rollback Plan

If issues arise after deployment:

1. **Immediate rollback:**
   - Revert commits from Phases 1-3
   - Fixed delays will be restored
   - No data migration needed

2. **Partial rollback:**
   - Can revert individual phases if one is problematic
   - E.g., keep window improvements but revert clipboard changes

### Deployment Strategy

**Recommended approach:**

1. Deploy Phase 1 (windows) first
   - Most visible user-facing impact
   - Easiest to verify

2. Wait 24-48 hours, monitor logs

3. Deploy Phase 2 (clipboard)
   - Test thoroughly in production

4. Wait 24-48 hours, monitor logs

5. Deploy Phase 3 (focus)
   - Smallest change, lowest risk

6. Deploy Phase 4 (documentation)

**Alternative:** Deploy all phases together since they're independent

### Monitoring

**After deployment, monitor for:**

1. **Timeout warnings** in logs
   - `⚠️ WindowHelper: Timeout waiting for window`
   - `⚠️ ClipboardHelper: Timeout waiting for clipboard`
   - `⚠️ FocusHelper: Timeout waiting for application focus`

2. **Timing values** in success logs
   - Should typically be <100ms
   - Values >200ms may indicate system performance issues

3. **User reports** of:
   - Windows not appearing
   - Clipboard operations failing
   - Keyboard events going to wrong app

## References

- Original research: `thoughts/shared/research/2025-12-18-task-sleep-usages.md`
- Existing patterns:
  - Permission monitoring: `vcdr/UI/MenuBarController.swift:291-323`
  - withCheckedContinuation: `vcdr/Audio/AudioRecorder.swift:26-41`
  - Timer-based polling: `vcdr/Audio/AudioRecorder.swift:113-132`
- Related utilities:
  - `vcdr/Core/ScreenHelper.swift` - Window positioning
  - `vcdr/UI/NonActivatingPanel.swift` - Custom window behavior

## Conclusion

This plan systematically replaces all questionable Task.sleep usages with robust, polling-based mechanisms while preserving justified intentional delays. The implementation is incremental, testable, and provides clear improvement in both reliability and performance.

**Total Task.sleep instances after implementation:**
- **3 justified** (unchanged): Intentional UX delays
- **0 questionable** (all improved): Replaced with polling
- **7 new internal** (in polling loops): Controlled and documented

The polling-based approach provides the right balance of:
- ✅ Reliability (timeouts handle edge cases)
- ✅ Performance (faster on fast systems)
- ✅ Maintainability (clear, documented utilities)
- ✅ Future-proofing (documented enhancement paths)
