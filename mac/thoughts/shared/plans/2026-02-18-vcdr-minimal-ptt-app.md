# VCDR Minimal Push-to-Talk App — Implementation Plan

## Overview

Build a minimal macOS menu bar app with push-to-talk voice transcription. The app abstracts voice models behind a protocol, uses NVIDIA Parakeet Multilingual (via FluidAudio CoreML SDK) as the first implementation, and supports two post-transcription actions: paste into the current app or run a bash command with `{}` argument substitution.

## Current State Analysis

### What Exists Now
- Fresh Xcode project scaffold at `mac/vcdr/` with template `vcdrApp.swift` and `ContentView.swift`
- Uses `PBXFileSystemSynchronizedRootGroup` — new files on disk are auto-included by Xcode
- Multi-platform project (iOS + macOS + visionOS) — needs to be narrowed to macOS-only
- App Sandbox enabled — must be disabled for global hotkeys (CGEvent tap) and accessibility (simulated paste)
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` enabled (Swift 6 strict concurrency)
- Deployment target: macOS 26.0

### Key Discoveries from Original App
- Original `GlobalHotkeyManager` uses CGEvent tap at `.cgSessionEventTap` — requires accessibility permissions and no App Sandbox
- Original `PasteDestination` simulates Cmd+V via CGEvent — also requires accessibility permissions
- Original `TranscriptionProvider` protocol is clean and reusable as inspiration
- Original code quality review identified singletons, god objects, magic numbers as key problems to avoid

## Desired End State

A macOS menu bar app that:
1. Shows a waveform icon in the menu bar
2. Registers a single global hotkey (default: Cmd+Option+Space)
3. On hold: records audio from microphone
4. On release: transcribes via Parakeet Multilingual, then either pastes into the focused app or runs a configurable bash command
5. Has a settings window to configure the hotkey, select the action, and set the bash command
6. Uses clean architecture: no singletons, DI via container, OSLog throughout

### Verification Criteria
- Hold hotkey → recording starts → release → text appears in target app (paste mode)
- Hold hotkey → recording starts → release → bash command runs with transcribed text (bash mode)
- Settings persist across app restart
- Action can be switched between paste and bash in settings
- `xcodebuild -scheme vcdr -destination 'platform=macOS' build` succeeds

## What We're NOT Doing

- No LLM/mode processing (raw transcription only for now)
- No capture session concept (single push-to-talk → transcribe → action)
- No history/persistence of transcriptions
- No mini overlay or results overlay
- No multiple input sources (just voice)
- No tmux destination
- No HUD notifications (just menu bar icon state changes)
- No streaming transcription (full audio file after recording stops)
- No custom transcription model selection UI (hardcoded to Parakeet v3 for now)

## Project Structure

```
vcdr/vcdr/
├── vcdrApp.swift                          # @main, MenuBarExtra + Settings window
├── App/
│   └── AppDependencies.swift              # DI container
├── Core/
│   ├── Logging/
│   │   └── Logger+Extensions.swift        # OSLog categories
│   └── Settings/
│       └── AppSettings.swift              # UserDefaults-backed settings
├── Transcription/
│   ├── TranscriptionProvider.swift         # Protocol abstraction
│   └── ParakeetProvider.swift             # FluidAudio implementation
├── Audio/
│   └── AudioRecorder.swift                # AVFoundation mic recording
├── Hotkeys/
│   └── GlobalHotkeyManager.swift          # CGEvent tap, key-down/key-up detection
├── Actions/
│   ├── PostTranscriptionAction.swift      # Action protocol + enum
│   ├── PasteAction.swift                  # Simulated Cmd+V paste
│   └── BashAction.swift                   # Shell command execution
├── Orchestration/
│   └── PushToTalkCoordinator.swift        # Wires hotkey → record → transcribe → action
└── UI/
    ├── MenuBarView.swift                  # Menu bar dropdown
    └── SettingsView.swift                 # Settings window
```

---

## Phase 0: Xcode Project Configuration

### Overview
Configure the Xcode project for macOS-only, disable App Sandbox, add FluidAudio dependency, and set up Info.plist for microphone access.

### Changes Required:

#### 1. Xcode Project Settings (via `project.pbxproj`)
The following changes must be made in Xcode or by editing `project.pbxproj`:

**Target: vcdr (both Debug and Release)**:
- `SUPPORTED_PLATFORMS` = `macosx` (remove iOS, visionOS)
- `TARGETED_DEVICE_FAMILY` = remove (macOS doesn't use this)
- `ENABLE_APP_SANDBOX` = `NO` (required for CGEvent tap and accessibility)
- Remove all `[sdk=iphoneos*]` and `[sdk=iphonesimulator*]` Info.plist keys
- Add `INFOPLIST_FILE` pointing to a custom `Info.plist` (for microphone usage description)

**Target: vcdrTests and vcdrUITests**:
- `SUPPORTED_PLATFORMS` = `macosx`
- Remove `TARGETED_DEVICE_FAMILY`

#### 2. Info.plist
**File**: `vcdr/vcdr/Info.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSMicrophoneUsageDescription</key>
    <string>VCDR needs microphone access for voice recording and transcription.</string>
</dict>
</plist>
```

#### 3. Add FluidAudio Swift Package Dependency
In Xcode: File → Add Package Dependencies → `https://github.com/FluidInference/FluidAudio.git`, version `0.7.9` or later.

This adds to `project.pbxproj`:
- A `XCRemoteSwiftPackageReference` for FluidAudio
- A `XCSwiftPackageProductDependency` linking `FluidAudio` to the vcdr target

### Success Criteria:

#### Automated Verification:
- [ ] Project builds for macOS only: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- [ ] No iOS/visionOS targets in build settings

#### Manual Verification:
- [ ] FluidAudio package resolves and compiles
- [ ] App launches on macOS

**Implementation Note**: This phase requires manual Xcode interaction for package dependency addition and some build settings. The `project.pbxproj` edits can be done programmatically but SPM dependency is safer to add through Xcode UI.

---

## Phase 1: Foundation Infrastructure

### Overview
Set up logging, DI container, and settings. This is the scaffolding everything else builds on.

### Changes Required:

#### 1. Logging
**File**: `vcdr/vcdr/Core/Logging/Logger+Extensions.swift`

```swift
import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "glebglazov.vcdr"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let actions = Logger(subsystem: subsystem, category: "actions")
    static let settings = Logger(subsystem: subsystem, category: "settings")
}
```

#### 2. Settings
**File**: `vcdr/vcdr/Core/Settings/AppSettings.swift`

```swift
import Foundation
import OSLog

enum PostTranscriptionActionType: String, CaseIterable, Codable {
    case paste = "paste"
    case bash = "bash"
}

@Observable
final class AppSettings {
    // Hotkey
    var hotkeyKeyCode: UInt16 {
        didSet { save() }
    }
    var hotkeyModifiers: UInt64 {
        didSet { save() }
    }

    // Action
    var actionType: PostTranscriptionActionType {
        didSet { save() }
    }
    var bashCommand: String {
        didSet { save() }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // Load saved values or defaults
        // Default hotkey: Cmd+Option+Space (keyCode 49 = Space)
        self.hotkeyKeyCode = UInt16(userDefaults.integer(forKey: "hotkeyKeyCode"))
        if self.hotkeyKeyCode == 0 { self.hotkeyKeyCode = 49 } // Space
        self.hotkeyModifiers = UInt64(userDefaults.integer(forKey: "hotkeyModifiers"))
        if self.hotkeyModifiers == 0 {
            self.hotkeyModifiers = UInt64(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue)
        }
        self.actionType = PostTranscriptionActionType(
            rawValue: userDefaults.string(forKey: "actionType") ?? ""
        ) ?? .paste
        self.bashCommand = userDefaults.string(forKey: "bashCommand") ?? "echo {}"
    }

    private func save() {
        userDefaults.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode")
        userDefaults.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers")
        userDefaults.set(actionType.rawValue, forKey: "actionType")
        userDefaults.set(bashCommand, forKey: "bashCommand")
        Logger.settings.info("Settings saved")
    }
}
```

#### 3. DI Container
**File**: `vcdr/vcdr/App/AppDependencies.swift`

```swift
import SwiftUI

@Observable
final class AppDependencies {
    let settings: AppSettings

    init() {
        self.settings = AppSettings()
    }
}
```

#### 4. Update App Entry Point (Stub)
**File**: `vcdr/vcdr/vcdrApp.swift`

```swift
import SwiftUI

@main
struct vcdrApp: App {
    @State private var dependencies = AppDependencies()

    var body: some Scene {
        MenuBarExtra {
            Text("VCDR")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "waveform.circle")
        }
    }
}
```

#### 5. Delete ContentView.swift
Remove the template `ContentView.swift` — we don't need a main window, only a menu bar app.

### Success Criteria:

#### Automated Verification:
- [ ] `xcodebuild -scheme vcdr -destination 'platform=macOS' build` succeeds
- [ ] No `ContentView.swift` in source tree

#### Manual Verification:
- [ ] App launches as menu bar icon (waveform circle)
- [ ] Clicking icon shows "VCDR" and "Quit" menu items
- [ ] No main window appears on launch

---

## Phase 2: Transcription Abstraction + Parakeet

### Overview
Define the `TranscriptionProvider` protocol and implement it with FluidAudio's Parakeet v3 CoreML model.

### Changes Required:

#### 1. TranscriptionProvider Protocol
**File**: `vcdr/vcdr/Transcription/TranscriptionProvider.swift`

```swift
import Foundation

enum TranscriptionError: LocalizedError {
    case providerUnavailable
    case initializationFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            "Transcription provider is not available"
        case .initializationFailed(let message):
            "Failed to initialize transcription: \(message)"
        case .transcriptionFailed(let message):
            "Failed to transcribe audio: \(message)"
        }
    }
}

protocol TranscriptionProvider: Sendable {
    var name: String { get }
    var isReady: Bool { get }
    func initialize() async throws
    func transcribe(audioFileURL: URL) async throws -> String
}
```

#### 2. Parakeet Provider
**File**: `vcdr/vcdr/Transcription/ParakeetProvider.swift`

```swift
import Foundation
import FluidAudio
import OSLog

actor ParakeetProvider: TranscriptionProvider {
    let name = "Parakeet Multilingual v3"

    private var asr: AsrManager?
    private(set) var isReady = false

    nonisolated var isReadySync: Bool {
        // For non-async contexts — note: this is a simplification
        false // Will be properly checked via async
    }

    func initialize() async throws {
        guard !isReady else { return }
        Logger.transcription.info("Initializing Parakeet v3 CoreML model...")

        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            self.asr = manager
            self.isReady = true
            Logger.transcription.info("Parakeet v3 initialized successfully")
        } catch {
            Logger.transcription.error("Failed to initialize Parakeet: \(error)")
            throw TranscriptionError.initializationFailed(error.localizedDescription)
        }
    }

    func transcribe(audioFileURL: URL) async throws -> String {
        guard let asr else {
            throw TranscriptionError.providerUnavailable
        }

        Logger.transcription.info("Transcribing audio file: \(audioFileURL.lastPathComponent)")

        do {
            let result = try await asr.transcribe(audioFileURL, source: .system)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            Logger.transcription.info("Transcription complete: \(text.prefix(100))...")
            return text
        } catch {
            Logger.transcription.error("Transcription failed: \(error)")
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }
}
```

#### 3. Update AppDependencies
**File**: `vcdr/vcdr/App/AppDependencies.swift`

```swift
import SwiftUI
import OSLog

@Observable
final class AppDependencies {
    let settings: AppSettings
    let transcriptionProvider: ParakeetProvider

    private(set) var isTranscriptionReady = false
    private(set) var initializationStatus = "Downloading Parakeet model..."

    init() {
        self.settings = AppSettings()
        self.transcriptionProvider = ParakeetProvider()
    }

    func initializeTranscription() async {
        do {
            try await transcriptionProvider.initialize()
            isTranscriptionReady = true
            initializationStatus = "Ready"
            Logger.app.info("Transcription provider ready")
        } catch {
            initializationStatus = "Failed: \(error.localizedDescription)"
            Logger.app.error("Transcription init failed: \(error)")
        }
    }
}
```

#### 4. Update App Entry Point
Show initialization status in menu bar.

```swift
// In MenuBarExtra content:
if !dependencies.isTranscriptionReady {
    Text(dependencies.initializationStatus)
        .foregroundStyle(.secondary)
} else {
    Text("Ready")
}
```

Add `.task` modifier to trigger initialization on launch.

### Success Criteria:

#### Automated Verification:
- [ ] `xcodebuild -scheme vcdr -destination 'platform=macOS' build` succeeds
- [ ] FluidAudio imports resolve

#### Manual Verification:
- [ ] On first launch, model downloads (~1.2GB) — status shown in menu bar dropdown
- [ ] After download, status changes to "Ready"
- [ ] On subsequent launches, initialization is fast (model cached)

**Implementation Note**: First launch will take several minutes for model download. This is expected. After this phase, pause for manual confirmation that the model downloads and initializes correctly.

---

## Phase 3: Audio Recording

### Overview
Implement microphone recording using AVFoundation. Records to WAV format suitable for Parakeet transcription.

### Changes Required:

#### 1. AudioRecorder
**File**: `vcdr/vcdr/Audio/AudioRecorder.swift`

```swift
import Foundation
import AVFoundation
import OSLog

@Observable
final class AudioRecorder: NSObject {
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0.0

    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                continuation.resume(returning: true)
            case .denied, .restricted:
                continuation.resume(returning: false)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            @unknown default:
                continuation.resume(returning: false)
            }
        }
    }

    func startRecording() async -> Bool {
        guard await requestMicrophonePermission() else {
            Logger.recording.warning("Microphone permission denied")
            return false
        }

        let tempDir = FileManager.default.temporaryDirectory
        let audioFile = tempDir.appendingPathComponent("vcdr_recording_\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,       // Parakeet expects 16kHz
            AVNumberOfChannelsKey: 1,      // Mono
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: audioFile, settings: settings)
            audioRecorder?.isMeteringEnabled = true

            guard audioRecorder?.record() == true else {
                Logger.recording.error("Failed to start recording")
                return false
            }

            isRecording = true
            startLevelMonitoring()
            Logger.recording.info("Recording started: \(audioFile.lastPathComponent)")
            return true
        } catch {
            Logger.recording.error("Recording setup failed: \(error)")
            return false
        }
    }

    func stopRecording() -> URL? {
        guard let recorder = audioRecorder else { return nil }

        let url = recorder.url
        recorder.stop()
        stopLevelMonitoring()

        isRecording = false
        audioLevel = 0.0
        audioRecorder = nil

        Logger.recording.info("Recording stopped: \(url.lastPathComponent)")
        return url
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let averagePower = recorder.averagePower(forChannel: 0)
            self.audioLevel = max(0.0, (averagePower + 60) / 60)
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    deinit {
        stopLevelMonitoring()
    }
}
```

**Key difference from original**: Records at 16kHz/mono (Parakeet's native format) instead of 44.1kHz. This avoids the need for post-recording resampling.

### Success Criteria:

#### Automated Verification:
- [ ] `xcodebuild -scheme vcdr -destination 'platform=macOS' build` succeeds

#### Manual Verification:
- [ ] Microphone permission prompt appears on first recording attempt
- [ ] Recording creates a WAV file in temp directory
- [ ] Audio levels update during recording

---

## Phase 4: Global Hotkey (Push-to-Talk)

### Overview
Implement the global hotkey system using CGEvent tap. Detects both key-down and key-up events for hold-to-record behavior.

### Changes Required:

#### 1. GlobalHotkeyManager
**File**: `vcdr/vcdr/Hotkeys/GlobalHotkeyManager.swift`

```swift
import Foundation
import Carbon
import ApplicationServices
import OSLog

final class GlobalHotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var targetKeyCode: CGKeyCode = 0
    private var targetModifiers: CGEventFlags = []

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    func register(keyCode: CGKeyCode, modifiers: CGEventFlags) -> Bool {
        unregister()

        self.targetKeyCode = keyCode
        self.targetModifiers = modifiers

        guard AXIsProcessTrusted() else {
            Logger.hotkeys.warning("Accessibility permissions not granted")
            requestAccessibilityPermissions()
            return false
        }

        // Listen for both key-down and key-up
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            Logger.hotkeys.error("Failed to create event tap")
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        let display = shortcutDisplayString(keyCode: keyCode, modifiers: modifiers)
        Logger.hotkeys.info("Hotkey registered: \(display)")
        return true
    }

    func unregister() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
                self.runLoopSource = nil
            }
            self.eventTap = nil
            Logger.hotkeys.info("Hotkey unregistered")
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Logger.hotkeys.warning("Event tap disabled, re-enabling")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])

        guard keyCode == targetKeyCode && flags == targetModifiers else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            // Only fire on initial press, not key repeat
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                DispatchQueue.main.async { self.onKeyDown?() }
            }
            return nil // Consume the event
        } else if type == .keyUp {
            DispatchQueue.main.async { self.onKeyUp?() }
            return nil // Consume the event
        }

        return Unmanaged.passUnretained(event)
    }

    private func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func shortcutDisplayString(keyCode: CGKeyCode, modifiers: CGEventFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.maskControl) { parts.append("\u{2303}") }
        if modifiers.contains(.maskAlternate) { parts.append("\u{2325}") }
        if modifiers.contains(.maskShift) { parts.append("\u{21E7}") }
        if modifiers.contains(.maskCommand) { parts.append("\u{2318}") }
        parts.append(keyNameForCode(keyCode))
        return parts.joined()
    }

    private func keyNameForCode(_ keyCode: CGKeyCode) -> String {
        let names: [CGKeyCode: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M", 49: "Space",
            36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
            123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        ]
        return names[keyCode] ?? "Key\(keyCode)"
    }

    var isRegistered: Bool { eventTap != nil }

    deinit { unregister() }
}
```

**Key difference from original**: Listens for both key-down AND key-up events (original only listened for key-down). This enables hold-to-record behavior. Also filters out key repeat events to prevent re-triggering on hold.

### Success Criteria:

#### Automated Verification:
- [ ] `xcodebuild -scheme vcdr -destination 'platform=macOS' build` succeeds

#### Manual Verification:
- [ ] Accessibility permission prompt appears on first hotkey registration
- [ ] After granting permission, hotkey key-down and key-up events are detected
- [ ] Other keyboard input is not affected

---

## Phase 5: Post-Transcription Actions

### Overview
Implement the two actions that can be triggered after transcription: paste into the focused app, or run a bash command.

### Changes Required:

#### 1. Action Protocol
**File**: `vcdr/vcdr/Actions/PostTranscriptionAction.swift`

```swift
import Foundation

enum ActionError: LocalizedError {
    case accessibilityRequired
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            "Accessibility permissions required. Enable in System Settings > Privacy & Security > Accessibility."
        case .executionFailed(let message):
            "Action failed: \(message)"
        }
    }
}

protocol PostTranscriptionAction: Sendable {
    var name: String { get }
    func execute(text: String) async throws
}
```

#### 2. Paste Action
**File**: `vcdr/vcdr/Actions/PasteAction.swift`

```swift
import Foundation
import AppKit
import ApplicationServices
import OSLog

struct PasteAction: PostTranscriptionAction {
    let name = "Paste"

    func execute(text: String) async throws {
        guard AXIsProcessTrusted() else {
            throw ActionError.accessibilityRequired
        }

        // Copy text to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Logger.actions.info("Text copied to clipboard")

        // Brief delay for clipboard to settle
        try await Task.sleep(for: .milliseconds(50))

        // Simulate Cmd+V
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true) // V key
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        Logger.actions.info("Paste simulated via Cmd+V")
    }
}
```

#### 3. Bash Action
**File**: `vcdr/vcdr/Actions/BashAction.swift`

```swift
import Foundation
import OSLog

struct BashAction: PostTranscriptionAction {
    let name = "Bash Command"
    let commandTemplate: String

    func execute(text: String) async throws {
        // Replace {} with the transcribed text (shell-escaped)
        let escapedText = text.replacingOccurrences(of: "'", with: "'\\''")
        let command = commandTemplate.replacingOccurrences(of: "{}", with: "'\(escapedText)'")

        Logger.actions.info("Executing bash command: \(command.prefix(100))...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                Logger.actions.info("Command succeeded. Output: \(output.prefix(200))")
            } else {
                Logger.actions.error("Command failed with status \(process.terminationStatus): \(output)")
                throw ActionError.executionFailed("Exit code \(process.terminationStatus): \(output)")
            }
        } catch let error as ActionError {
            throw error
        } catch {
            Logger.actions.error("Failed to run command: \(error)")
            throw ActionError.executionFailed(error.localizedDescription)
        }
    }
}
```

**Note on `{}` substitution**: The transcribed text is wrapped in single quotes with internal single quotes escaped via `'\''`. For example, if the command template is `echo {}` and the text is `hello world`, the executed command becomes `echo 'hello world'`.

### Success Criteria:

#### Automated Verification:
- [ ] `xcodebuild -scheme vcdr -destination 'platform=macOS' build` succeeds

#### Manual Verification:
- [ ] PasteAction pastes text into a text editor when accessibility is granted
- [ ] BashAction runs `echo {}` and logs the output correctly
- [ ] Special characters in transcribed text don't break the bash command

---

## Phase 6: Push-to-Talk Coordinator

### Overview
Wire everything together: hotkey → record → transcribe → action. This is the central orchestrator.

### Changes Required:

#### 1. PushToTalkCoordinator
**File**: `vcdr/vcdr/Orchestration/PushToTalkCoordinator.swift`

```swift
import Foundation
import AppKit
import OSLog

@Observable
final class PushToTalkCoordinator {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case executing
        case error(String)
    }

    private(set) var state: State = .idle

    private let settings: AppSettings
    private let transcriptionProvider: ParakeetProvider
    private let audioRecorder: AudioRecorder
    private let hotkeyManager: GlobalHotkeyManager

    private var previousActiveApp: NSRunningApplication?

    init(settings: AppSettings, transcriptionProvider: ParakeetProvider) {
        self.settings = settings
        self.transcriptionProvider = transcriptionProvider
        self.audioRecorder = AudioRecorder()
        self.hotkeyManager = GlobalHotkeyManager()
    }

    func setupHotkey() {
        let keyCode = CGKeyCode(settings.hotkeyKeyCode)
        let modifiers = CGEventFlags(rawValue: settings.hotkeyModifiers)

        hotkeyManager.onKeyDown = { [weak self] in
            Task { @MainActor in
                await self?.onHotkeyDown()
            }
        }
        hotkeyManager.onKeyUp = { [weak self] in
            Task { @MainActor in
                await self?.onHotkeyUp()
            }
        }

        _ = hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
    }

    func updateHotkey() {
        setupHotkey()
    }

    private func onHotkeyDown() async {
        guard state == .idle else {
            Logger.app.warning("Hotkey pressed but not idle (state: \(String(describing: self.state)))")
            return
        }

        // Remember the currently focused app for paste action
        previousActiveApp = NSWorkspace.shared.frontmostApplication

        let started = await audioRecorder.startRecording()
        if started {
            state = .recording
            Logger.app.info("Push-to-talk: recording started")
        } else {
            state = .error("Failed to start recording")
            Logger.app.error("Push-to-talk: failed to start recording")
            resetAfterDelay()
        }
    }

    private func onHotkeyUp() async {
        guard state == .recording else { return }

        guard let audioURL = audioRecorder.stopRecording() else {
            state = .error("No audio recorded")
            resetAfterDelay()
            return
        }

        state = .transcribing
        Logger.app.info("Push-to-talk: transcribing...")

        do {
            let text = try await transcriptionProvider.transcribe(audioFileURL: audioURL)

            // Clean up audio file
            try? FileManager.default.removeItem(at: audioURL)

            guard !text.isEmpty else {
                state = .error("No speech detected")
                resetAfterDelay()
                return
            }

            state = .executing
            Logger.app.info("Push-to-talk: executing action with text: \(text.prefix(100))")

            let action = makeAction()

            // For paste action, restore focus to the previous app first
            if settings.actionType == .paste, let previousApp = previousActiveApp {
                previousApp.activate()
                try await Task.sleep(for: .milliseconds(100))
            }

            try await action.execute(text: text)
            state = .idle
            Logger.app.info("Push-to-talk: action complete")
        } catch {
            state = .error(error.localizedDescription)
            Logger.app.error("Push-to-talk failed: \(error)")
            resetAfterDelay()
        }
    }

    private func makeAction() -> any PostTranscriptionAction {
        switch settings.actionType {
        case .paste:
            PasteAction()
        case .bash:
            BashAction(commandTemplate: settings.bashCommand)
        }
    }

    private func resetAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            if case .error = state {
                state = .idle
            }
        }
    }

    var isHotkeyRegistered: Bool { hotkeyManager.isRegistered }

    var menuBarIcon: String {
        switch state {
        case .idle: "waveform.circle"
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle"
        case .executing: "arrow.right.circle"
        case .error: "exclamationmark.circle"
        }
    }
}
```

#### 2. Update AppDependencies
Add the coordinator:

```swift
@Observable
final class AppDependencies {
    let settings: AppSettings
    let transcriptionProvider: ParakeetProvider
    let coordinator: PushToTalkCoordinator

    private(set) var isTranscriptionReady = false
    private(set) var initializationStatus = "Downloading Parakeet model..."

    init() {
        let settings = AppSettings()
        let provider = ParakeetProvider()
        self.settings = settings
        self.transcriptionProvider = provider
        self.coordinator = PushToTalkCoordinator(settings: settings, transcriptionProvider: provider)
    }

    func initialize() async {
        do {
            try await transcriptionProvider.initialize()
            isTranscriptionReady = true
            initializationStatus = "Ready"
            coordinator.setupHotkey()
            Logger.app.info("App fully initialized")
        } catch {
            initializationStatus = "Failed: \(error.localizedDescription)"
            Logger.app.error("Initialization failed: \(error)")
        }
    }
}
```

#### 3. Update App Entry Point
**File**: `vcdr/vcdr/vcdrApp.swift`

```swift
import SwiftUI

@main
struct vcdrApp: App {
    @State private var dependencies = AppDependencies()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(dependencies: dependencies)
        } label: {
            Image(systemName: dependencies.coordinator.menuBarIcon)
        }

        Window("VCDR Settings", id: "settings") {
            SettingsView(dependencies: dependencies)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 450, height: 350)
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] `xcodebuild -scheme vcdr -destination 'platform=macOS' build` succeeds

#### Manual Verification:
- [ ] Hold hotkey → menu bar icon changes to filled waveform (recording)
- [ ] Release hotkey → icon changes to ellipsis (transcribing) → then back to idle
- [ ] In paste mode: transcribed text appears in the previously focused text field
- [ ] In bash mode: transcribed text is passed to the configured command
- [ ] Menu bar icon shows error state briefly if something fails

**Implementation Note**: After completing this phase and verifying the end-to-end flow works, pause for manual confirmation before proceeding to the settings UI.

---

## Phase 7: Settings UI

### Overview
Build the menu bar dropdown and settings window for configuring the hotkey, action, and bash command.

### Changes Required:

#### 1. MenuBarView
**File**: `vcdr/vcdr/UI/MenuBarView.swift`

```swift
import SwiftUI

struct MenuBarView: View {
    let dependencies: AppDependencies
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading) {
            // Status
            HStack {
                Circle()
                    .fill(dependencies.isTranscriptionReady ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(statusText)
            }

            Divider()

            // Current action
            Text("Action: \(dependencies.settings.actionType == .paste ? "Paste" : "Bash")")
                .foregroundStyle(.secondary)

            // Hotkey display
            Text("Hotkey: \(hotkeyDisplay)")
                .foregroundStyle(.secondary)

            Divider()

            Button("Settings...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Quit VCDR") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private var statusText: String {
        if !dependencies.isTranscriptionReady {
            return dependencies.initializationStatus
        }
        switch dependencies.coordinator.state {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .executing: return "Executing action..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var hotkeyDisplay: String {
        let mgr = GlobalHotkeyManager()
        return mgr.shortcutDisplayString(
            keyCode: CGKeyCode(dependencies.settings.hotkeyKeyCode),
            modifiers: CGEventFlags(rawValue: dependencies.settings.hotkeyModifiers)
        )
    }
}
```

#### 2. SettingsView
**File**: `vcdr/vcdr/UI/SettingsView.swift`

```swift
import SwiftUI

struct SettingsView: View {
    let dependencies: AppDependencies

    var body: some View {
        Form {
            // Hotkey section
            Section("Push-to-Talk Hotkey") {
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

            // Action section
            Section("After Transcription") {
                Picker("Action", selection: Binding(
                    get: { dependencies.settings.actionType },
                    set: { dependencies.settings.actionType = $0 }
                )) {
                    Text("Paste into active app").tag(PostTranscriptionActionType.paste)
                    Text("Run bash command").tag(PostTranscriptionActionType.bash)
                }
                .pickerStyle(.radioGroup)

                if dependencies.settings.actionType == .bash {
                    TextField("Command (use {} for text)", text: Binding(
                        get: { dependencies.settings.bashCommand },
                        set: { dependencies.settings.bashCommand = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .help("Use {} as placeholder for the transcribed text. Example: pbcopy <<< {}")
                }
            }

            // Status section
            Section("Status") {
                LabeledContent("Transcription") {
                    HStack {
                        Circle()
                            .fill(dependencies.isTranscriptionReady ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(dependencies.initializationStatus)
                    }
                }
                LabeledContent("Hotkey") {
                    Text(dependencies.coordinator.isHotkeyRegistered ? "Registered" : "Not registered")
                        .foregroundStyle(dependencies.coordinator.isHotkeyRegistered ? .green : .red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
    }
}
```

#### 3. ShortcutRecorderRow
**File**: `vcdr/vcdr/UI/ShortcutRecorderRow.swift`

```swift
import SwiftUI
import Carbon

struct ShortcutRecorderRow: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt64
    @State private var isRecording = false

    var body: some View {
        HStack {
            Text("Shortcut:")

            Button(action: { isRecording.toggle() }) {
                Text(isRecording ? "Press keys..." : displayString)
                    .frame(minWidth: 120)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .background(isRecording ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
            )
            .onKeyPress(phases: .down) { keyPress in
                guard isRecording else { return .ignored }

                // Convert SwiftUI key to CGKeyCode
                // This is a simplified approach — for production,
                // we'd use NSEvent monitoring
                isRecording = false
                return .handled
            }
        }
        .onAppear {
            if isRecording {
                setupEventMonitor()
            }
        }
        .onChange(of: isRecording) { _, newValue in
            if newValue {
                setupEventMonitor()
            }
        }
    }

    private var displayString: String {
        let mgr = GlobalHotkeyManager()
        return mgr.shortcutDisplayString(
            keyCode: CGKeyCode(keyCode),
            modifiers: CGEventFlags(rawValue: modifiers)
        )
    }

    private func setupEventMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }

            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            // Require at least one modifier
            guard !flags.isEmpty else { return event }

            keyCode = event.keyCode
            // Convert NSEvent modifier flags to CGEventFlags
            var cgFlags: UInt64 = 0
            if flags.contains(.command) { cgFlags |= CGEventFlags.maskCommand.rawValue }
            if flags.contains(.option) { cgFlags |= CGEventFlags.maskAlternate.rawValue }
            if flags.contains(.shift) { cgFlags |= CGEventFlags.maskShift.rawValue }
            if flags.contains(.control) { cgFlags |= CGEventFlags.maskControl.rawValue }
            modifiers = cgFlags

            isRecording = false
            return nil // Consume the event
        }
    }
}
```

#### 4. Wire up initialization in App
**File**: `vcdr/vcdr/vcdrApp.swift` — add `.task` for initialization:

```swift
@main
struct vcdrApp: App {
    @State private var dependencies = AppDependencies()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(dependencies: dependencies)
                .task {
                    await dependencies.initialize()
                }
        } label: {
            Image(systemName: dependencies.coordinator.menuBarIcon)
        }

        Window("VCDR Settings", id: "settings") {
            SettingsView(dependencies: dependencies)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 450, height: 350)
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] `xcodebuild -scheme vcdr -destination 'platform=macOS' build` succeeds

#### Manual Verification:
- [ ] Menu bar shows status (initialization progress, ready, recording, etc.)
- [ ] Settings window opens from menu bar
- [ ] Can change hotkey by clicking the shortcut recorder and pressing a new key combo
- [ ] Can switch between Paste and Bash action types
- [ ] Bash command text field appears/hides based on selected action
- [ ] Settings persist after app restart
- [ ] Full end-to-end flow works: hold hotkey → speak → release → text pasted / command run

---

## Testing Strategy

### Manual Testing Script

1. **First launch**: App downloads Parakeet model (~1.2GB). Menu bar shows progress.
2. **After init**: Menu bar icon is `waveform.circle`. Dropdown shows "Ready".
3. **Hold Cmd+Option+Space**: Icon changes to `waveform.circle.fill`. Recording starts.
4. **Speak**: Say "hello world".
5. **Release**: Icon changes to `ellipsis.circle` (transcribing), then `arrow.right.circle` (executing), then back to `waveform.circle`.
6. **Paste mode**: "hello world" (or close) appears in the focused text field.
7. **Switch to Bash**: Open Settings, select "Run bash command", set command to `echo {} > /tmp/vcdr_test.txt`.
8. **Record again**: Hold hotkey, speak, release.
9. **Verify**: `cat /tmp/vcdr_test.txt` shows the transcribed text.
10. **Change hotkey**: Open Settings, click shortcut recorder, press Cmd+Shift+R. Verify old hotkey stops working, new one works.
11. **Restart app**: Verify settings persisted (hotkey, action type, bash command).

### Edge Cases to Test
- Very short recording (< 0.5s)
- No speech detected (silence)
- Accessibility permissions not granted (should show prompt)
- Microphone permission not granted (should show prompt)
- Pressing hotkey while transcription model is still loading
- Special characters in speech (punctuation, quotes, etc.)
- Very long recording (> 30 seconds)

## Performance Considerations

- **Model download**: ~1.2GB on first launch. Consider showing a progress indicator.
- **Transcription speed**: ~110x realtime on M4 Pro. A 5-second recording should transcribe in <50ms.
- **Memory**: Parakeet model uses ~800MB RAM. This is the main memory cost.
- **Audio format**: Recording at 16kHz/mono matches Parakeet's native format, avoiding resampling overhead.

## References

- Original app architecture: `original/thoughts/shared/research/2026-02-12-glossary-and-user-flows.md`
- Original quality review: `original/thoughts/shared/research/2026-01-12-codebase-quality-review.md`
- Original rebuild plan: `original/thoughts/shared/plans/2026-01-24-vcdr-rebuild-from-scratch.md`
- FluidAudio SDK: https://github.com/FluidInference/FluidAudio
- Parakeet v3 CoreML model: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- Original GlobalHotkeyManager: `original/vcdr/Core/GlobalHotkeyManager.swift`
- Original PasteDestination: `original/vcdr/Destinations/PasteDestination.swift`
- Original AudioRecorder: `original/vcdr/Audio/AudioRecorder.swift`
