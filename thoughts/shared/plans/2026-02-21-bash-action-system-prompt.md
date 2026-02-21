# Bash Action System Prompt — Implementation Plan

## Overview

Add a per-mode "System prompt" option for the Custom script action. When enabled via a checkbox, a textarea appears where the user writes a system prompt that gets prepended to `$VCDR_TEXT` at execution time.

## Current State Analysis

- `Mode` struct stores per-mode settings including `bashCommand`, `terminatorTemplateEnabled`, and `terminatorTemplate`
- The terminator feature follows the exact pattern we need: a `Bool` toggle + `String` value, with backward-compatible `Codable` decoding
- `RecordingCoordinator.processTranscription()` applies the terminator to text before passing it to the action
- `ModeDetailView` conditionally shows the bash command field when `actionType == .bash`

### Key Discoveries:
- Terminator pattern at `Mode.swift:8-9` is the model for our new fields
- Backward-compatible decoding at `Mode.swift:48-49` shows how to add fields without breaking existing data
- Text transformation chain in `RecordingCoordinator.swift:159-162` is where we'll add system prompt prepending
- UI conditional display at `ModesTabView.swift:114-118` shows the pattern for bash-specific UI

## Desired End State

When editing a mode with "Custom script" action type, a "System prompt" checkbox appears below the command field. When checked, a multi-line textarea appears. At execution time, if enabled and non-empty, the system prompt is prepended to `$VCDR_TEXT` with a newline separator.

### Verification:
1. Create a mode with Custom script action, enable system prompt, type "You are a helpful assistant"
2. Record audio → the `$VCDR_TEXT` env var should contain "You are a helpful assistant\n<transcribed text>"
3. Disable the checkbox → `$VCDR_TEXT` should contain only the transcribed text
4. Quit and relaunch → system prompt settings should persist
5. Existing modes without system prompt should load without issues (backward compat)

## What We're NOT Doing

- No separate `$VCDR_SYSTEM_PROMPT` environment variable — the user asked for it prepended to `$VCDR_TEXT`
- No system prompt for paste action — only applies to bash/custom script
- No template tokens or placeholders in the system prompt text — it's literal text

## Implementation Approach

Follow the terminator feature pattern exactly: add two fields to `Mode`, show them conditionally in the UI, and apply the transformation in `RecordingCoordinator`.

## Phase 1: Data Model

### Changes Required:

#### 1. Mode struct
**File**: `vcdr/Core/Settings/Mode.swift`

Add two new stored properties after `terminatorTemplate`:

```swift
var systemPromptEnabled: Bool
var systemPrompt: String
```

Update `makeDefault()` — defaults are `false` and `""` (handled by init default params).

Update `init(...)` with default parameter values:

```swift
systemPromptEnabled: Bool = false,
systemPrompt: String = ""
```

Update `init(from decoder:)` with backward-compatible decoding:

```swift
systemPromptEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemPromptEnabled) ?? false
systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

---

## Phase 2: UI

### Changes Required:

#### 1. ModeDetailView
**File**: `vcdr/UI/ModesTabView.swift`

Inside the `Section("Action")` block, after the bash command `TextField` (line 117), add the system prompt toggle and textarea — still within the `if mode.actionType == .bash` guard:

```swift
if mode.actionType == .bash {
    TextField("Command (use {} for text)", text: $mode.bashCommand)
        .textFieldStyle(.roundedBorder)
        .help("Use {} as placeholder for transcribed text")

    Toggle("Include system prompt in $VCDR_TEXT", isOn: $mode.systemPromptEnabled)

    if mode.systemPromptEnabled {
        TextEditor(text: $mode.systemPrompt)
            .font(.body)
            .frame(minHeight: 80)
            .border(Color.secondary.opacity(0.3))
            .help("This text is prepended to $VCDR_TEXT before the transcribed text")
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] In mode detail, selecting "Custom script" shows the system prompt checkbox
- [ ] Checking the box reveals a textarea
- [ ] Unchecking the box hides the textarea
- [ ] Selecting "Paste (Cmd+V)" hides both the command field and system prompt
- [ ] Text entered in the textarea persists when navigating away and back

---

## Phase 3: Execution Logic

### Changes Required:

#### 1. RecordingCoordinator
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

In `processTranscription(audioURL:)`, after the terminator is applied (line 162) and before `state = .executing` (line 164), add system prompt prepending:

```swift
let terminatedText = mode.terminatorTemplateEnabled
    ? Self.applyTerminator(text, terminator: mode.terminatorTemplate)
    : text

let finalText = (mode.actionType == .bash && mode.systemPromptEnabled && !mode.systemPrompt.isEmpty)
    ? mode.systemPrompt + "\n\n" + terminatedText
    : terminatedText
```

Then replace `terminatedText` with `finalText` in the `action.execute(text:)` call on line 176:

```swift
try await action.execute(text: finalText)
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] With system prompt enabled and set to "System: You are a translator", record speech → `$VCDR_TEXT` contains "System: You are a translator\n<transcribed text>"
- [ ] With system prompt disabled, record speech → `$VCDR_TEXT` contains only the transcribed text
- [ ] With system prompt enabled but empty string, record speech → `$VCDR_TEXT` contains only the transcribed text
- [ ] Paste action is unaffected by system prompt settings

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful.

---

## Testing Strategy

### Manual Testing Steps:
1. Create a mode with Custom script action, command: `echo "$VCDR_TEXT" > /tmp/vcdr_test.txt`
2. Enable system prompt, type "SYSTEM PROMPT HERE"
3. Record audio, check `/tmp/vcdr_test.txt` starts with "SYSTEM PROMPT HERE\n"
4. Disable system prompt, record again, verify no prefix
5. Quit app, relaunch, verify system prompt settings persisted
6. Verify existing modes (created before this change) load without errors
