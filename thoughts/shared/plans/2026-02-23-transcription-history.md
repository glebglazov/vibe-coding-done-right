# Transcription History Implementation Plan

## Overview

Add a persistent transcription history to the VCDR app. Each transcription record captures the full text, model name, and recording duration. The history is viewable in a new "History" tab (last in the sidebar), and the latest transcription is shown in the menu bar dropdown with one-click copy to clipboard.

## Current State Analysis

- Transcription results are plain `String` — no metadata survives past `ParakeetProvider.transcribe()` (`ParakeetProvider.swift:72`)
- `RecordingCoordinator` already tracks transcription elapsed time via `ContinuousClock` (`RecordingCoordinator.swift:195`) but only logs it
- `AudioRecorder` tracks `recordingStartTime` (`AudioRecorder.swift:12`) but nils it in `stopRecording()` before the coordinator can use it
- `ParakeetProvider.name` is already `"Parakeet Multilingual v3"` (`ParakeetProvider.swift:6`)
- The main window has 4 tabs: Home, Audio, Modes, Transcription
- The menu bar dropdown shows status, mode, hotkey, settings, and quit
- No history or persistence of transcription results exists

### Key Discoveries:
- `AudioRecorder.stopRecording()` returns `URL?` — no duration info (`AudioRecorder.swift:80`)
- The coordinator's `stopRecordingAndTranscribe()` is synchronous (`RecordingCoordinator.swift:163`) — duration must be tracked in the coordinator itself
- `TranscriptionProvider` protocol has a `name: String` property — already available for model name
- `AppSettings` uses `UserDefaults` with JSON encoding — but history is a growing list, better suited to a standalone JSON file

## Desired End State

1. **History stored to disk** — JSON file in Application Support, capped at 500 entries, survives restarts
2. **History tab** — Last tab in the sidebar, shows a scrollable list of transcription records (newest first) with full text, model name, and recording duration (e.g. "0:03")
3. **Menu bar copy** — Truncated preview of latest transcription in the dropdown; clicking it copies the full text to clipboard
4. **Zero impact on existing flow** — History recording is a side effect of the existing transcription pipeline, not a change to it

### Verification:
- Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- Record a few transcriptions → entries appear in the History tab with correct model/duration
- Click latest transcription in menu bar → full text copied to clipboard
- Quit and relaunch → history persists
- Record 500+ transcriptions → oldest entries pruned

## What We're NOT Doing

- No search/filter in the history view (can add later)
- No editing or deleting individual entries
- No export functionality
- No changes to the `TranscriptionProvider` protocol (history is coordinator-level)
- No word-level timestamps from the FluidAudio result object

## Implementation Approach

Track recording duration in the coordinator (owns the state machine, knows when recording starts/stops). After successful transcription, create a `TranscriptionRecord` and append it to `TranscriptionHistory`. The history service handles persistence and pruning. UI reads from the `@Observable` history service.

---

## Phase 1: Data Model & Storage

### Overview
Create the `TranscriptionRecord` model and `TranscriptionHistory` persistence service.

### Changes Required:

#### 1. TranscriptionRecord model
**File**: `vcdr/History/TranscriptionRecord.swift` (new)

```swift
import Foundation

struct TranscriptionRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let modelName: String
    let recordingDuration: TimeInterval  // seconds
    let timestamp: Date

    init(text: String, modelName: String, recordingDuration: TimeInterval, timestamp: Date = .now) {
        self.id = UUID()
        self.text = text
        self.modelName = modelName
        self.recordingDuration = recordingDuration
        self.timestamp = timestamp
    }

    /// Formats recording duration as "M:SS" (e.g. "0:03", "1:15")
    var formattedDuration: String {
        let totalSeconds = Int(recordingDuration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}
```

#### 2. TranscriptionHistory service
**File**: `vcdr/History/TranscriptionHistory.swift` (new)

```swift
import Foundation
import OSLog

@Observable
final class TranscriptionHistory {
    private(set) var records: [TranscriptionRecord] = []

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Constants
    static let maxRecords = 500

    init(directory: URL = Self.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("history.json")
        self.records = Self.load(from: fileURL, decoder: decoder)
    }

    func addRecord(_ record: TranscriptionRecord) {
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records = Array(records.prefix(Self.maxRecords))
        }
        save()
    }

    func clearAll() {
        records.removeAll()
        save()
    }

    var latestRecord: TranscriptionRecord? {
        records.first
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try encoder.encode(records)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.app.error("Failed to save transcription history: \(error)")
        }
    }

    private static func load(from url: URL, decoder: JSONDecoder) -> [TranscriptionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([TranscriptionRecord].self, from: data)) ?? []
    }

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VCDR")
    }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] N/A — no UI yet, just data layer

---

## Phase 2: Wire History into Coordinator

### Overview
Track recording duration in the coordinator, inject `TranscriptionHistory`, and create records after successful transcription.

### Changes Required:

#### 1. AppDependencies — create and inject TranscriptionHistory
**File**: `vcdr/App/AppDependencies.swift`
**Changes**: Add `TranscriptionHistory` as a stored property, create in `init()`, inject into coordinator.

Add stored property after `mediaPlaybackController`:
```swift
let transcriptionHistory: TranscriptionHistory
```

In `init()`, create before `RecordingCoordinator`:
```swift
let history = TranscriptionHistory()
self.transcriptionHistory = history
```

Pass to coordinator:
```swift
self.coordinator = RecordingCoordinator(
    settings: settings,
    transcriptionProvider: provider,
    audioRecorder: audioRecorder,
    hotkeyManager: hotkeyManager,
    mediaPlaybackController: mediaPlayback,
    recordingIndicator: recordingIndicator,
    selectionCapturer: selectionCapturer,
    transcriptionHistory: history
)
```

#### 2. RecordingCoordinator — track duration, store records
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`
**Changes**:

Add dependency and state:
```swift
private let transcriptionHistory: TranscriptionHistory

// In stored properties:
private var recordingStartInstant: ContinuousClock.Instant?
```

Update `init` to accept `transcriptionHistory`:
```swift
init(
    settings: AppSettings,
    transcriptionProvider: any TranscriptionProvider,
    audioRecorder: AudioRecorder,
    hotkeyManager: GlobalHotkeyManager,
    mediaPlaybackController: MediaPlaybackController,
    recordingIndicator: RecordingIndicatorPanel,
    selectionCapturer: SelectionCapturer,
    transcriptionHistory: TranscriptionHistory
) {
    // ... existing assignments ...
    self.transcriptionHistory = transcriptionHistory
}
```

In `onHotkeyDown`, when recording starts (after `state = .recording` at line 134):
```swift
recordingStartInstant = .now
```

In `stopRecordingAndTranscribe`, compute duration before transitioning away from recording (after line 176 `audioRecorder.stopRecording()`):
```swift
let recordingDuration = recordingStartInstant.map { $0.duration(to: .now) }
recordingStartInstant = nil
```

Pass `recordingDuration` to `processTranscription`:
```swift
Task { @MainActor in await self.processTranscription(audioURL: audioURL, recordingDuration: recordingDuration) }
```

Update `processTranscription` signature and add history recording after successful transcription (after line 219 `action.execute`):
```swift
private func processTranscription(audioURL: URL, recordingDuration: Duration?) async {
    // ... existing code through action.execute ...

    // Record in history (raw transcription text, before mode transforms)
    let durationSeconds = recordingDuration.map {
        Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
    } ?? 0
    let record = TranscriptionRecord(
        text: text,
        modelName: transcriptionProvider.name,
        recordingDuration: durationSeconds
    )
    transcriptionHistory.addRecord(record)

    state = .idle
    // ... rest of existing code ...
}
```

Note: We store the raw `text` (pre-transform) in history, not `transformedText`. The raw transcription is what the user spoke; the transformed version includes terminators, system prompts, and selections which are action-specific artifacts.

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Record a transcription → check `~/Library/Application Support/VCDR/history.json` exists with the record

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation before proceeding to the next phase.

---

## Phase 3: History Tab UI

### Overview
Add a "History" tab as the last item in the main window sidebar, showing a scrollable list of past transcriptions.

### Changes Required:

#### 1. HistoryTabView
**File**: `vcdr/UI/HistoryTabView.swift` (new)

```swift
import SwiftUI

struct HistoryTabView: View {
    let history: TranscriptionHistory

    // MARK: - Constants
    private static let textLineLimit = 3
    private static let timestampStyle = Date.FormatStyle(
        date: .abbreviated,
        time: .shortened
    )

    var body: some View {
        Group {
            if history.records.isEmpty {
                ContentUnavailableView(
                    "No Transcriptions Yet",
                    systemImage: "text.bubble",
                    description: Text("Your transcription history will appear here.")
                )
            } else {
                List(history.records) { record in
                    HistoryRowView(record: record)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .toolbar {
            if !history.records.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear All") {
                        history.clearAll()
                    }
                }
            }
        }
    }
}

private struct HistoryRowView: View {
    let record: TranscriptionRecord

    // MARK: - Constants
    private static let textLineLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.text)
                .lineLimit(Self.textLineLimit)

            HStack(spacing: 12) {
                Label(record.modelName, systemImage: "cpu")
                Label(record.formattedDuration, systemImage: "timer")
                Label(record.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute()), systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
            }
        }
    }
}
```

#### 2. MainWindowView — add History tab
**File**: `vcdr/UI/MainWindowView.swift`

Add `case history` to the `Tab` enum (after `transcription`):
```swift
case history
```

Add to `title`:
```swift
case .history: "History"
```

Add to `systemImage`:
```swift
case .history: "clock.arrow.circlepath"
```

Add to the `switch selection` in the detail pane:
```swift
case .history:
    HistoryTabView(history: dependencies.transcriptionHistory)
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] History tab appears as last item in sidebar
- [ ] Empty state shown when no history exists
- [ ] After a few transcriptions, entries appear newest-first with correct text/model/duration
- [ ] Right-click → Copy works on individual entries
- [ ] "Clear All" button empties the list
- [ ] After restart, history is preserved

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation before proceeding to the next phase.

---

## Phase 4: Menu Bar Latest Transcription

### Overview
Add a truncated preview of the latest transcription to the menu bar dropdown. Clicking it copies the full text to clipboard.

### Changes Required:

#### 1. MenuBarView — add latest transcription section
**File**: `vcdr/UI/MenuBarView.swift`

Add between the status `HStack` and the first `Divider` (after line 14):

```swift
if let latest = dependencies.transcriptionHistory.latestRecord {
    Divider()

    Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latest.text, forType: .string)
    } label: {
        VStack(alignment: .leading) {
            Text(latest.text)
                .lineLimit(Self.previewLineLimit)
                .truncationMode(.tail)
            Text("Click to copy")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
    .buttonStyle(.plain)
}
```

Add constant:
```swift
// MARK: - Constants
private static let previewLineLimit = 2
```

### Success Criteria:

#### Automated Verification:
- [x] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] No latest transcription section when history is empty
- [ ] After a transcription, preview appears in menu bar dropdown
- [ ] Preview is truncated to 2 lines
- [ ] Clicking the preview copies full text to clipboard (verify with Cmd+V in a text editor)
- [ ] After a new transcription, preview updates to the latest one

---

## File Summary

| File | Action | Purpose |
|------|--------|---------|
| `vcdr/History/TranscriptionRecord.swift` | New | Data model for a single transcription entry |
| `vcdr/History/TranscriptionHistory.swift` | New | Persistence service with JSON file storage, capped at 500 |
| `vcdr/Orchestration/RecordingCoordinator.swift` | Modify | Track recording duration, create history records |
| `vcdr/App/AppDependencies.swift` | Modify | Create and inject `TranscriptionHistory` |
| `vcdr/UI/HistoryTabView.swift` | New | History list UI with empty state |
| `vcdr/UI/MainWindowView.swift` | Modify | Add `.history` tab case |
| `vcdr/UI/MenuBarView.swift` | Modify | Add latest transcription copy button |

## References

- Recording duration tracking: `AudioRecorder.swift:12` (existing `recordingStartTime`)
- Model name source: `ParakeetProvider.swift:6` (`name = "Parakeet Multilingual v3"`)
- Transcription pipeline: `RecordingCoordinator.swift:193-233` (`processTranscription`)
- Menu bar structure: `MenuBarView.swift:7-37`
- Tab enum: `MainWindowView.swift:6-29`
