---
date: 2026-02-20T09:10:00+00:00
researcher: Claude
git_commit: f760e6b
branch: main
repository: vibe-coding-done-right
topic: "VCDR Project Architecture & Swift App Development Fundamentals"
tags: [research, codebase, architecture, swift, swiftui, concurrency, macos]
status: complete
last_updated: 2026-02-20
last_updated_by: Claude
---

# Research: VCDR Project Architecture & Swift App Development Fundamentals

**Date**: 2026-02-20
**Git Commit**: f760e6b
**Branch**: main
**Repository**: vibe-coding-done-right

## Research Question

Document the current VCDR project architecture and provide an in-depth educational guide to Swift app development concepts used in the project, for someone new to Swift.

## Summary

VCDR is a minimal macOS menu bar push-to-talk voice transcription app. It records audio while a global hotkey is held, transcribes via on-device ML (Parakeet/FluidAudio), and executes a post-transcription action (paste or bash command). The codebase is 25 Swift files, ~2,200 lines total, following strict architectural rules: no singletons, no god objects, dependency injection, protocol abstractions, structured logging, and Swift 6 strict concurrency.

---

# Part 1: VCDR Project Architecture

## 1.1 High-Level Data Flow

```
User holds hotkey
       ↓
GlobalHotkeyManager detects keyDown via CGEvent tap
       ↓
PushToTalkCoordinator.onHotkeyDown()
       ↓
AudioRecorder.startRecording() → 16kHz mono WAV to temp file
       ↓
RecordingIndicatorPanel.show() → floating waveform indicator
       ↓
User releases hotkey
       ↓
GlobalHotkeyManager detects keyUp
       ↓
PushToTalkCoordinator.stopRecordingAndTranscribe()
       ↓
AudioRecorder.stopRecording() → returns audio file URL
       ↓
ParakeetProvider.transcribe(audioFileURL:) → CoreML on Neural Engine
       ↓
PostTranscriptionAction.execute(text:)
       ├── PasteAction: clipboard + simulated Cmd+V
       └── BashAction: /bin/bash -c with $VCDR_TEXT env var
       ↓
State returns to idle
```

## 1.2 App Entry Point

**File**: `vcdr/vcdr/vcdrApp.swift` (23 lines)

```swift
@main
struct vcdrApp: App {
    @State private var dependencies = AppDependencies()

    var body: some Scene {
        MenuBarExtra { ... } label: { ... }
        Window("VCDR", id: "main") {
            MainWindowView(dependencies: dependencies)
                .task { await dependencies.initialize() }
        }
    }
}
```

Key concepts at play:
- `@main` — marks this struct as the app's entry point. Swift generates the actual `main()` function.
- `App` protocol — defines the app's structure as a collection of `Scene`s.
- `@State` — owns the `AppDependencies` instance. SwiftUI manages its lifecycle.
- `MenuBarExtra` — a Scene that creates a menu bar icon with a dropdown.
- `Window` — a Scene that creates a standard window (the settings/main window).
- `.task { }` — launches an async task when the view appears; automatically cancelled when it disappears.

## 1.3 Dependency Injection Container

**File**: `vcdr/vcdr/App/AppDependencies.swift` (111 lines)

This is the **only place** in the entire app where objects are created. Every other type receives its dependencies through `init`.

```swift
@Observable
final class AppDependencies {
    let settings: AppSettings
    let transcriptionProvider: ParakeetProvider
    let coordinator: PushToTalkCoordinator
    let audioDeviceMonitor: AudioDeviceMonitor
    let inputLevelMonitor: InputLevelMonitor
    let modeSwitcherCoordinator: ModeSwitcherCoordinator

    init() {
        let settings = AppSettings()
        let provider = ParakeetProvider()
        self.settings = settings
        self.transcriptionProvider = provider
        self.coordinator = PushToTalkCoordinator(settings: settings, transcriptionProvider: provider)
        self.audioDeviceMonitor = AudioDeviceMonitor(settings: settings)
        self.inputLevelMonitor = InputLevelMonitor()
        self.modeSwitcherCoordinator = ModeSwitcherCoordinator(settings: settings)
    }
}
```

**Dependency graph** (arrows = "depends on"):
```
AppDependencies
├── AppSettings (standalone — no dependencies)
├── ParakeetProvider (standalone — no dependencies)
├── PushToTalkCoordinator → AppSettings, ParakeetProvider
│   ├── AudioRecorder (created internally)
│   ├── GlobalHotkeyManager (created internally)
│   └── RecordingIndicatorPanel (created internally)
├── AudioDeviceMonitor → AppSettings
├── InputLevelMonitor (standalone)
└── ModeSwitcherCoordinator → AppSettings
    ├── GlobalHotkeyManager (created internally)
    └── ModeSwitcherPanel (created internally)
```

`AppDependencies` also manages:
- **Initialization**: downloads/compiles the ML model, polls permission state
- **Permission tracking**: `hasMicrophonePermission`, `hasAccessibilityPermission`
- **Permission polling**: Timer that checks every 2s until both permissions are granted, then self-stops

## 1.4 The State Machine (PushToTalkCoordinator)

**File**: `vcdr/vcdr/Orchestration/PushToTalkCoordinator.swift` (239 lines)

The coordinator is a finite state machine with 5 states:

```
idle ──hotkey down──→ recording ──hotkey up──→ transcribing ──→ executing ──→ idle
  ↑                       │                        │                │
  └───── error ←──────────┴────────────────────────┴────────────────┘
         (auto-resets after 3s)
```

Each state maps to a menu bar icon:
| State | Icon |
|---|---|
| idle | `waveform.circle` |
| recording | `waveform.circle.fill` |
| transcribing | `ellipsis.circle` |
| executing | `arrow.right.circle` |
| error | `exclamationmark.circle` |

The coordinator owns (internally creates) three helper objects:
- `AudioRecorder` — AVFoundation recording
- `GlobalHotkeyManager` — CGEvent tap for the push-to-talk hotkey
- `RecordingIndicatorPanel` — floating NSPanel shown during recording

**Key design decision**: `stopRecordingAndTranscribe()` is synchronous — it immediately updates `state` and the UI within the same RunLoop cycle, then kicks off the async transcription in a background `Task`. This ensures the recording indicator hides instantly when the key is released.

## 1.5 Settings & Persistence

**File**: `vcdr/vcdr/Core/Settings/AppSettings.swift` (144 lines)

`AppSettings` is an `@Observable` class backed by `UserDefaults`. Every property uses `didSet { save() }` to auto-persist on change.

Stored settings:
- `pushToTalkHotkey: HotkeyBinding` — keyCode + modifiers, encoded as JSON `Data`
- `modeSwitcherHotkey: HotkeyBinding` — same format
- `modes: [Mode]` — array of Mode structs, encoded as JSON `Data`
- `activeModeID: UUID` — which mode is active, stored as String
- `preferredInputDeviceID: String?` — audio device UID or nil for system default

**File**: `vcdr/vcdr/Core/Settings/Mode.swift` (51 lines)

```swift
struct Mode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var actionType: PostTranscriptionActionType  // .paste or .bash
    var bashCommand: String
    var terminatorTemplateEnabled: Bool
    var terminatorTemplate: String
}
```

Modes are the core configuration unit — each mode defines what happens after transcription (paste vs. bash) and optional text post-processing (terminator template that appends punctuation).

## 1.6 Transcription Layer

### Protocol

**File**: `vcdr/vcdr/Transcription/TranscriptionProvider.swift` (25 lines)

```swift
protocol TranscriptionProvider: Sendable {
    var name: String { get }
    var isReady: Bool { get async }
    func initialize() async throws
    func transcribe(audioFileURL: URL) async throws -> String
}
```

This is the abstraction boundary. Any speech-to-text backend can be swapped in by conforming to this protocol.

### Implementation: ParakeetProvider

**File**: `vcdr/vcdr/Transcription/ParakeetProvider.swift` (80 lines)

```swift
actor ParakeetProvider: TranscriptionProvider { ... }
```

This is an **actor** — Swift's thread-safe reference type. All access to its internal state (the `AsrManager` and `isReady` flag) is automatically serialized, preventing data races.

Initialization has 3 phases:
1. **Download** — fetches the ~1.2GB Parakeet v3 model (cached after first run)
2. **Compile** — compiles the CoreML model for the Neural Engine (slow first time, cached after)
3. **Ready** — `AsrManager` is initialized and ready for transcription

The `AppDependencies` polls `initPhase` every 200ms to show download/compile progress in the UI.

## 1.7 Audio Recording

**File**: `vcdr/vcdr/Audio/AudioRecorder.swift` (101 lines)

Records to a temporary WAV file at **16kHz mono 16-bit PCM** — this is Parakeet's native format, avoiding any resampling overhead. Uses `AVAudioRecorder` from AVFoundation.

Includes audio level metering via a Timer that polls `averagePower(forChannel:)` every 50ms and normalizes it to 0.0–1.0.

**File**: `vcdr/vcdr/Audio/AudioDeviceMonitor.swift` (89 lines)

Enumerates available input devices using `AVCaptureDevice.DiscoverySession` and monitors for connect/disconnect events via `NotificationCenter`. Falls back to system default if the selected device is disconnected.

**File**: `vcdr/vcdr/Audio/InputLevelMonitor.swift` (148 lines)

Real-time audio level monitoring using `AVAudioEngine` (lower-level than `AVAudioRecorder`). Installs a tap on the input node to compute RMS of audio buffers. Can target a specific device by UID via CoreAudio's `AudioUnitSetProperty`.

## 1.8 Global Hotkey System

**File**: `vcdr/vcdr/Hotkeys/GlobalHotkeyManager.swift` (133 lines)

Uses a **CGEvent tap** at `.cgSessionEventTap` to intercept all keyboard events system-wide. This is a macOS-specific low-level API that:
- Requires **Accessibility permissions** (checked via `AXIsProcessTrusted()`)
- Requires **no App Sandbox** (can't tap session events from a sandbox)
- Runs on the **main RunLoop** via `CFRunLoopSource`

The tap filters for keyDown/keyUp events matching the target keyCode + modifiers, consuming them (returning `nil`) so they don't reach other apps. Non-matching events pass through unchanged.

Key details:
- **Key repeat filtering**: `keyboardEventAutorepeat` field distinguishes initial press from held repeats
- **KeyUp modifier handling**: On keyUp, only the keyCode is checked (not modifiers) because the user may release the modifier keys before the main key
- **Auto-re-enable**: If the system disables the tap (timeout or user input), it re-enables automatically

## 1.9 Post-Transcription Actions

### Protocol

**File**: `vcdr/vcdr/Actions/PostTranscriptionAction.swift` (20 lines)

```swift
protocol PostTranscriptionAction: Sendable {
    var name: String { get }
    func execute(text: String) async throws
}
```

### PasteAction

**File**: `vcdr/vcdr/Actions/PasteAction.swift` (36 lines)

1. Copies text to `NSPasteboard.general`
2. Waits 50ms for clipboard to settle
3. Simulates Cmd+V via `CGEvent` (keyDown + keyUp for virtual key 9 = "V")

### BashAction

**File**: `vcdr/vcdr/Actions/BashAction.swift` (48 lines)

Runs a configurable shell command via `Process` (Swift's `NSTask` equivalent). The transcribed text is passed via the `$VCDR_TEXT` environment variable — this avoids shell injection issues that would occur with string interpolation into the command.

## 1.10 UI Architecture

The UI uses a **NavigationSplitView** with a sidebar and detail area:

```
┌─────────────────────────────────────────────────┐
│ VCDR                                            │
├──────────┬──────────────────────────────────────┤
│ Sidebar  │ Detail                               │
│          │                                      │
│ ● Home   │ [Content for selected tab]           │
│ ○ Modes  │                                      │
│ ○ Trans. │                                      │
│          │                                      │
└──────────┴──────────────────────────────────────┘
```

**Files**:
- `UI/MainWindowView.swift` (78 lines) — NavigationSplitView with 3 tabs
- `UI/HomeTabView.swift` (159 lines) — permissions, audio device, record button, hotkey config
- `UI/ModesTabView.swift` (135 lines) — modes list + detail editor (push navigation)
- `UI/TranscriptionTabView.swift` (67 lines) — model status display
- `UI/MenuBarView.swift` (67 lines) — menu bar dropdown
- `UI/AudioSectionView.swift` (80 lines) — device picker + sound check meter
- `UI/ShortcutRecorderRow.swift` (108 lines) — hotkey capture widget
- `UI/RecordingIndicator.swift` (64 lines) — floating NSPanel with animated waveform
- `UI/ModeSwitcherPanel.swift` (197 lines) — popup for quick mode switching with keyboard nav

## 1.11 Logging

**File**: `vcdr/vcdr/Core/Logging/Logger+Extensions.swift` (13 lines)

Seven log categories: `app`, `recording`, `transcription`, `hotkeys`, `actions`, `settings`, `audio`. All use `OSLog` via `Logger` — filterable in Console.app by subsystem (`glebglazov.vcdr`) and category.

## 1.12 File Inventory

| Directory | Files | Purpose |
|---|---|---|
| `vcdrApp.swift` | 1 | App entry point |
| `App/` | 1 | DI container |
| `Core/Logging/` | 1 | OSLog extensions |
| `Core/Settings/` | 2 | Settings + Mode model |
| `Transcription/` | 2 | Protocol + Parakeet implementation |
| `Audio/` | 3 | Recorder, device monitor, level monitor |
| `Hotkeys/` | 1 | CGEvent tap manager |
| `Actions/` | 3 | Protocol + Paste + Bash |
| `Orchestration/` | 2 | Push-to-talk + mode switcher coordinators |
| `UI/` | 9 | All views and panels |
| **Total** | **25 files** | **~2,200 lines** |

---

# Part 2: Swift App Development Fundamentals

## 2.1 Value Types vs Reference Types

Swift has two fundamental categories of types:

**Value types** (`struct`, `enum`) — copied on assignment. Each variable holds its own independent copy.

```swift
struct HotkeyBinding {
    var keyCode: UInt16
    var modifiers: UInt64
}

var a = HotkeyBinding(keyCode: 49, modifiers: 256)
var b = a        // b is a COPY of a
b.keyCode = 50   // only b changes; a.keyCode is still 49
```

**Reference types** (`class`, `actor`) — shared on assignment. Multiple variables point to the same object.

```swift
class AppSettings {
    var pushToTalkHotkey: HotkeyBinding
}

let a = AppSettings()
let b = a        // b points to the SAME object as a
b.pushToTalkHotkey.keyCode = 50   // a sees this change too
```

**When to use which:**
- **Structs** for data (settings, models, configuration). In VCDR: `HotkeyBinding`, `Mode`, `AudioInputDevice`
- **Classes** for identity/lifecycle (objects that need to be shared and mutated). In VCDR: `AppSettings`, `PushToTalkCoordinator`, `AudioRecorder`
- **Actors** for shared mutable state that needs thread safety. In VCDR: `ParakeetProvider`

Swift strongly prefers value types. Apple's guidance: "Use structs by default. Use classes when you need identity or Objective-C interoperability."

Sources: [Value And Reference Types — Swift.org](https://www.swift.org/documentation/articles/value-and-reference-types.html)

## 2.2 Protocols and Protocol-Oriented Programming

A **protocol** defines a contract — a set of methods and properties that conforming types must implement:

```swift
protocol TranscriptionProvider: Sendable {
    var name: String { get }
    var isReady: Bool { get async }
    func initialize() async throws
    func transcribe(audioFileURL: URL) async throws -> String
}
```

Any type can conform — struct, class, actor, enum:

```swift
actor ParakeetProvider: TranscriptionProvider {
    let name = "Parakeet Multilingual v3"
    // ... implements all required members
}
```

**Why protocols matter:**
- **Decoupling**: `PushToTalkCoordinator` doesn't know about `ParakeetProvider` specifically — it just knows it has a `TranscriptionProvider`
- **Testability**: You can create a `MockTranscriptionProvider` for tests
- **Extensibility**: Add a new backend (Whisper, OpenAI API) without changing any existing code

In VCDR, there are 2 protocol abstractions: `TranscriptionProvider` and `PostTranscriptionAction`.

Sources: [Protocol-oriented programming — Hacking with Swift](https://www.hackingwithswift.com/sixty/9/5/protocol-oriented-programming)

## 2.3 Enums with Associated Values

Swift enums can carry data with each case:

```swift
enum State: Equatable {
    case idle
    case recording
    case transcribing
    case executing
    case error(String)    // ← carries an error message
}
```

The `error` case holds a `String` payload. You extract it with pattern matching:

```swift
switch state {
case .idle: return "Ready"
case .recording: return "Recording..."
case .error(let msg): return "Error: \(msg)"
// ...
}
```

This is far safer than using an error string property that might be nil or stale — the data is *only* available when you're in the error state.

VCDR also uses enums for error types:

```swift
enum TranscriptionError: LocalizedError {
    case providerUnavailable
    case initializationFailed(String)
    case transcriptionFailed(String)
}
```

Sources: [Enum associated values — Hacking with Swift](https://www.hackingwithswift.com/sixty/2/9/enum-associated-values)

## 2.4 Optionals

Swift has no `null` — instead, it has **optionals**, which explicitly mark values that might be absent:

```swift
private var audioRecorder: AVAudioRecorder?   // might be nil
private var levelTimer: Timer?                 // might be nil
```

The `?` means "this value is either an `AVAudioRecorder` or `nil`." You cannot use the value without unwrapping it:

```swift
// guard let — unwrap or exit the function
guard let recorder = audioRecorder else { return nil }
// recorder is now safely unwrapped

// if let — unwrap in a specific scope
if let data = userDefaults.data(forKey: key) {
    // data is available here
}

// Optional chaining — call methods only if non-nil
audioRecorder?.stop()   // does nothing if audioRecorder is nil
```

**Force unwrap** (`!`) crashes if the value is nil:
```swift
let url = URL(string: "https://example.com")!  // OK for compile-time constants
let data = userDefaults.data(forKey: key)!      // DANGEROUS — crashes if key missing
```

VCDR's rules: never force-unwrap in production code, except for static constants known at compile time.

Sources: [Optional — Apple Developer Documentation](https://developer.apple.com/documentation/swift/optional)

## 2.5 Access Control

```swift
@Observable
final class PushToTalkCoordinator {
    private(set) var state: State = .idle           // readable externally, writable only internally
    private let settings: AppSettings               // fully private
    private var previousActiveApp: NSRunningApplication?  // fully private

    func setupHotkey() { ... }                      // internal (default) — accessible within the module
    private func onHotkeyDown() async { ... }       // private — only this type
}
```

| Keyword | Visibility |
|---|---|
| `private` | Only within the declaring type |
| `fileprivate` | Only within the same file |
| `internal` (default) | Anywhere in the same module (app/framework) |
| `public` | Accessible from other modules |
| `open` | Like public, but also subclassable from other modules |
| `final` | Prevents subclassing (used on all VCDR classes) |

`private(set)` is a common pattern: the property is readable from outside but only writable from inside. Used for `state`, `isRecording`, `audioLevel`, `isMonitoring`, etc.

## 2.6 Property Observers (didSet)

```swift
var pushToTalkHotkey: HotkeyBinding {
    didSet { save() }
}
```

`didSet` runs **after** the property changes. Every property in `AppSettings` uses `didSet { save() }` to auto-persist to `UserDefaults` whenever any setting changes.

`willSet` runs **before** the change (with the new value available as `newValue`). VCDR doesn't use `willSet`.

The `@Observable` macro also uses property observation internally — it synthesizes `willSet`/`didSet`-like behavior to notify SwiftUI when properties change.

Sources: [Property observers — Swift by Sundell](https://www.swiftbysundell.com/articles/property-observers-in-swift/)

---

## 2.7 Swift Concurrency

### async/await

Swift's structured concurrency replaces callback-based async code:

```swift
// Old pattern (callbacks):
AVCaptureDevice.requestAccess(for: .audio) { granted in
    // callback runs later on unknown thread
}

// Modern pattern (async/await):
let granted = await AVCaptureDevice.requestAccess(for: .audio)
// execution resumes here after the result is ready
```

`async` marks a function that can suspend (pause execution without blocking the thread). `await` marks the suspension point — execution pauses here and resumes when the result is ready.

### Actors

An **actor** is a reference type that protects its internal state from concurrent access:

```swift
actor ParakeetProvider: TranscriptionProvider {
    private var asr: AsrManager?     // protected by actor isolation
    private(set) var isReady = false  // protected by actor isolation

    func transcribe(audioFileURL: URL) async throws -> String { ... }
}
```

Only one task can execute inside the actor at a time. External access requires `await`:

```swift
// From outside the actor:
let ready = await transcriptionProvider.isReady  // must await
let text = try await transcriptionProvider.transcribe(audioFileURL: url)  // must await

// From inside the actor:
let ready = isReady  // direct access, no await needed
```

Actors solve **data races** — when two threads read/write the same memory simultaneously. The compiler enforces this at compile time.

### @MainActor

`@MainActor` constrains a type or function to run on the main thread (required for all UI work):

```swift
@Observable
@MainActor
final class ModeSwitcherCoordinator { ... }
```

All UI-related coordinators and monitors in VCDR are `@MainActor` because they update `@Observable` properties that SwiftUI reads.

### Task {}

`Task { }` creates an unstructured async context — it bridges synchronous code into async code:

```swift
hotkeyManager.onKeyDown = { [weak self] in
    Task { @MainActor in
        await self?.onHotkeyDown()
    }
}
```

The hotkey callback is synchronous (called from the CGEvent tap), but `onHotkeyDown()` is async. `Task { }` bridges the gap.

### Swift 6 Strict Concurrency

VCDR uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every type is implicitly `@MainActor` unless opted out. Swift 6 enforces that:
- Data shared across concurrency boundaries must be `Sendable`
- Actor isolation is checked at compile time
- `@Sendable` closures cannot capture mutable state

This is why `TranscriptionProvider` requires `: Sendable` and why `ParakeetProvider` is an `actor` — the compiler won't let you share a regular class across threads.

Sources:
- [Async await explained — SwiftLee](https://www.avanderlee.com/swift/async-await/)
- [Adopting strict concurrency in Swift 6 — Apple Developer](https://developer.apple.com/documentation/swift/adoptingswift6)
- [Actors — Hacking with Swift](https://www.hackingwithswift.com/swift/5.5/actors)

---

## 2.8 SwiftUI

### Declarative UI

SwiftUI is **declarative** — you describe *what* the UI should look like, and SwiftUI figures out *how* to make it happen:

```swift
struct MenuBarView: View {
    let dependencies: AppDependencies

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Circle()
                    .fill(dependencies.isTranscriptionReady ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(statusText)
            }
            Divider()
            Button("Quit VCDR") { NSApplication.shared.terminate(nil) }
        }
    }
}
```

This is **not** imperative ("create a circle, set its color, add it to a stack, add text next to it"). Instead, it's a **description**: "there is a VStack containing an HStack with a colored circle and text, then a divider, then a button."

When data changes (e.g., `isTranscriptionReady` becomes `true`), SwiftUI re-evaluates `body`, diffs the old and new descriptions, and only updates the parts that changed (the circle color).

### Views Are Structs

SwiftUI views are **lightweight value types** (structs). They are created and destroyed frequently — every time `body` is re-evaluated, new view structs are created. The actual on-screen rendering is managed by SwiftUI's internal render tree, not by the view structs themselves.

### @State and @Binding

```swift
@State private var selection: Tab? = .home       // view owns this data
@Binding var keyCode: UInt16                      // view borrows this data from parent
```

- `@State` — the view **owns** this value. SwiftUI stores it separately from the struct and preserves it across re-renders.
- `@Binding` — a **two-way reference** to data owned by a parent view. Changes propagate up and down.

### @Observable (Observation Framework)

The `@Observable` macro (macOS 14+ / iOS 17+) replaced the older `ObservableObject`/`@Published` pattern:

```swift
@Observable
final class AppSettings {
    var pushToTalkHotkey: HotkeyBinding { didSet { save() } }
    var modes: [Mode] { didSet { save() } }
    // ...
}
```

**What @Observable does under the hood:**
1. Synthesizes `willSet`/`didSet`-like observation tracking for every stored property
2. When SwiftUI evaluates a view's `body`, it records which `@Observable` properties were **read**
3. When any of those properties change, only the views that read them are re-rendered
4. No `@Published` needed — every property is automatically tracked

This is a massive improvement over the old pattern:
```swift
// OLD (pre-macOS 14):
class AppSettings: ObservableObject {
    @Published var hotkey: HotkeyBinding    // must mark each property
}

// NEW (macOS 14+):
@Observable
class AppSettings {
    var hotkey: HotkeyBinding               // automatically tracked
}
```

The old pattern re-rendered ALL views that observed the object when ANY property changed. The new pattern only re-renders views that read the specific property that changed.

### View Lifecycle

```swift
MainWindowView(dependencies: dependencies)
    .task { await dependencies.initialize() }    // runs when view appears (async)
    .onAppear { ... }                             // runs when view appears (sync)
    .onDisappear { dependencies.inputLevelMonitor.stop() }  // cleanup
    .onChange(of: selection) { path = NavigationPath() }     // reacts to changes
```

| Modifier | When it runs |
|---|---|
| `.onAppear` | View enters the render tree (synchronous) |
| `.task` | Like onAppear but creates an async context; auto-cancelled on disappear |
| `.onDisappear` | View leaves the render tree |
| `.onChange(of:)` | A specific value changes |

### NavigationSplitView and NavigationStack

VCDR uses both for its settings window:

```swift
NavigationSplitView {
    // Sidebar with tab list
    List(Tab.allCases, id: \.self, selection: $selection) { tab in
        Label(tab.title, systemImage: tab.systemImage)
    }
} detail: {
    // Detail area with NavigationStack for push navigation
    NavigationStack(path: $path) {
        // ... content based on selected tab
        .navigationDestination(for: UUID.self) { modeID in
            ModeDetailView(mode: ...)  // pushed when tapping a mode
        }
    }
}
```

`NavigationSplitView` creates the sidebar/detail split. `NavigationStack` inside the detail enables push navigation (e.g., tapping a mode pushes the mode editor).

### MenuBarExtra

```swift
MenuBarExtra {
    MenuBarView(dependencies: dependencies)   // dropdown content
} label: {
    Image(systemName: dependencies.coordinator.menuBarIcon)  // icon in menu bar
}
```

This is a SwiftUI Scene that creates a menu bar icon. The label is always visible in the menu bar. Clicking it shows the content as a dropdown.

### Form, Section, List

```swift
Form {
    Section("Audio") {
        Picker("Input Device", selection: ...) { ... }
    }
    Section("Shortcuts") {
        ShortcutRecorderRow(label: "Push-to-Talk", ...)
    }
}
.formStyle(.grouped)
```

`Form` is a container that automatically styles its children as a settings form. `Section` groups related controls with a header. `.formStyle(.grouped)` gives the macOS System Preferences look.

Sources:
- [All SwiftUI property wrappers — Hacking with Swift](https://www.hackingwithswift.com/quick-start/swiftui/all-swiftui-property-wrappers-explained-and-compared)
- [Migrating to Observable macro — Apple Developer](https://developer.apple.com/documentation/SwiftUI/Migrating-from-the-observable-object-protocol-to-the-observable-macro)
- [A Deep Dive Into Observation — Fatbobman](https://fatbobman.com/en/posts/mastering-observation/)
- [MenuBarExtra — Apple Developer Documentation](https://developer.apple.com/documentation/SwiftUI/MenuBarExtra)

---

## 2.9 macOS-Specific Concepts

### NSPanel vs NSWindow

`NSPanel` is a subclass of `NSWindow` designed for auxiliary, floating UI:

| Feature | NSWindow | NSPanel |
|---|---|---|
| Can be main window | Yes | No |
| Can be key window | Yes | Yes |
| Hides when app deactivates | No | Yes (by default) |
| Floats above other windows | No | Configurable |

VCDR uses NSPanel for two things:
1. **RecordingIndicatorPanel** — floating waveform indicator during recording (non-activating, so it doesn't steal focus)
2. **ModeSwitcherPanel** — popup for quick mode switching (subclassed as `KeyablePanel` to accept keyboard input)

Both use `.nonactivatingPanel` style mask — they appear without stealing focus from the user's current app.

Sources: [NSPanel — Apple Developer Documentation](https://developer.apple.com/documentation/appkit/nspanel)

### CGEvent Tap

A CGEvent tap intercepts system-wide keyboard/mouse events before they reach any application. It's the macOS mechanism for global hotkeys.

```swift
CGEvent.tapCreate(
    tap: .cgSessionEventTap,      // intercept at session level (all apps)
    place: .headInsertEventTap,   // process before other taps
    options: .defaultTap,         // can modify/consume events
    eventsOfInterest: eventMask,  // which events to intercept
    callback: { ... },            // your handler
    userInfo: pointer             // context pointer
)
```

Returning `nil` from the callback **consumes** the event (it won't reach any app). Returning the event passes it through.

**Requirements**: Accessibility permission (`AXIsProcessTrusted()`) and no App Sandbox.

### Accessibility Permissions

`AXIsProcessTrusted()` checks whether your app has been granted Accessibility access in System Settings. Without it, `CGEvent.tapCreate` returns nil.

VCDR polls this every 2 seconds on startup. When granted, it registers the hotkeys and stops polling.

### NSPasteboard (Clipboard)

```swift
let pasteboard = NSPasteboard.general
pasteboard.clearContents()
pasteboard.setString(text, forType: .string)
```

`NSPasteboard.general` is the system clipboard. After writing to it, VCDR waits 50ms before simulating Cmd+V — the clipboard write is not always instantaneous at the system level.

### App Sandbox

The App Sandbox restricts what a process can access. VCDR is **not sandboxed** because it needs:
1. CGEvent tap at `.cgSessionEventTap` — requires session-level access
2. `BashAction` — executes arbitrary shell commands via `/bin/bash`
3. `CGEvent.post` — simulates keyboard events to other apps

Not being sandboxed means VCDR can't be in the Mac App Store but can be distributed directly.

---

## 2.10 Dependency Injection

**The problem with singletons:**

```swift
// BAD — hidden dependency, untestable
class PushToTalkCoordinator {
    func doWork() {
        let hotkey = AppSettings.shared.hotkey  // where does this come from?
    }
}
```

**The solution — constructor injection:**

```swift
// GOOD — explicit, testable
class PushToTalkCoordinator {
    private let settings: AppSettings
    init(settings: AppSettings) {
        self.settings = settings
    }
}
```

**The DI container** (`AppDependencies`) is the single place where all objects are created and wired together. Every other type receives its dependencies through `init`.

Sources: [Different flavors of dependency injection — Swift by Sundell](https://www.swiftbysundell.com/articles/different-flavors-of-dependency-injection-in-swift/)

## 2.11 OSLog / Logger

```swift
import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "glebglazov.vcdr"
    static let recording = Logger(subsystem: subsystem, category: "recording")
}

// Usage:
Logger.recording.info("Recording started: \(audioFile.lastPathComponent)")
Logger.recording.error("Failed to start recording: \(error)")
```

**Log levels**: `debug` (not persisted), `info`, `notice`/`log` (default, persisted), `error` (persisted), `fault` (persisted).

**Privacy**: Dynamic values are automatically redacted as `<private>` in production logs. Use `\(value, privacy: .public)` to opt out for non-sensitive data.

**Viewing**: Filter by subsystem and category in Console.app on macOS.

Sources: [OSLog and Unified logging — SwiftLee](https://www.avanderlee.com/debugging/oslog-unified-logging/)

## 2.12 UserDefaults

A persistent key-value store backed by a `.plist` file. Loaded into memory at launch, so reads are instant. Designed for small amounts of settings data (aim for <512KB total).

VCDR stores `Codable` structs by encoding to JSON `Data`:

```swift
// Save
if let encoded = try? JSONEncoder().encode(pushToTalkHotkey) {
    userDefaults.set(encoded, forKey: Keys.pushToTalkHotkey)
}

// Load
if let data = userDefaults.data(forKey: Keys.pushToTalkHotkey),
   let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
    self.pushToTalkHotkey = decoded
}
```

Sources: [How to save user settings — Hacking with Swift](https://www.hackingwithswift.com/example-code/system/how-to-save-user-settings-using-userdefaults)

## 2.13 CoreML and the Neural Engine

**CoreML** runs ML models on-device (privacy, no latency, offline). It dispatches computation across CPU, GPU, and the **Apple Neural Engine (ANE)** — a dedicated chip for tensor math at low power.

VCDR uses CoreML via FluidAudio's Parakeet SDK:
1. First launch downloads the ~1.2GB model
2. CoreML compiles it for the Neural Engine (cached after first run)
3. Transcription runs at ~110x realtime on M4 Pro (5s audio → <50ms transcription)

Sources: [Core ML — Apple Developer](https://developer.apple.com/documentation/coreml)

## 2.14 Key Swift Protocols Used

| Protocol | What it does | Used in VCDR |
|---|---|---|
| `Equatable` | Enables `==` comparison. Auto-synthesized for structs with Equatable properties. | `HotkeyBinding`, `Mode`, `State` |
| `Identifiable` | Requires an `id` property. Needed by SwiftUI's `List`/`ForEach` for efficient diffing. | `Mode`, `AudioInputDevice` |
| `Codable` | Enables JSON/plist serialization. Auto-synthesized when all properties are Codable. | `HotkeyBinding`, `Mode`, `PostTranscriptionActionType` |
| `CaseIterable` | Exposes `allCases` on enums. Used for SwiftUI pickers and iteration. | `PostTranscriptionActionType`, `MainWindowView.Tab` |
| `LocalizedError` | Provides user-facing error messages via `errorDescription`. | `TranscriptionError`, `ActionError` |
| `Sendable` | Marks types safe to pass across concurrency boundaries. Required by Swift 6. | `TranscriptionProvider`, `PostTranscriptionAction` |

---

## Code References

- `vcdr/vcdr/vcdrApp.swift` — App entry point, MenuBarExtra + Window scenes
- `vcdr/vcdr/App/AppDependencies.swift` — DI container, initialization, permission polling
- `vcdr/vcdr/Core/Settings/AppSettings.swift` — UserDefaults-backed settings with didSet auto-save
- `vcdr/vcdr/Core/Settings/Mode.swift` — Mode data model (Identifiable, Codable, Equatable)
- `vcdr/vcdr/Orchestration/PushToTalkCoordinator.swift` — State machine: idle→recording→transcribing→executing
- `vcdr/vcdr/Orchestration/ModeSwitcherCoordinator.swift` — Mode switcher hotkey + panel
- `vcdr/vcdr/Transcription/TranscriptionProvider.swift` — Protocol abstraction for STT backends
- `vcdr/vcdr/Transcription/ParakeetProvider.swift` — FluidAudio Parakeet actor implementation
- `vcdr/vcdr/Audio/AudioRecorder.swift` — AVFoundation 16kHz mono recording
- `vcdr/vcdr/Audio/AudioDeviceMonitor.swift` — Input device enumeration + hot-plug monitoring
- `vcdr/vcdr/Audio/InputLevelMonitor.swift` — Real-time RMS level via AVAudioEngine
- `vcdr/vcdr/Hotkeys/GlobalHotkeyManager.swift` — CGEvent tap for global hotkeys
- `vcdr/vcdr/Actions/PostTranscriptionAction.swift` — Action protocol + error types
- `vcdr/vcdr/Actions/PasteAction.swift` — Clipboard + simulated Cmd+V
- `vcdr/vcdr/Actions/BashAction.swift` — Shell command with $VCDR_TEXT env var
- `vcdr/vcdr/UI/MainWindowView.swift` — NavigationSplitView with sidebar tabs
- `vcdr/vcdr/UI/HomeTabView.swift` — Permissions, audio, recording button, hotkey config
- `vcdr/vcdr/UI/ModesTabView.swift` — Modes list + detail editor
- `vcdr/vcdr/UI/MenuBarView.swift` — Menu bar dropdown
- `vcdr/vcdr/UI/RecordingIndicator.swift` — Floating NSPanel recording indicator
- `vcdr/vcdr/UI/ModeSwitcherPanel.swift` — Floating mode switcher with keyboard nav
- `vcdr/vcdr/UI/ShortcutRecorderRow.swift` — Hotkey capture widget
- `vcdr/vcdr/UI/AudioSectionView.swift` — Device picker + sound check meter
- `vcdr/vcdr/UI/TranscriptionTabView.swift` — Transcription model status
- `vcdr/vcdr/Core/Logging/Logger+Extensions.swift` — OSLog categories

## Historical Context (from thoughts/)

- `thoughts/shared/plans/2026-02-18-vcdr-minimal-ptt-app.md` — Original implementation plan with 7 phases, from project scaffold to settings UI. Documents key discoveries from the original app and the "desired end state" vision.
- `thoughts/shared/plans/2026-02-19-tabbed-settings-ui.md` — Plan for tabbed settings UI redesign
- `thoughts/shared/plans/2026-02-19-home-recording-modes-navigation.md` — Plan for home tab, recording button, modes navigation
- `thoughts/shared/plans/2026-02-19-xcode-style-settings-ui.md` — Plan for Xcode-style NavigationSplitView settings
- `thoughts/shared/handoffs/2026-02-19_23-19-37_xcode-style-settings-ui.md` — Handoff from the settings UI redesign session
- `thoughts/shared/ios-macos-rendering-explained.md` — Detailed explainer on SwiftUI rendering, RunLoop, why Task.sleep is used as workarounds for system API timing

## Sources

### Apple Developer Documentation
- [Core ML](https://developer.apple.com/documentation/coreml)
- [NSPanel](https://developer.apple.com/documentation/appkit/nspanel)
- [MenuBarExtra](https://developer.apple.com/documentation/SwiftUI/MenuBarExtra)
- [AVAudioRecorder](https://developer.apple.com/documentation/avfaudio/avaudiorecorder)
- [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard)
- [Optional](https://developer.apple.com/documentation/swift/optional)
- [Access Control](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/)
- [Adopting Swift 6 Concurrency](https://developer.apple.com/documentation/swift/adoptingswift6)
- [Migrating to Observable Macro](https://developer.apple.com/documentation/SwiftUI/Migrating-from-the-observable-object-protocol-to-the-observable-macro)
- [CaseIterable](https://developer.apple.com/documentation/swift/caseiterable)
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)

### Educational Articles
- [Value And Reference Types — Swift.org](https://www.swift.org/documentation/articles/value-and-reference-types.html)
- [Protocol-oriented programming — Hacking with Swift](https://www.hackingwithswift.com/sixty/9/5/protocol-oriented-programming)
- [Enum associated values — Hacking with Swift](https://www.hackingwithswift.com/sixty/2/9/enum-associated-values)
- [Async await explained — SwiftLee](https://www.avanderlee.com/swift/async-await/)
- [Actors — Hacking with Swift](https://www.hackingwithswift.com/swift/5.5/actors)
- [All SwiftUI property wrappers — Hacking with Swift](https://www.hackingwithswift.com/quick-start/swiftui/all-swiftui-property-wrappers-explained-and-compared)
- [A Deep Dive Into Observation — Fatbobman](https://fatbobman.com/en/posts/mastering-observation/)
- [OSLog and Unified logging — SwiftLee](https://www.avanderlee.com/debugging/oslog-unified-logging/)
- [Different flavors of DI — Swift by Sundell](https://www.swiftbysundell.com/articles/different-flavors-of-dependency-injection-in-swift/)
- [Property observers — Swift by Sundell](https://www.swiftbysundell.com/articles/property-observers-in-swift/)
- [Make a floating panel — Cindori Developer](https://cindori.com/developer/floating-panel)
- [Everything about the Apple Neural Engine — GitHub/hollance](https://github.com/hollance/neural-engine)
- [LocalizedError — NSHipster](https://nshipster.com/swift-foundation-error-protocols/)
- [How to save user settings — Hacking with Swift](https://www.hackingwithswift.com/example-code/system/how-to-save-user-settings-using-userdefaults)

## Open Questions

- How does the `@Observable` macro interact with `@MainActor` isolation in practice? (The compiler enforces that `@Observable` class mutations happen on the correct actor.)
- What happens to the CGEvent tap if the app crashes? (It is cleaned up by the system when the process exits.)
- How is the Parakeet model cache invalidated when upgrading to a new version? (FluidAudio handles this via versioned download paths.)
