# Issue 3: StyleTransformer Context-Aware Capitalization

**Status:** Done (2026-04-12 14:01:49)

## Parent PRD

[PRD: Cursor Context-Aware Formatting](../../../PRD-Cursor-Context-Formatting.md)

## What to build

Extend `StyleTransformer.transform()` to accept an optional `CursorContext` and use `beforeText` to make smarter leading-edge capitalization decisions. This is the core behavioral change of the feature.

New signature: `StyleTransformer.transform(_ text: String, using rules: StaticStyleRules, cursorContext: CursorContext?) -> String`

Leading-edge capitalization logic for the **first character** of the dictated text:

| Context state | Before text ends with | Formal (capitalizeSentences: true) | Casual (capitalizeSentences: false) |
|---|---|---|---|
| Available | `[.!?]` + optional whitespace | Uppercase | Lowercase |
| Available | Empty string or whitespace-only | Uppercase | Lowercase |
| Available | Anything else (comma, word, etc.) | Leave untouched | Leave untouched |
| Nil (AX failed / discarded) | N/A | Current behavior (uppercase) | Current behavior (lowercase) |

The rest of the text (internal sentence boundaries, ending punctuation) continues to use existing logic unchanged.

## Acceptance Criteria

- [ ] `StyleTransformer.transform()` signature updated with `cursorContext: CursorContext?` parameter defaulting to `nil`
- [ ] All existing `StyleTransformerTests` pass unchanged (nil context = current behavior, zero regression)
- [ ] New tests for Formal mode with context:
  - [ ] Capitalize after period: `before="hello."` + `"how are you"` → `"How are you."`
  - [ ] Capitalize after period+space: `before="hello. "` + `"how are you"` → `"How are you."`
  - [ ] Capitalize after `!`: `before="wow!"` + `"that was great"` → `"That was great."`
  - [ ] Capitalize after `?`: `before="really?"` + `"yes indeed"` → `"Yes indeed."`
  - [ ] Capitalize in empty field: `before=""` + `"how are you"` → `"How are you."`
  - [ ] Don't capitalize after comma: `before="hello,"` + `"How are you"` → `"How are you."` (first char untouched)
  - [ ] Don't capitalize after word: `before="hello "` + `"world"` → `"world."` (first char untouched)
  - [ ] Don't capitalize after plain word: `before="hello"` + `"world"` → `"world."` (first char untouched)
- [ ] New tests for Casual mode with context:
  - [ ] Lowercase after period: `before="hello."` + `"How are you"` → `"how are you"`
  - [ ] Lowercase in empty field: `before=""` + `"How are you"` → `"how are you"`
  - [ ] Leave untouched mid-sentence: `before="hello,"` + `"how are you"` → `"how are you"` (untouched)
- [ ] Nil context tests: exact same results as current behavior for both Formal and Casual
- [ ] Edge cases: Unicode first character, emoji in beforeText, multiple terminators (`?!`), whitespace-only beforeText, trailing whitespace in beforeText

## Blocked by

None - can start immediately. Only needs the `CursorContext` type definition, which can be defined inline or in the same PR. Wiring through the pipeline (Issue 2) is separate.

## User stories addressed

From PRD:
- 1. Capitalize after period in Formal mode
- 2. Lowercase after period in Casual mode
- 3. Leave untouched mid-sentence
- 4. Correct capitalization in empty field
- 5. Consistent behavior after all sentence terminators
- 6. No regression when context unavailable
- 14. Algorithmic formatting works in `.none` and `.bashScript` modes
- 15. Formal context-aware capitalization at boundaries
- 16. Casual context-aware lowercasing at boundaries
- 17. Preserve punctuation rule independent of context capitalization

## Type

AFK - Pure logic with comprehensive test suite. No AX, no UI, no side effects.

## Notes

- The `CursorContext` type can be defined in this slice if starting before Issue 1. It only needs `beforeText: String?` and `afterText: String?` for transformer use — `sourceBundleID` is only needed by the pipeline staleness check in Issue 2.
- Boundary detection regex: `[.!?]\s*$` on `beforeText` — simple, consistent with how `StyleTransformer` already treats periods as sentence boundaries internally.
- The "leave untouched" behavior means the first character passes through without the style's capitalization rule being applied to it. Internal sentence boundaries within the dictated text still get the style's rule as before.
