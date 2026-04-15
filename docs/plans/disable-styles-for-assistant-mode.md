# Plan: Disable Styles for Assistant Mode

## Motivation

Styles (capitalization, punctuation rules, dynamic prompts) make sense for dictation modes where the user is producing text that should match a writing style. But in assistant mode, the AI generates its own output — applying style transformations can corrupt it (e.g., lowercasing code, stripping intentional punctuation). Styles should be opt-in per mode, and assistant modes should opt out.

## Design Decisions

### 1. Per-mode `appliesStyles: Bool` property

A boolean property on the mode model controls whether styles are applied. This is preferred over keying off `processingType` or `promptType` because:
- Users can create custom modes where the right default isn't predictable from the processing type
- It follows the existing pattern of per-mode behavior flags (`showPreview`, `saveResultToClipboard`)

**Defaults for built-in modes:**

| Mode | `appliesStyles` |
|------|-----------------|
| Transcription (`plain`) | `true` |
| Dictation (`ai-dictation`) | `true` |
| Assistant Remote (`claude-code`) | `false` |
| Assistant Local (`ollama`) | `false` |

New custom modes default to `true`.

### 2. Pipeline: single check in `TextProcessingPipeline`

When `mode.appliesStyles` is `false`, skip both:
- **Stage 2**: `dynamicPrompt` appending to the AI system prompt (via `AIStylePromptAppender`)
- **Stage 3**: `StyleTransformer.transform()` static rules application

The check lives in `TextProcessingPipeline` — the single orchestrator of all four stages — rather than scattering it across individual components.

### 3. UI: style pill on the active mode row (macOS)

Replace the current bottom-section style indicator with a **small pill embedded in the active mode's row**, visible only when `appliesStyles == true`.

- **Content**: style name (e.g., "Casual", "Formal")
- **Background**: muted/secondary when auto-detected, accent color when user-overridden
- **Clickable**: cycles through `detected -> alt 1 -> alt 2 -> ... -> detected`
- **Accessible**: proper `accessibilityLabel`, `accessibilityHint`, and button role for VoiceOver

### 4. Remove old style indicator and TAB cycling (macOS)

- Remove the bottom divider + style indicator section from `ModeSwitcherView`
- Remove TAB key style cycling from `ModeSwitcherViewModel` / `ModeSwitcherCoordinator`
- Clean up unused `onCycleStyle` callback and related wiring in `AppDependencies`

The pill button fully replaces TAB as the style cycling mechanism.

### 5. UI: hide style pill when styles don't apply (iOS)

iOS uses `AIPromptMode` enum (dictation, assistant) instead of full `Mode` objects:
- Add `appliesStyles: Bool` computed property on `AIPromptMode` — `true` for `.dictation`, `false` for `.assistant`
- Conditionally show the style toggle pill in `RecordingView` only when `appliesStyles == true`
- Skip `StyleTransformer` and style-related terminator logic in `RecordingFlowCoordinator` when `appliesStyles == false`

## Implementation Checklist

### macOS (`vcdr-mac`)

- [ ] Add `appliesStyles: Bool` to `Mode` struct (`Mode.swift`) with Codable support and `true` default
- [ ] Set `appliesStyles` to `false` for `claude-code` and `ollama` templates (`ModeTemplate.swift`)
- [ ] Guard style stages in `TextProcessingPipeline.swift` behind `mode.appliesStyles`
- [ ] Add style pill button to the active mode row in `ModeSwitcherView.swift`
- [ ] Wire pill click to `StyleOverrideController` cycling via `ModeSwitcherCoordinator`
- [ ] Remove old style indicator section (bottom divider + style row) from `ModeSwitcherView.swift`
- [ ] Remove TAB key cycling from `ModeSwitcherViewModel.swift`
- [ ] Clean up unused `onCycleStyle` wiring in `ModeSwitcherCoordinator` and `AppDependencies`
- [ ] Add/update tests for pipeline style-skipping behavior
- [ ] Add/update mode serialization tests for new property

### iOS (`vcdr-ios`)

- [ ] Add `appliesStyles: Bool` computed property to `AIPromptMode`
- [ ] Guard style transform and terminator logic in `RecordingFlowCoordinator.swift`
- [ ] Conditionally show style pill in `RecordingView.swift`
- [ ] Add/update tests for pipeline style-skipping behavior

## Files Affected

### macOS
- `vcdr-mac/Core/Settings/Mode.swift`
- `vcdr-mac/Core/Settings/ModeTemplate.swift`
- `vcdr-mac/Orchestration/TextProcessingPipeline.swift`
- `vcdr-mac/UI/ModeSwitcherView.swift`
- `vcdr-mac/UI/ModeSwitcherViewModel.swift`
- `vcdr-mac/Orchestration/ModeSwitcherCoordinator.swift`
- `vcdr-mac/App/AppDependencies.swift`

### iOS
- `vcdr-ios/vcdr-ios/Settings/AIProcessingSettings.swift` (or wherever `AIPromptMode` lives)
- `vcdr-ios/vcdr-ios/Orchestration/RecordingFlowCoordinator.swift`
- `vcdr-ios/vcdr-ios/RecordingView.swift`
