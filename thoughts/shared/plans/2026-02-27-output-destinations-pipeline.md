# Output Destinations & Processing Pipeline Implementation Plan

## Overview

Refactor the Mode architecture from a monolithic model (bundling processing + output) into a clean pipeline: **Input → Processing → Output**. Extract "Output Destinations" as first-class entities registered independently from modes, and restructure modes to have separate Processing and Output sections.

## Current State Analysis

### Current Mode Model (`vcdr/Core/Settings/Mode.swift`)
Each Mode bundles everything together:
- `actionType: PostTranscriptionActionType` — `.paste` or `.bash`
- `bashCommand` — shell command (processing AND output)
- `pasteScriptOutput` — whether bash stdout gets pasted (output behavior)
- `systemPromptEnabled` / `systemPrompt` — prepended to text before bash
- `terminatorTemplateEnabled` / `terminatorTemplate` — appends punctuation

### Current Pipeline (`RecordingCoordinator.swift:229-238`)
```
raw text → mode.transformTranscription(text, capturedSelection)
         → makeAction() → PasteAction or BashAction
         → action.execute(transformedText)
```

`BashAction` conflates processing (transform text via script) and output (copy to clipboard, optionally paste). There's no way to run a processing script AND send output to a different destination.

### Key Discoveries:
- `BashAction.runProcess()` (`BashAction.swift:41-89`) contains reusable bash execution logic that should be extracted
- `makeAction()` exists in both `RecordingCoordinator.swift:268` and `PushToTypeCoordinator.swift:131` — both need updating
- `ModeSwitcherPanel` (`ModeSwitcherPanel.swift:107-148`) handles keyboard with number keys 1-9, arrows, j/k — output destination keys must not conflict
- `PostTranscriptionActionType` enum (`AppSettings.swift:5-8`) is used in Mode's Codable — must remain for backward-compatible decoding

## Desired End State

### Pipeline Architecture
```
Raw transcription
  → [Terminator] (if enabled in mode)
  → [System prompt prepend] (if processing == bash + system prompt enabled)
  → [Append captured selection] (if present)
  → [Processing bash script] (if processing == bash) → stdout becomes text
  → [Output Destination] (Paste: Cmd+V into app, or Bash Script: script handles output)
```

### Data Model
- **OutputDestination**: standalone entity with name, type, symbol, activation key
- **Mode**: references an OutputDestination by ID, has separate processing config
- **AppSettings**: stores `outputDestinations: [OutputDestination]` alongside `modes`

### How to Verify
- Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- Existing modes auto-migrate to new format on first launch
- Output Destinations tab appears in Settings sidebar
- Mode detail shows Processing and Output sections (not old action type picker)
- Mode switcher shows output symbols and responds to activation keys
- Pipeline executes correctly: terminator → processing → output destination

## What We're NOT Doing

- Adding new output destination types beyond Paste and Bash Script
- Changing the transcription provider or audio recording
- Modifying history/TranscriptionRecord schema (old `actionResult` field stays for backward compat)
- Adding a "Clipboard only" destination (user chose to migrate old bash-no-paste modes to Paste)
- Persisting output destination overrides (they're temporary, cleared after one transcription)

## Implementation Approach

Five phases, each independently testable:
1. Data model + migration (foundation everything else builds on)
2. Action pipeline refactor (new execution flow using new model)
3. Output Destinations settings tab (UI for managing destinations)
4. Mode detail UI updates (restructured form)
5. Mode switcher enhancement (symbols + activation keys)

---

## Phase 1: Data Model + Migration

### Overview
Create `OutputDestination` model, update `Mode` struct, add storage in `AppSettings`, and implement backward-compatible migration from the old format.

### Changes Required:

#### 1. New file: `OutputDestination.swift`
**File**: `vcdr/Core/Settings/OutputDestination.swift`
**Changes**: New file with OutputDestination struct and OutputDestinationType enum

```swift
import Foundation

enum OutputDestinationType: String, Codable, CaseIterable {
    case paste
    case bashScript

    /// Types available for user-created destinations (excludes special built-in types)
    static var userCreatable: [OutputDestinationType] {
        [.bashScript]
    }

    var displayName: String {
        switch self {
        case .paste: "Paste (Cmd+V)"
        case .bashScript: "Bash Script"
        }
    }
}

struct OutputDestination: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var type: OutputDestinationType
    var bashCommand: String
    var symbol: String
    var activationKey: String

    var isBuiltIn: Bool { type == .paste }

    // MARK: - Constants

    /// Well-known ID for the built-in Paste destination.
    /// Used for migration and as default fallback when a mode's destination is missing.
    static let builtInPasteID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func makeDefaultPaste() -> OutputDestination {
        OutputDestination(
            id: builtInPasteID,
            name: "Paste",
            type: .paste,
            bashCommand: "",
            symbol: "📋",
            activationKey: "p"
        )
    }

    static func makeNewBashScript(name: String = "New Destination") -> OutputDestination {
        OutputDestination(
            id: UUID(),
            name: name,
            type: .bashScript,
            bashCommand: "echo $VCDR_TEXT",
            symbol: "⚡",
            activationKey: ""
        )
    }
}
```

#### 2. New enum: `ProcessingType`
**File**: `vcdr/Core/Settings/Mode.swift`
**Changes**: Add ProcessingType enum at the top of the file

```swift
enum ProcessingType: String, Codable, CaseIterable {
    case none
    case bashScript
}
```

#### 3. Update Mode struct
**File**: `vcdr/Core/Settings/Mode.swift`
**Changes**: Replace `actionType`/`bashCommand`/`pasteScriptOutput` with `processingType`/`processingCommand`/`defaultOutputDestinationID`

Updated struct fields:
```swift
struct Mode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String

    // Processing
    var terminatorTemplateEnabled: Bool
    var terminatorTemplate: String
    var processingType: ProcessingType
    var processingCommand: String
    var systemPromptEnabled: Bool
    var systemPrompt: String

    // Output
    var defaultOutputDestinationID: UUID

    // ... constants, pipeline methods, etc.
}
```

Updated `transformTranscription` → rename to `applyPreProcessing` to clarify it's the pre-processing step (terminator + system prompt + selection), NOT the full processing pipeline:
```swift
/// Pre-processes transcription text by applying terminator, system prompt
/// (bash processing only), and appending any captured selection.
/// This is step 1 of the pipeline — before the optional processing script.
func applyPreProcessing(_ text: String, capturedSelection: String?) -> String {
    var result = terminatorTemplateEnabled
        ? Self.applyTerminator(text, terminator: terminatorTemplate)
        : text

    if processingType == .bashScript && systemPromptEnabled && !systemPrompt.isEmpty {
        result = systemPrompt + "\n\n" + result
    }

    if let selection = capturedSelection {
        result += "\n\n" + selection
    }

    return result
}
```

Updated init:
```swift
init(
    id: UUID,
    name: String,
    processingType: ProcessingType = .none,
    processingCommand: String = "",
    terminatorTemplateEnabled: Bool = false,
    terminatorTemplate: String = defaultTerminatorTemplate,
    systemPromptEnabled: Bool = false,
    systemPrompt: String = "",
    defaultOutputDestinationID: UUID = OutputDestination.builtInPasteID
) {
    self.id = id
    self.name = name
    self.processingType = processingType
    self.processingCommand = processingCommand
    self.terminatorTemplateEnabled = terminatorTemplateEnabled
    self.terminatorTemplate = terminatorTemplate
    self.systemPromptEnabled = systemPromptEnabled
    self.systemPrompt = systemPrompt
    self.defaultOutputDestinationID = defaultOutputDestinationID
}
```

Updated `makeDefault()`:
```swift
static func makeDefault() -> Mode {
    Mode(id: UUID(), name: "Default")
}
```

Updated backward-compatible `init(from decoder:)`:
```swift
init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    terminatorTemplateEnabled = try container.decodeIfPresent(Bool.self, forKey: .terminatorTemplateEnabled) ?? false
    terminatorTemplate = try container.decodeIfPresent(String.self, forKey: .terminatorTemplate) ?? Self.defaultTerminatorTemplate
    systemPromptEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemPromptEnabled) ?? false
    systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
    defaultOutputDestinationID = try container.decodeIfPresent(UUID.self, forKey: .defaultOutputDestinationID) ?? OutputDestination.builtInPasteID

    // New fields
    if let newProcessingType = try container.decodeIfPresent(ProcessingType.self, forKey: .processingType) {
        self.processingType = newProcessingType
        self.processingCommand = try container.decodeIfPresent(String.self, forKey: .processingCommand) ?? ""
    } else {
        // Migrate from legacy actionType + bashCommand
        let legacyActionType = try container.decodeIfPresent(PostTranscriptionActionType.self, forKey: .actionType)
        let legacyBashCommand = try container.decodeIfPresent(String.self, forKey: .bashCommand) ?? ""
        switch legacyActionType {
        case .bash:
            self.processingType = .bashScript
            self.processingCommand = legacyBashCommand
        default:
            self.processingType = .none
            self.processingCommand = ""
        }
    }
}

// CodingKeys must include both new and legacy keys for migration
private enum CodingKeys: String, CodingKey {
    case id, name
    case terminatorTemplateEnabled, terminatorTemplate
    case processingType, processingCommand
    case systemPromptEnabled, systemPrompt
    case defaultOutputDestinationID
    // Legacy keys (read-only, for migration)
    case actionType, bashCommand, pasteScriptOutput
}
```

Note: The `encode(to:)` method only writes new keys — old keys are NOT written. This means once a mode is saved in the new format, the old keys are gone. This is intentional (one-way migration).

#### 4. Update AppSettings
**File**: `vcdr/Core/Settings/AppSettings.swift`
**Changes**: Add `outputDestinations` property, key, load, and save

Add property:
```swift
var outputDestinations: [OutputDestination] {
    didSet { save() }
}
```

Add key:
```swift
static let outputDestinations = "outputDestinations"
```

Add load logic in `init()` (after modes load):
```swift
if let data = userDefaults.data(forKey: Keys.outputDestinations),
   let decoded = try? JSONDecoder().decode([OutputDestination].self, from: data),
   !decoded.isEmpty {
    self.outputDestinations = decoded
} else {
    self.outputDestinations = [OutputDestination.makeDefaultPaste()]
}
```

Add save logic in `save()`:
```swift
if let encoded = try? JSONEncoder().encode(outputDestinations) {
    userDefaults.set(encoded, forKey: Keys.outputDestinations)
}
```

Add computed helper:
```swift
/// Resolves an output destination by ID, falling back to the built-in Paste
func outputDestination(for id: UUID) -> OutputDestination {
    outputDestinations.first(where: { $0.id == id }) ?? outputDestinations.first ?? OutputDestination.makeDefaultPaste()
}
```

#### 5. Remove PostTranscriptionActionType from active use
**File**: `vcdr/Core/Settings/AppSettings.swift`
**Changes**: Keep `PostTranscriptionActionType` enum for backward-compatible Mode decoding, but it's no longer used for constructing actions. Add a comment marking it as legacy.

```swift
/// Legacy enum — kept for backward-compatible Mode decoding only.
/// New code uses ProcessingType (for text processing) and OutputDestinationType (for output).
enum PostTranscriptionActionType: String, CaseIterable, Codable {
    case paste = "paste"
    case bash = "bash"
}
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Launch app — existing modes load without crash (backward-compatible decoding)
- [ ] Check that `outputDestinations` array has the default Paste destination in UserDefaults

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 2: Action Pipeline Refactor

### Overview
Extract shared bash execution logic, create the output bash action, and update both coordinators (RecordingCoordinator + PushToTypeCoordinator) to use the new 3-step pipeline.

### Changes Required:

#### 1. New file: `BashRunner.swift`
**File**: `vcdr/Actions/BashRunner.swift`
**Changes**: Extract bash process execution from BashAction into a shared utility

```swift
import Foundation
import OSLog

/// Shared utility for running bash commands with text input via $VCDR_TEXT.
/// Used by both the processing pipeline (mode's bash script) and output
/// destinations (bash script destinations).
enum BashRunner {

    // MARK: - Constants

    private static let textPlaceholder = "{}"
    private static let textEnvironmentVariable = "VCDR_TEXT"
    private static let shellPath = "/bin/bash"

    /// Runs a bash command with the given text passed as $VCDR_TEXT environment variable.
    /// The `{}` placeholder in the command is replaced with `$VCDR_TEXT`.
    /// Returns the command's stdout as a String.
    @discardableResult
    static func run(command: String, text: String) async throws -> String {
        let resolvedCommand = command.replacingOccurrences(of: textPlaceholder, with: "$\(textEnvironmentVariable)")

        Logger.actions.info("Executing bash command")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", resolvedCommand]

        var env = ProcessInfo.processInfo.environment
        env[textEnvironmentVariable] = text
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let terminationStatus: Int32
        do {
            terminationStatus = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    continuation.resume(returning: proc.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            Logger.actions.error("Failed to run command: \(error)")
            throw ActionError.executionFailed(error.localizedDescription)
        }

        // Process has exited — readDataToEndOfFile is non-blocking at this point
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if terminationStatus == 0 {
            Logger.actions.info("Command succeeded")
            return output
        } else {
            Logger.actions.error("Command failed with status \(terminationStatus): \(output)")
            throw ActionError.executionFailed("Exit code \(terminationStatus): \(output)")
        }
    }
}
```

#### 2. New file: `OutputBashAction.swift`
**File**: `vcdr/Actions/OutputBashAction.swift`
**Changes**: Action for bash script output destinations (stdout discarded, script handles output)

```swift
import Foundation
import OSLog

/// Output action for bash script destinations.
/// The script is responsible for handling its own output — stdout is discarded.
/// No focus restoration is performed; scripts that need the previous app's focus
/// can handle that themselves (e.g., via AppleScript).
struct OutputBashAction: PostTranscriptionAction {
    let name: String
    let commandTemplate: String

    init(name: String, commandTemplate: String) {
        self.name = name
        self.commandTemplate = commandTemplate
    }

    func execute(text: String) async throws -> String? {
        // Run the output script — stdout is intentionally discarded.
        // The script handles its own output (API calls, file writes, etc.)
        try await BashRunner.run(command: commandTemplate, text: text)
        Logger.actions.info("Output bash script executed: \(name)")
        return nil
    }
}
```

#### 3. Delete `BashAction.swift`
**File**: `vcdr/Actions/BashAction.swift`
**Changes**: Delete this file entirely. Its process execution logic is now in `BashRunner.swift`, and its action behavior is split between the processing step (in coordinators) and `OutputBashAction`.

#### 4. Update RecordingCoordinator
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`
**Changes**: Add outputDestinationOverride, refactor processTranscription to 3-step pipeline, update makeAction → makeOutputAction

Add property:
```swift
/// Temporary output destination override set via mode switcher.
/// Cleared after one transcription completes (or on error/cancel).
var outputDestinationOverride: UUID?
```

Replace `processTranscription` (lines 211-266) with the new pipeline:
```swift
private func processTranscription(audioURL: URL, recordingDuration: Duration?) async {
    do {
        let transcriptionStart = ContinuousClock.now
        let text = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
        let elapsed = transcriptionStart.duration(to: .now)
        Logger.app.info("Transcribed in \(elapsed): \(text)")

        try? FileManager.default.removeItem(at: audioURL)

        guard !text.isEmpty else {
            capturedSelection = nil
            outputDestinationOverride = nil
            state = .error("No speech detected")
            recordingIndicator.update(phase: .error, message: "No speech detected")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            resetAfterDelay()
            return
        }

        let mode = settings.activeMode
        let selection = capturedSelection
        capturedSelection = nil

        // Step 1: Pre-processing (terminator, system prompt, captured selection)
        let preprocessedText = mode.applyPreProcessing(text, capturedSelection: selection)

        // Step 2: Processing (optional bash script)
        let processedText: String
        switch mode.processingType {
        case .none:
            processedText = preprocessedText
        case .bashScript:
            processedText = try await BashRunner.run(
                command: mode.processingCommand,
                text: preprocessedText
            )
        }

        state = .executing
        Logger.app.info("Pipeline: executing output action")

        // Step 3: Output (paste or bash script destination)
        let action = makeOutputAction()
        try await action.execute(text: processedText)

        // Record in history (raw transcription text, before any transforms)
        let durationSeconds = recordingDuration.map {
            Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
        } ?? 0
        let record = TranscriptionRecord(
            text: text,
            modelName: transcriptionProvider.name,
            recordingDuration: durationSeconds,
            actionResult: nil,
            capturedSelection: selection
        )
        transcriptionHistory.addRecord(record)

        state = .idle
        recordingIndicator.update(phase: .success)
        dismissIndicatorAfterDelay(Self.successIndicatorDuration)
        Logger.app.info("Pipeline: complete")
    } catch {
        capturedSelection = nil
        outputDestinationOverride = nil
        state = .error(error.localizedDescription)
        recordingIndicator.update(phase: .error, message: error.localizedDescription)
        dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
        Logger.app.error("Pipeline failed: \(error)")
        resetAfterDelay()
    }
}
```

Replace `makeAction()` (lines 268-281) with `makeOutputAction()`:
```swift
private func makeOutputAction() -> any PostTranscriptionAction {
    let mode = settings.activeMode
    let targetPID = previousActiveApp?.processIdentifier

    // Use temporary override if set, otherwise mode's default destination
    let destinationID = outputDestinationOverride ?? mode.defaultOutputDestinationID
    outputDestinationOverride = nil

    let destination = settings.outputDestination(for: destinationID)

    switch destination.type {
    case .paste:
        return PasteAction(targetAppPID: targetPID)
    case .bashScript:
        return OutputBashAction(
            name: destination.name,
            commandTemplate: destination.bashCommand
        )
    }
}
```

Also clear `outputDestinationOverride` in `cancelRecording()` (add after line 335):
```swift
outputDestinationOverride = nil
```

#### 5. Update PushToTypeCoordinator
**File**: `vcdr/Orchestration/PushToTypeCoordinator.swift`
**Changes**: Same pipeline refactor as RecordingCoordinator

Add property:
```swift
/// Temporary output destination override set via mode switcher
var outputDestinationOverride: UUID?
```

Replace `submitText` (lines 91-129) with:
```swift
private func submitText(_ text: String) {
    let mode = settings.activeMode
    let selection = capturedSelection
    capturedSelection = nil

    // Show processing indicator
    recordingIndicator.show()
    recordingIndicator.update(phase: .processing)
    Logger.app.info("Push-to-type: executing pipeline")

    Task { @MainActor in
        do {
            // Step 1: Pre-processing
            let preprocessedText = mode.applyPreProcessing(text, capturedSelection: selection)

            // Step 2: Processing (optional bash script)
            let processedText: String
            switch mode.processingType {
            case .none:
                processedText = preprocessedText
            case .bashScript:
                processedText = try await BashRunner.run(
                    command: mode.processingCommand,
                    text: preprocessedText
                )
            }

            // Step 3: Output
            let action = makeOutputAction()
            try await action.execute(text: processedText)

            // Record in history
            let record = TranscriptionRecord(
                text: text,
                modelName: "Push-to-Type",
                recordingDuration: 0,
                actionResult: nil,
                capturedSelection: selection
            )
            transcriptionHistory.addRecord(record)

            recordingIndicator.update(phase: .success)
            dismissIndicatorAfterDelay(Self.successIndicatorDuration)
            Logger.app.info("Push-to-type: complete")
        } catch {
            outputDestinationOverride = nil
            recordingIndicator.update(phase: .error, message: error.localizedDescription)
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
            Logger.app.error("Push-to-type failed: \(error)")
        }

        previousActiveApp = nil
    }
}
```

Replace `makeAction()` (lines 131-144) with `makeOutputAction()`:
```swift
private func makeOutputAction() -> any PostTranscriptionAction {
    let mode = settings.activeMode
    let targetPID = previousActiveApp?.processIdentifier

    let destinationID = outputDestinationOverride ?? mode.defaultOutputDestinationID
    outputDestinationOverride = nil

    let destination = settings.outputDestination(for: destinationID)

    switch destination.type {
    case .paste:
        return PasteAction(targetAppPID: targetPID)
    case .bashScript:
        return OutputBashAction(
            name: destination.name,
            commandTemplate: destination.bashCommand
        )
    }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Create a mode with processing type None + Paste output → transcription is pasted correctly
- [ ] Create a mode with processing type Bash Script (`echo "processed: $VCDR_TEXT"`) + Paste output → processed text is pasted
- [ ] Create a bash script output destination and a mode using it → script receives text, stdout is discarded
- [ ] Verify old modes migrated correctly still work

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 3: Output Destinations Settings Tab

### Overview
Create a new sidebar tab for managing Output Destinations with a list/detail navigation pattern matching the existing Modes tab.

### Changes Required:

#### 1. Add tab to sidebar
**File**: `vcdr/UI/MainWindowView.swift`
**Changes**: Add `.outputDestinations` case to the Tab enum and handle it in the detail view

Add enum case (after `.modes`):
```swift
case outputDestinations
```

With properties:
```swift
case .outputDestinations: "Output"      // title
case .outputDestinations: "arrow.right.square"  // systemImage
```

Add to detail view switch:
```swift
case .outputDestinations:
    OutputDestinationsListView(settings: dependencies.settings, path: $path)
```

Add navigation destination for OutputDestination UUIDs (needs a way to distinguish from Mode UUIDs — use a wrapper type):

Since both modes and output destinations use UUID for navigation, we need distinct navigation value types. Add a wrapper:
```swift
/// Navigation value for output destination detail views
struct OutputDestinationNavID: Hashable {
    let id: UUID
}
```

Add a `.navigationDestination(for: OutputDestinationNavID.self)` alongside the existing `UUID.self` destination:
```swift
.navigationDestination(for: OutputDestinationNavID.self) { navID in
    if let index = dependencies.settings.outputDestinations.firstIndex(where: { $0.id == navID.id }) {
        OutputDestinationDetailView(
            destination: Binding(
                get: { dependencies.settings.outputDestinations[index] },
                set: { dependencies.settings.outputDestinations[index] = $0 }
            )
        )
    }
}
```

#### 2. New file: `OutputDestinationsTabView.swift`
**File**: `vcdr/UI/OutputDestinationsTabView.swift`
**Changes**: List and detail views for Output Destinations

```swift
import SwiftUI

/// List of output destinations with NavigationLink rows.
/// Lives inside a NavigationStack owned by MainWindowView.
struct OutputDestinationsListView: View {
    @Bindable var settings: AppSettings
    @Binding var path: NavigationPath

    // MARK: - Constants
    private static let newDestinationBaseName = "New Destination"

    var body: some View {
        List {
            ForEach(settings.outputDestinations) { destination in
                NavigationLink(value: OutputDestinationNavID(id: destination.id)) {
                    OutputDestinationRowView(
                        destination: destination,
                        isInUse: isDestinationInUse(destination)
                    )
                }
                .contextMenu {
                    if !destination.isBuiltIn {
                        Button("Delete", role: .destructive) {
                            deleteDestination(destination)
                        }
                        .disabled(isDestinationInUse(destination))
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let dest = settings.outputDestinations[index]
                    if !dest.isBuiltIn && !isDestinationInUse(dest) {
                        deleteDestination(dest)
                    }
                }
            }
            .onMove { source, destination in
                settings.outputDestinations.move(fromOffsets: source, toOffset: destination)
            }
        }
        .navigationTitle("Output")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addDestination) {
                    Image(systemName: "plus")
                }
                .help("Add new output destination")
            }
        }
    }

    private func addDestination() {
        let newDest = OutputDestination.makeNewBashScript(
            name: nextUniqueName()
        )
        settings.outputDestinations.append(newDest)
        path.append(OutputDestinationNavID(id: newDest.id))
    }

    private func nextUniqueName() -> String {
        let existingNames = Set(settings.outputDestinations.map(\.name))
        if !existingNames.contains(Self.newDestinationBaseName) {
            return Self.newDestinationBaseName
        }
        var counter = 1
        while existingNames.contains("\(Self.newDestinationBaseName) (\(counter))") {
            counter += 1
        }
        return "\(Self.newDestinationBaseName) (\(counter))"
    }

    /// A destination is "in use" if any mode references it as its default output
    private func isDestinationInUse(_ destination: OutputDestination) -> Bool {
        settings.modes.contains { $0.defaultOutputDestinationID == destination.id }
    }

    private func deleteDestination(_ destination: OutputDestination) {
        guard !destination.isBuiltIn, !isDestinationInUse(destination) else { return }
        settings.outputDestinations.removeAll { $0.id == destination.id }
    }
}

// MARK: - Destination Row

private struct OutputDestinationRowView: View {
    let destination: OutputDestination
    let isInUse: Bool

    var body: some View {
        HStack {
            Text(destination.symbol)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading) {
                Text(destination.name)
                Text(destination.type.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !destination.activationKey.isEmpty {
                Text(destination.activationKey)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }

            if destination.isBuiltIn {
                Text("Built-in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isInUse {
                Text("In Use")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Destination Detail

struct OutputDestinationDetailView: View {
    @Binding var destination: OutputDestination
    @FocusState private var isNameFieldFocused: Bool

    // MARK: - Constants
    private static let selectAllDelay: Duration = .milliseconds(100)
    private static let maxActivationKeyLength = 1

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .foregroundStyle(.secondary)
                    TextField("Name", text: $destination.name)
                        .labelsHidden()
                        .focused($isNameFieldFocused)
                }

                if !destination.isBuiltIn {
                    // Type is not editable for built-in destinations
                    // Currently only shows "Bash Script" since that's the only user-creatable type
                    Picker("Type", selection: $destination.type) {
                        ForEach(OutputDestinationType.userCreatable, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Symbol")
                        .foregroundStyle(.secondary)
                    TextField("Symbol", text: $destination.symbol)
                        .labelsHidden()
                        .help("Displayed in the mode switcher to identify this destination")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Activation Key")
                        .foregroundStyle(.secondary)
                    TextField("Key", text: $destination.activationKey)
                        .labelsHidden()
                        .onChange(of: destination.activationKey) { _, newValue in
                            // Enforce single character limit
                            if newValue.count > Self.maxActivationKeyLength {
                                destination.activationKey = String(newValue.prefix(Self.maxActivationKeyLength))
                            }
                        }
                        .help("Press this key in the mode switcher to override the output destination")
                }

                if destination.type == .bashScript {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command")
                            .foregroundStyle(.secondary)
                        TextField("Command", text: $destination.bashCommand)
                            .labelsHidden()
                            .help("The script receives text via $VCDR_TEXT. Use {} as placeholder.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(destination.name)
        .onAppear {
            isNameFieldFocused = true
            Task { @MainActor in
                try? await Task.sleep(for: Self.selectAllDelay)
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] "Output" tab appears in Settings sidebar between Modes and Transcription
- [ ] Built-in Paste destination appears and cannot be deleted (no delete context menu, swipe-delete is no-op)
- [ ] Built-in Paste destination allows editing name, symbol, and activation key — but NOT type
- [ ] Can add a new bash script destination via "+" button
- [ ] Can edit destination name, symbol, activation key, and command
- [ ] Activation key field enforces single character limit
- [ ] A destination referenced by any mode shows "In Use" badge and cannot be deleted (context menu disabled, swipe-delete is no-op)
- [ ] A destination not referenced by any mode can be deleted
- [ ] Can reorder destinations via drag

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 4: Mode Detail UI Updates

### Overview
Restructure the ModeDetailView form into Processing and Output sections, replacing the old action type picker and bash command fields.

### Changes Required:

#### 1. Update ModeDetailView
**File**: `vcdr/UI/ModesTabView.swift`
**Changes**: Replace the entire form content in ModeDetailView with Processing + Output sections

```swift
struct ModeDetailView: View {
    @Binding var mode: Mode
    let outputDestinations: [OutputDestination]
    @FocusState private var isNameFieldFocused: Bool

    // MARK: - Constants

    private static let selectAllDelay: Duration = .milliseconds(100)

    var body: some View {
        Form {
            // Name section
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .foregroundStyle(.secondary)
                    TextField("Name", text: $mode.name)
                        .labelsHidden()
                        .focused($isNameFieldFocused)
                }
            }

            // Processing section
            Section("Processing") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Append terminator template", isOn: $mode.terminatorTemplateEnabled)

                    if mode.terminatorTemplateEnabled {
                        TextField("Terminator template", text: $mode.terminatorTemplate)
                            .labelsHidden()
                            .help("Appended after transcription if it doesn't end with punctuation. Tokens: <dot>, <space>, <newline>.")
                    }
                }

                Picker("Processing", selection: $mode.processingType) {
                    Text("None").tag(ProcessingType.none)
                    Text("Bash Script").tag(ProcessingType.bashScript)
                }
                .pickerStyle(.radioGroup)

                if mode.processingType == .bashScript {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command")
                            .foregroundStyle(.secondary)
                        TextField("Command", text: $mode.processingCommand)
                            .labelsHidden()
                            .help("Use {} as placeholder for transcribed text. Text also available as $VCDR_TEXT.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Include system prompt in $VCDR_TEXT", isOn: $mode.systemPromptEnabled)

                        if mode.systemPromptEnabled {
                            TextEditor(text: $mode.systemPrompt)
                                .font(.body)
                                .frame(minHeight: 80)
                                .border(Color.secondary.opacity(0.3))
                                .help("This text is prepended to $VCDR_TEXT before the transcribed text")
                        }
                    }
                }
            }

            // Output section
            Section("Output") {
                Picker("Default output destination", selection: $mode.defaultOutputDestinationID) {
                    ForEach(outputDestinations) { destination in
                        HStack {
                            Text(destination.symbol)
                            Text(destination.name)
                        }
                        .tag(destination.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mode.name)
        .onAppear {
            isNameFieldFocused = true
            Task { @MainActor in
                try? await Task.sleep(for: Self.selectAllDelay)
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }
}
```

#### 2. Update ModeDetailView instantiation
**File**: `vcdr/UI/MainWindowView.swift`
**Changes**: Pass outputDestinations to ModeDetailView in the navigationDestination

```swift
.navigationDestination(for: UUID.self) { modeID in
    if let index = dependencies.settings.modes.firstIndex(where: { $0.id == modeID }) {
        ModeDetailView(
            mode: Binding(
                get: { dependencies.settings.modes[index] },
                set: { dependencies.settings.modes[index] = $0 }
            ),
            outputDestinations: dependencies.settings.outputDestinations
        )
    }
}
```

#### 3. Update ModeRowView subtitle
**File**: `vcdr/UI/ModesTabView.swift`
**Changes**: Update the subtitle in ModeRowView to show processing type and output destination name instead of old "Paste"/"Script"

The ModeRowView needs access to outputDestinations to resolve the destination name. Pass it through:
```swift
private struct ModeRowView: View {
    let mode: Mode
    let isActive: Bool
    let outputDestinationName: String

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(mode.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        let processing = mode.processingType == .bashScript ? "Script" : "Direct"
        return "\(processing) → \(outputDestinationName)"
    }
}
```

Update the ForEach in ModesListView to pass the resolved name:
```swift
ModeRowView(
    mode: mode,
    isActive: mode.id == settings.activeModeID,
    outputDestinationName: settings.outputDestination(for: mode.defaultOutputDestinationID).name
)
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Mode detail shows "Processing" section with terminator + processing type picker
- [ ] Selecting "Bash Script" processing reveals command + system prompt fields
- [ ] Mode detail shows "Output" section with destination dropdown
- [ ] Dropdown lists all registered output destinations with symbols
- [ ] Changing output destination persists correctly
- [ ] Mode list rows show updated subtitles (e.g., "Direct → Paste", "Script → My Dest")

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 5: Mode Switcher Enhancement

### Overview
Update the mode switcher panel to display output destination symbols alongside modes, and add activation key support for temporary output destination overrides.

### Changes Required:

#### 1. Update ModeSwitcherCoordinator
**File**: `vcdr/Orchestration/ModeSwitcherCoordinator.swift`
**Changes**: Pass output destinations and override callback to the panel

The coordinator needs references to the coordinators that hold `outputDestinationOverride`. Since the coordinator is wired in AppDependencies, we need to pass the override targets.

Add properties:
```swift
/// Callback to set a temporary output destination override on the active coordinators
var onOutputDestinationOverride: ((UUID) -> Void)?
```

Update `showSwitcher()`:
```swift
func showSwitcher() {
    guard !settings.modes.isEmpty else { return }
    panel.show(
        modes: settings.modes,
        activeModeID: settings.activeModeID,
        outputDestinations: settings.outputDestinations,
        onSelect: { [weak self] id in
            guard let self else { return }
            self.settings.activeModeID = id
            Logger.settings.info("Mode switched to \(id)")
        },
        onOutputDestinationSelect: { [weak self] destinationID in
            guard let self else { return }
            self.onOutputDestinationOverride?(destinationID)
            Logger.settings.info("Output destination override set to \(destinationID)")
        }
    )
}
```

#### 2. Wire override callback in AppDependencies
**File**: `vcdr/App/AppDependencies.swift`
**Changes**: After creating coordinators, set the override callback

Add after the modeSwitcherCoordinator creation (around line 54):
```swift
modeSwitcherCoordinator.onOutputDestinationOverride = { [weak self] destinationID in
    self?.coordinator.outputDestinationOverride = destinationID
    self?.pushToTypeCoordinator.outputDestinationOverride = destinationID
}
```

#### 3. Update ModeSwitcherPanel
**File**: `vcdr/UI/ModeSwitcherPanel.swift`
**Changes**: Add output destinations section, update keyboard handling, show symbols

Update `show()` signature:
```swift
func show(
    modes: [Mode],
    activeModeID: UUID,
    outputDestinations: [OutputDestination],
    onSelect: @escaping (UUID) -> Void,
    onOutputDestinationSelect: @escaping (UUID) -> Void
)
```

Update panel height calculation to account for output destinations section:
```swift
let destinationRows = outputDestinations.count
let hasSeparator = !outputDestinations.isEmpty
let separatorHeight: CGFloat = hasSeparator ? Self.separatorHeight : 0
let totalRows = modes.count + destinationRows
let panelHeight = Self.verticalPadding * 2 + Self.rowHeight * CGFloat(totalRows) + separatorHeight
```

Add constant:
```swift
private static let separatorHeight: CGFloat = 17
```

Update viewModel construction to include output destinations:
```swift
let viewModel = ModeSwitcherViewModel(
    modes: modes,
    highlightedIndex: activeIndex,
    outputDestinations: outputDestinations,
    onSelect: { [weak self] id in
        onSelect(id)
        self?.hide()
    },
    onOutputDestinationSelect: { [weak self] id in
        onOutputDestinationSelect(id)
        self?.hide()
    },
    onDismiss: { [weak self] in
        self?.hide()
    }
)
```

#### 4. Update ModeSwitcherViewModel
**File**: `vcdr/UI/ModeSwitcherPanel.swift`
**Changes**: Add output destinations support and key handling

```swift
@Observable
private final class ModeSwitcherViewModel {
    let modes: [Mode]
    var highlightedIndex: Int
    let outputDestinations: [OutputDestination]
    let onSelect: (UUID) -> Void
    let onOutputDestinationSelect: (UUID) -> Void
    let onDismiss: () -> Void

    init(
        modes: [Mode],
        highlightedIndex: Int,
        outputDestinations: [OutputDestination],
        onSelect: @escaping (UUID) -> Void,
        onOutputDestinationSelect: @escaping (UUID) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.modes = modes
        self.highlightedIndex = highlightedIndex
        self.outputDestinations = outputDestinations
        self.onSelect = onSelect
        self.onOutputDestinationSelect = onOutputDestinationSelect
        self.onDismiss = onDismiss
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let chars = event.charactersIgnoringModifiers ?? ""

        switch keyCode {
        case 125, 38: // Down arrow, J
            highlightedIndex = min(highlightedIndex + 1, modes.count - 1)
            return true
        case 126, 40: // Up arrow, K
            highlightedIndex = max(highlightedIndex - 1, 0)
            return true
        case 36: // Return
            onSelect(modes[highlightedIndex].id)
            return true
        case 53: // Escape
            onDismiss()
            return true
        default:
            // Number keys 1-9 for modes
            if let number = chars.first?.wholeNumberValue,
               number >= 1, number <= modes.count {
                onSelect(modes[number - 1].id)
                return true
            }
            // Output destination activation keys
            if let char = chars.first {
                let key = String(char)
                if let destination = outputDestinations.first(where: { $0.activationKey == key }) {
                    onOutputDestinationSelect(destination.id)
                    return true
                }
            }
            return false
        }
    }
}
```

#### 5. Update ModeSwitcherView
**File**: `vcdr/UI/ModeSwitcherPanel.swift`
**Changes**: Show output destination symbols on mode rows + destinations section at bottom

```swift
private struct ModeSwitcherView: View {
    let viewModel: ModeSwitcherViewModel

    // MARK: - Constants

    private static let cornerRadius: CGFloat = 10
    private static let rowCornerRadius: CGFloat = 6
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 6

    var body: some View {
        VStack(spacing: 2) {
            // Modes section
            ForEach(Array(viewModel.modes.enumerated().prefix(9)), id: \.element.id) { index, mode in
                modeRow(index: index, mode: mode)
                    .onHover { hovering in
                        if hovering { viewModel.highlightedIndex = index }
                    }
                    .onTapGesture { viewModel.onSelect(mode.id) }
            }

            // Output destinations section
            if !viewModel.outputDestinations.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                ForEach(viewModel.outputDestinations) { destination in
                    destinationRow(destination: destination)
                        .onTapGesture {
                            viewModel.onOutputDestinationSelect(destination.id)
                        }
                }
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    private func modeRow(index: Int, mode: Mode) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(mode.name)
                .lineLimit(1)

            Spacer()

            // Show the mode's default output destination symbol
            let destination = viewModel.outputDestinations.first(where: { $0.id == mode.defaultOutputDestinationID })
            Text(destination?.symbol ?? "")
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Self.rowCornerRadius)
                .fill(index == viewModel.highlightedIndex ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func destinationRow(destination: OutputDestination) -> some View {
        HStack(spacing: 8) {
            Text(destination.activationKey.isEmpty ? " " : destination.activationKey)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(destination.symbol)

            Text(destination.name)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
```

#### 6. Update ModeSwitcherCoordinator.toggleSwitcher default
**File**: `vcdr/Orchestration/ModeSwitcherCoordinator.swift`
**Changes**: No additional changes needed — the existing `toggleSwitcher()` calls `showSwitcher()` which now passes output destinations.

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Mode switcher shows output destination symbols next to each mode name
- [ ] Output destinations section appears below modes with a separator
- [ ] Each destination shows its activation key and symbol
- [ ] Pressing an activation key in the mode switcher dismisses it and sets a temporary override
- [ ] The temporary override applies to the next transcription only (verify with 2 consecutive transcriptions)
- [ ] Number keys still select modes correctly
- [ ] Arrow keys and j/k still navigate modes
- [ ] Return still confirms mode selection
- [ ] Escape still dismisses

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Testing Strategy

### Integration Testing:
1. **Migration path**: Start with old-format UserDefaults data, launch app, verify modes decode correctly with new fields
2. **Full pipeline**: Record → transcribe → processing script → output destination paste → text appears in target app
3. **Temporary override**: Set override via mode switcher → next transcription uses override → following transcription uses mode default
4. **Destination deletion cascade**: Delete an output destination → all modes referencing it fall back to Paste

### Manual Testing Steps:
1. Fresh launch — default Paste destination exists, default mode points to it
2. Create a bash script output destination (e.g., `osascript -e 'display notification "$VCDR_TEXT"'`)
3. Create a mode with processing type None + the bash script destination
4. Record and verify the notification appears
5. Create a mode with bash processing (`echo "processed: $VCDR_TEXT"`) + Paste output
6. Record and verify "processed: [text]" is pasted
7. Open mode switcher, press the destination activation key, record, verify override works
8. Record again without mode switcher — verify it uses mode default (no override)

## Performance Considerations

- `BashRunner.run()` creates a new `Process` per invocation — same as current behavior, no regression
- Processing bash script adds one process spawn to the pipeline; output bash script adds another. Maximum 2 process spawns per transcription (was 1 max before)
- Mode switcher panel height calculation now accounts for output destinations — slightly taller panel but negligible
- `outputDestination(for:)` does a linear scan of destinations array — fine for typical counts (< 20)

## Migration Notes

- **One-way migration**: Old Mode format (with `actionType`/`bashCommand`/`pasteScriptOutput`) is read via backward-compatible `init(from:)`. Once saved in new format, old keys are dropped.
- **All existing modes get Paste as default output**: `defaultOutputDestinationID` defaults to `OutputDestination.builtInPasteID` during migration.
- **Old bash modes become processing**: `actionType: .bash` migrates to `processingType: .bashScript` with the same command.
- **No data loss**: The well-known Paste UUID ensures references are stable across app launches.

## References

- Current Mode model: `vcdr/Core/Settings/Mode.swift`
- Current actions: `vcdr/Actions/PasteAction.swift`, `vcdr/Actions/BashAction.swift`
- Current coordinator pipeline: `vcdr/Orchestration/RecordingCoordinator.swift:211-266`
- Current mode switcher: `vcdr/UI/ModeSwitcherPanel.swift`
- Mode detail UI: `vcdr/UI/ModesTabView.swift:114-187`
