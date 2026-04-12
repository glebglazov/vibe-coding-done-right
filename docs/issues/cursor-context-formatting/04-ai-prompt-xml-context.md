# Issue 4: AI Prompt Integration — XML Context Tags and System Prompt Update

**Status:** Done (2026-04-12 14:37:31)

## Parent PRD

[PRD: Cursor Context-Aware Formatting](../../../PRD-Cursor-Context-Formatting.md)

## What to build

When cursor context is available in cloudAI mode, emit `<cursor_context>` XML tags in `structureInput()` so the LLM can make grammar-aware formatting decisions. Add a single instruction line to the AI system prompt about cursor context.

XML output when context is available:
```xml
<cursor_context>
  <before>text before cursor</before>
  <after>text after cursor</after>
</cursor_context>
<dictation>transcribed text</dictation>
```

When context is nil, no `<cursor_context>` tags — existing XML structure unchanged.

Update the built-in dictation system prompt (and optionally the assistant prompt) with one line instructing the AI to consider cursor context for natural text flow when present. The AI can handle cases the algorithmic path cannot — abbreviation periods ("Dr."), contextual grammar, mid-sentence tone matching.

## Acceptance Criteria

- [ ] `structureInput()` emits `<cursor_context>` with `<before>` and `<after>` child tags when `cursorContext` is non-nil
- [ ] Both `beforeText` and `afterText` are included (both may be nil independently — omit the child tag when nil)
- [ ] Special XML characters in context text are properly escaped (`&`, `<`, `>`, `"`, `'`)
- [ ] No `<cursor_context>` tags when context is nil — existing behavior preserved
- [ ] Built-in dictation system prompt updated with cursor context instruction
- [ ] Tests: XML output contains cursor context tags with correct content when available
- [ ] Tests: XML output has no cursor context tags when context is nil
- [ ] Tests: XML special characters properly escaped in context
- [ ] All existing TextProcessingPipeline tests pass unchanged

## Blocked by

- Blocked by Issue 2 (pipeline threading — context must reach `structureInput()`)

## User stories addressed

From PRD:
- 12. Surrounding text context passed to AI for grammar-aware formatting
- 13. Both before-cursor and after-cursor context available to AI

## Type

AFK - XML generation and prompt update with test coverage. No design decisions remaining.

## Notes

- The system prompt addition should be minimal — one sentence like "When `<cursor_context>` is present, use it to ensure the dictated text flows naturally with the surrounding text (capitalization, punctuation, grammar)."
- Keep the prompt instruction conditional-sounding ("when present") so the prompt still works correctly when context is absent
- Token cost of context: ~100 tokens for 200 chars × 2 sides. Negligible relative to typical dictation prompt costs
- `localAgent` and `bashScript` modes also use `structureInput()` — they get the XML tags too, which is fine (their processors can ignore or use them)
