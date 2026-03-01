---
date: 2026-02-28T00:00:00+00:00
researcher: Claude
git_commit: e8eaf318a40cab4ebaf85a9216583d53cc9274dd
branch: main
repository: vibe-coding-done-right
topic: "Testing strategy, structure, and feasibility for VCDR"
tags: [research, testing, swift-testing, xctest, testability, architecture]
status: complete
last_updated: 2026-02-28
last_updated_by: Claude
---

# Research: Testing Strategy, Structure, and Feasibility for VCDR

**Date**: 2026-02-28
**Researcher**: Claude
**Git Commit**: e8eaf318a40cab4ebaf85a9216583d53cc9274dd
**Branch**: main
**Repository**: vibe-coding-done-right

## Research Question

Should we write tests for the app? How to structure them? What layers are testable? How to run Swift tests?

## Summary

The app has excellent testability foundations — protocol-based DI, clear separation of concerns, and substantial pure logic in `Mode.swift`, `AppSettings.swift`, and the coordinator state machines. The test targets already exist (`vcdrTests` using Swift Testing, `vcdrUITests` using XCTest) but contain only Xcode boilerplate. The highest-value tests require zero mocking: `Mode.applyTerminator`, `Mode.applyPreProcessing`, settings migration, and data model logic. Coordinator tests require mock protocols (two already exist: `TranscriptionProvider`, `PostTranscriptionAction`). System boundaries (CGEvent, AVFoundation, NSPasteboard) should not be unit tested directly.

## Detailed Findings

### Current Test Infrastructure

Both test targets exist in `vcdr.xcodeproj` and are wired correctly:

- **`vcdrTests/vcdrTests.swift`** — Uses `import Testing` (Swift Testing framework). Contains one empty `@Test func example()`.
- **`vcdrUITests/vcdrUITests.swift`** — Uses `import XCTest`. Contains boilerplate `XCUIApplication().launch()`.
- **`vcdrUITests/vcdrUITestsLaunchTests.swift`** — Screenshot capture on launch, no assertions.

No actual test logic, mocks, or test utilities exist anywhere in the project.

### Framework Choice: Swift Testing vs XCTest

**Use Swift Testing (`import Testing`) for all new unit tests.** It's Apple's recommended framework as of Xcode 16 (WWDC 2024). The project's `vcdrTests` target already imports it.

**Keep XCTest only for:** UI automation (`XCUIApplication`) and performance tests (`XCTMetric`) — Swift Testing has no equivalents for these.

Key syntax:

| Concept | Swift Testing |
|---|---|
| Import | `import Testing` |
| Suite | `@Suite struct ModeTests` |
| Test | `@Test func applyTerminatorAppended()` |
| Assert | `#expect(result == "Hello. ")` |
| Unwrap | `try #require(optional)` |
| Parameterized | `@Test(arguments: [".", "?", "!"])` |
| Async | `@Test func something() async throws` |

### What's Worth Testing — By Layer

#### Layer 1: Pure Logic (Highest Value, Zero Mocking)

These functions take strings/values in and return strings/values out. No system dependencies.

| Function | File | What It Does |
|---|---|---|
| `Mode.applyTerminator(_:terminator:)` | `Mode.swift:59-81` | Template token resolution, punctuation dedup |
| `Mode.applyPreProcessing(_:capturedSelection:followUpContext:)` | `Mode.swift:34-53` | Text pipeline assembly (terminator → follow-up → system prompt → selection) |
| `AppSettings.activeMode` | `AppSettings.swift:73-75` | Mode lookup with fallback chain |
| `AppSettings.outputDestination(for:)` | `AppSettings.swift:78-80` | Destination lookup with fallback |
| `TranscriptionRecord.fullCapture` | `TranscriptionRecord.swift:33-38` | Text + selection concatenation |
| `TranscriptionRecord.formattedDuration` | `TranscriptionRecord.swift:41-46` | Seconds → "M:SS" formatting |
| `OutputDestination.isBuiltIn` | `OutputDestination.swift:30` | Type check for paste/outputPanel |
| `OutputDestinationType.userCreatable` | `OutputDestination.swift:9-11` | Subset filtering |
| `HotkeyBinding.isAssigned` | `AppSettings.swift:34-36` | Non-zero check |
| `TranscriptionHistory.addRecord` | `TranscriptionHistory.swift:20-26` | Insert-at-0 + cap enforcement |
| `OutputPanelPanel.calculateHeight(for:)` | `OutputPanelPanel.swift:123-128` | Line count → clamped height |

#### Layer 2: Settings Migration (High Value, Uses UserDefaults Seam)

`AppSettings.init(userDefaults:)` accepts a `UserDefaults` parameter (defaults to `.standard`). Tests can pass an in-memory `UserDefaults(suiteName:)` to verify:
- Push-to-talk hotkey migration from legacy keys
- Modes migration from legacy `actionType`/`bashCommand`
- Output destinations forward migration (adding built-in Output Panel)
- `Mode` Codable backward-compatible decoding

#### Layer 3: Coordinator State Machine (Medium Value, Needs Mocks)

`RecordingCoordinator` has a well-defined state machine: `idle → recording → transcribing → executing → idle` with error branches. Testing transitions is valuable but requires mocking:
- `TranscriptionProvider` — protocol already exists, easy to mock
- `PostTranscriptionAction` — protocol already exists, easy to mock
- `AudioRecorder` — concrete class, needs protocol extraction (`AudioRecording`)
- `RecordingIndicatorPanel`, `OutputPanelPanel` — concrete classes, need protocol extraction or restructuring

#### Layer 4: System Boundaries (Do NOT Unit Test)

| Component | Why Not |
|---|---|
| `GlobalHotkeyManager` (CGEvent tap) | Requires accessibility permissions + run loop |
| `AudioRecorder` (AVFoundation) | Requires mic hardware |
| `PasteAction` (NSPasteboard + CGEvent) | Requires accessibility + clipboard |
| `SelectionCapturer` (AX API) | Requires accessibility permissions |
| `ParakeetProvider` (CoreML) | Requires 1.2GB model download |
| SwiftUI views | Test state machines that drive them instead |

### How to Run Tests

**Run all unit tests:**
```bash
xcodebuild test \
  -project vcdr.xcodeproj \
  -scheme vcdr \
  -destination 'platform=macOS' \
  -only-testing vcdrTests
```

**Run a specific suite:**
```bash
xcodebuild test \
  -project vcdr.xcodeproj \
  -scheme vcdr \
  -destination 'platform=macOS' \
  -only-testing vcdrTests/ModeTests
```

**Run a single test:**
```bash
xcodebuild test \
  -project vcdr.xcodeproj \
  -scheme vcdr \
  -destination 'platform=macOS' \
  -only-testing 'vcdrTests/ModeTests/applyTerminatorAppended'
```

**Skip UI tests (faster):**
```bash
xcodebuild test \
  -project vcdr.xcodeproj \
  -scheme vcdr \
  -destination 'platform=macOS' \
  -skip-testing vcdrUITests
```

### Recommended Test Structure

```
vcdrTests/
├── Core/
│   └── Settings/
│       ├── ModeTests.swift              # applyTerminator, applyPreProcessing
│       ├── AppSettingsTests.swift        # activeMode, migration, persistence
│       └── OutputDestinationTests.swift  # isBuiltIn, userCreatable, factories
├── History/
│   ├── TranscriptionRecordTests.swift   # fullCapture, formattedDuration
│   └── TranscriptionHistoryTests.swift  # addRecord cap, latestRecord
├── Actions/
│   └── BashRunnerTests.swift            # Integration: real shell execution
├── Orchestration/
│   └── RecordingCoordinatorTests.swift  # State transitions (requires mocks)
├── Mocks/
│   ├── MockTranscriptionProvider.swift
│   └── MockPostTranscriptionAction.swift
└── UI/
    └── OutputPanelTests.swift           # calculateHeight
```

### Existing Protocol Seams (Ready for Mocking)

| Protocol | File | Methods |
|---|---|---|
| `TranscriptionProvider` | `TranscriptionProvider.swift:20-25` | `name`, `isReady`, `initialize()`, `transcribe(audioFileURL:)` |
| `PostTranscriptionAction` | `PostTranscriptionAction.swift:17-21` | `name`, `execute(text:)` |

### Injectable Seams That Need Protocol Extraction (For Coordinator Tests)

| Concrete Class | Suggested Protocol | Used By |
|---|---|---|
| `AudioRecorder` | `AudioRecording` | `RecordingCoordinator` |
| `RecordingIndicatorPanel` | `RecordingIndicatorPresenting` | `RecordingCoordinator`, `PushToTypeCoordinator` |
| `OutputPanelPanel` | `OutputPresenting` | `RecordingCoordinator`, `PushToTypeCoordinator` |

## Code References

- `vcdr/Core/Settings/Mode.swift:34-81` — Pure text pipeline logic (highest test value)
- `vcdr/Core/Settings/AppSettings.swift:73-80` — Pure lookup logic
- `vcdr/Core/Settings/AppSettings.swift:104-218` — Migration logic with `UserDefaults` seam
- `vcdr/Core/Settings/OutputDestination.swift:9-72` — Pure data model logic
- `vcdr/History/TranscriptionRecord.swift:33-46` — Pure computed properties
- `vcdr/History/TranscriptionHistory.swift:15-60` — File-backed history with injectable `directory`
- `vcdr/Orchestration/RecordingCoordinator.swift:7-13` — State enum definition
- `vcdr/Orchestration/RecordingCoordinator.swift:47-67` — DI init with protocol seam
- `vcdr/Actions/BashRunner.swift:19-64` — Testable with real shell (integration)
- `vcdr/UI/OutputPanelPanel.swift:123-128` — Pure height calculation
- `vcdrTests/vcdrTests.swift` — Existing boilerplate, ready to extend

## Historical Context (from thoughts/)

- `thoughts/shared/research/2026-02-21-dictate-transcribe-process-act-risks.md` — Identified `AudioRecorder`, `GlobalHotkeyManager`, `RecordingIndicatorPanel`, and `SelectionCapturer` as not mockable due to concrete class injection
- `thoughts/shared/research/2026-02-21-text-based-mode-simulation.md` — Proposed text-based simulation mode to enable pipeline testing without audio hardware
- `thoughts/shared/research/2026-02-20-vcdr-architecture-and-swift-fundamentals.md` — Canonical reference for DI and protocol-oriented design rationale; references `MockTranscriptionProvider` as testability example
- All implementation plans contain "Testing Strategy" sections that describe manual verification steps; no automated test suite has been implemented yet

## Open Questions

- Should `BashRunner` tests execute real shell commands (integration-style) or should it be wrapped in a `BashExecuting` protocol for mocking?
- Is it worth extracting `AudioRecording`/`RecordingIndicatorPresenting`/`OutputPresenting` protocols now to enable coordinator state machine tests, or wait until those tests are actually needed?
- Should CI be set up to run `xcodebuild test` on every commit?
