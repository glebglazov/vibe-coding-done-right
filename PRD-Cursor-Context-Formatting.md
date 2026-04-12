# PRD: Cursor Context-Aware Formatting

## Problem Statement

When dictating text into an existing document, the transcribed output has no awareness of the surrounding text. If a user has "hi, i am Gleb." in a text field and dictates "how are you", the result is "hi, i am Gleb.how are you" — with wrong capitalization and no spatial awareness. The user must manually fix capitalization after every mid-document dictation. This is the single most annoying formatting issue in the current dictation flow.

## Solution

Read the text surrounding the cursor via the Accessibility API at recording start. Use that context to make smarter formatting decisions:

1. **Algorithmic path (all modes):** Extend `StyleTransformer` to accept cursor context and adjust the leading edge of dictated text. In Formal mode, capitalize the first letter when the cursor follows a sentence terminator (`[.!?]`) or sits in an empty field. In Casual mode, lowercase it. When context shows a mid-sentence position (e.g., after a comma or plain word), leave the first character untouched.

2. **AI path (cloudAI mode):** Pass cursor context as XML tags alongside the dictation, so the LLM can make grammar-aware decisions that regex cannot (e.g., distinguishing abbreviation periods from sentence-ending periods).

When context is unavailable (AX dead zones like Terminal, Telegram, password fields), fall back to current behavior — no regression.

## User Stories

### Core Behavior

1. As a user dictating after a period in Formal mode, I want my first dictated word to be capitalized automatically, so that I don't have to fix it manually.

2. As a user dictating after a period in Casual mode, I want my first dictated word to be lowercased, so that it matches the casual style.

3. As a user dictating mid-sentence (e.g., after a comma), I want the first dictated word to remain as-is, so that it flows naturally with the existing text.

4. As a user dictating into an empty text field, I want capitalization to follow my active style's rules, so that the first word is formatted correctly.

5. As a user dictating after an exclamation mark or question mark, I want the same capitalization behavior as after a period, so that all sentence terminators are treated consistently.

6. As a user dictating in an app where AX context is unavailable (e.g., Terminal, Telegram), I want the existing formatting behavior to apply unchanged, so that there is no regression.

### Context Capture

7. As a user, I want cursor context to be captured when I start recording, so that there is no delay when inserting text.

8. As a user who switches apps during recording, I want stale context to be discarded rather than applied incorrectly, so that formatting doesn't break when I change targets.

9. As a user dictating in a native Cocoa app (TextEdit, Notes, Xcode), I want context capture to work reliably via AX range attributes.

10. As a user dictating in a WebKit-based app (Safari textarea), I want context capture to work via AX text markers.

11. As a user dictating in a Chromium-based app (Chrome, Arc, VS Code, Obsidian), I want context capture to work after AXEnhancedUserInterface is enabled.

### AI Integration

12. As a user in cloudAI mode, I want the surrounding text context passed to the AI, so that it can make grammar-aware formatting decisions (e.g., handling abbreviations like "Dr." correctly).

13. As a user in cloudAI mode, I want both before-cursor and after-cursor context available to the AI, so that mid-sentence insertions flow naturally.

14. As a user in `.none` or `.bashScript` mode, I want algorithmic context-aware formatting to still work, so that I benefit from cursor context even without AI.

### Style Interaction

15. As a user with Formal style active, I want context-aware capitalization to capitalize after sentence boundaries and at document start.

16. As a user with Casual style active, I want context-aware capitalization to lowercase after sentence boundaries and at document start, consistent with how Casual already handles internal sentence starts.

17. As a user with a Preserve punctuation rule, I want the context-aware logic to still handle capitalization according to `capitalizeSentences`, independent of punctuation rules.

## Implementation Decisions

### New Type: `CursorContext`

A lightweight struct with `beforeText: String?` and `afterText: String?`. Separate from `CapturedContext` (which represents selection/clipboard content). `CursorContext` is positional metadata about where insertion will happen, not content to process.

### Cursor Context Capture: Folded into `SelectionCapturer`

Context capture reuses the same AX focused element already obtained by `SelectionCapturer`. This avoids a duplicate cross-process AX round-trip (10-100ms savings) and eliminates a race condition where two separate calls could see different focused elements.

Two AX paths, matching the existing selection capture strategy:
- **Path A (native Cocoa):** `kAXSelectedTextRangeAttribute` to get cursor position, `kAXStringForRangeParameterizedAttribute` to read a window of characters before/after. Capped at 200 characters each direction.
- **Path B (WebKit):** `AXSelectedTextMarkerRange` to get start/end markers, walk backward/forward with `AXPreviousTextMarkerForTextMarker`/`AXNextTextMarkerForTextMarker`, then `AXStringForTextMarkerRange` to extract text. Capped at 200-400 marker steps.

`SelectionCapturer` keeps its name despite expanded scope — renaming would add churn across many files for marginal clarity.

### Context Flow Through Pipeline

1. `SelectionCapturer.capture()` returns cursor context alongside selected text.
2. Stored in `RunState.cursorContext`.
3. Copied into `SubmissionSnapshot` by `makeSubmissionSnapshot()`.
4. Threaded through `TextProcessingPipeline` to two consumers:
   - `structureInput()` — wraps context as XML for AI.
   - `StyleTransformer.transform()` — uses `beforeText` for capitalization.

### Context Staleness Check

At insertion time, compare the stored context's source bundleID with the target app's bundleID. If they differ (user switched apps during recording), discard the context and fall back to no-context behavior. No AX calls on the insertion path — zero added latency.

### `StyleTransformer` Changes

New signature: `StyleTransformer.transform(text, using: rules, cursorContext: CursorContext?)`.

Leading-edge capitalization logic:
- **Context available, sentence boundary** (`[.!?]` followed by optional whitespace at end of `beforeText`, or `beforeText` is empty/whitespace-only): Apply style's capitalization rule to first character (Formal → uppercase, Casual → lowercase).
- **Context available, non-boundary** (any other trailing content in `beforeText`): Do not modify the first character of the dictated text.
- **Context nil** (AX unavailable or discarded): Current behavior — unconditionally apply style's capitalization rule. This is the graceful fallback ensuring zero regression.

### AI Prompt Integration

When cursor context is available in cloudAI mode, `structureInput()` prepends XML context before the dictation tag:

```xml
<cursor_context>
  <before>text before cursor</before>
  <after>text after cursor</after>
</cursor_context>
<dictation>transcribed text</dictation>
```

A single line is added to the AI system prompt instructing it to consider cursor context for natural text flow when present.

### Tested App Compatibility (from spike)

| App Category | Examples | Works? |
|---|---|---|
| Native Cocoa | TextEdit, Notes | Yes (Path A) |
| Electron w/ enhanced UI | Obsidian | Yes (Path A) |
| Browsers | Safari, Chrome, Arc | Yes (Path A or B) |
| Terminal | Ghostty, Terminal.app | No — AX dead zone |
| Custom rendering | Telegram | No — AX dead zone |
| Internal WebKit | Mail compose | No — AX blocked |

Dead zones fall back to current behavior gracefully.

## Testing Decisions

### What makes a good test

Tests should verify external behavior through the public interface (`StyleTransformer.transform()`), not AX internals. Given a `(text, rules, cursorContext)` tuple, assert the output string. No mocking of AX — that's an integration concern validated by the spike.

### Modules to test

**`StyleTransformer` with cursor context (primary):**
- Formal mode: capitalize after `.`, `!`, `?`, after `.` + space, after empty context, after whitespace-only context.
- Formal mode: don't capitalize after `,`, after plain word, after word + space.
- Casual mode: lowercase at same boundary positions, leave untouched at non-boundary.
- Preserve rules: respect `capitalizeSentences` flag independently of punctuation rule.
- Nil context: exact current behavior (regression suite — existing tests pass unchanged with `cursorContext: nil`).
- Edge cases: Unicode, emoji, numbers at boundary, multiple terminators (`?!`), trailing whitespace in `beforeText`.

**XML structuring (secondary):**
- Context available: `<cursor_context>` tags present with correct content.
- Context nil: no `<cursor_context>` tags emitted.
- Context with special XML characters: properly escaped.

### Prior art

`StyleTransformerTests.swift` — comprehensive test suite using Swift Testing (`@Suite`, `@Test`, `#expect`). New context-aware tests follow the same patterns and live in the same file or a companion suite. Existing tests must pass unchanged when called with `cursorContext: nil` to verify zero regression.

## Out of Scope

- **Punctuation prepending:** No automatic insertion of periods, commas, or spaces before dictated text based on context. Users often dictate partial replacements (a word or two) where prepended punctuation would be wrong.
- **iOS cursor context:** `UITextDocumentProxy.documentContextBeforeInput` is the iOS equivalent but requires separate investigation and implementation. This PRD covers macOS only.
- **Abbreviation detection:** Distinguishing "Dr." from sentence-ending "." in the algorithmic path. The AI path handles this; the algorithmic path accepts false positives (capitalizes after "Dr."), consistent with how `StyleTransformer` already treats all periods as sentence boundaries within dictated text.
- **Custom styles with context-specific rules:** The context-aware capitalization uses the existing `capitalizeSentences` flag. No new per-style context configuration.
- **After-cursor context consumption in algorithmic path:** Captured and passed to AI, but not used by `StyleTransformer`. Reserved for future spacing/punctuation logic.

## Further Notes

- The spike code (`CursorContextProbe.swift` + hook in `SelectionCapturer.swift`) should be deleted before implementation begins. The spike validated AX feasibility across app categories; production code will be structured differently (returning values instead of logging).
- The 200-character context window is a starting point. If AI responses improve with more context, the window can be widened. Performance impact is negligible — AX string reads are fast once the focused element is obtained.
- Long-term, `Style.dynamicPrompt` (currently always nil) could include context-aware instructions, making style-specific AI formatting possible. This PRD's XML context tags lay the groundwork.
