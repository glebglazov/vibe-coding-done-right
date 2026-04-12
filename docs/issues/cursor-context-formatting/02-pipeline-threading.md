# Issue 2: Pipeline Threading — RunState to SubmissionSnapshot to TextProcessingPipeline

**Status:** Done (2026-04-12 13:50:21)

## Parent PRD

[PRD: Cursor Context-Aware Formatting](../../../PRD-Cursor-Context-Formatting.md)

## What to build

Thread `CursorContext` from capture through the processing pipeline so it reaches both `StyleTransformer` and `structureInput()`. This is pure plumbing — no behavioral change yet.

The flow follows existing patterns for how `captures` and `style` are threaded:

1. `CaptureSession+Recording.swift`: Store `CursorContext?` returned by `SelectionCapturer` in `RunState.cursorContext`
2. `CaptureSession+Processing.swift`: Copy from `RunState` into `SubmissionSnapshot` via `makeSubmissionSnapshot()`
3. `SubmissionPipeline` / `TextProcessingPipeline`: Accept and forward `cursorContext` parameter
4. **Staleness check:** At the point where the pipeline result is about to be inserted, compare `cursorContext.sourceBundleID` with the target app's bundle ID. If they differ (user switched apps during recording), set context to `nil` before passing to `StyleTransformer`.

## Acceptance Criteria

- [ ] `RunState` has a `cursorContext: CursorContext?` field
- [ ] `SubmissionSnapshot` (or its pipeline context) includes `cursorContext: CursorContext?`
- [ ] `TextProcessingPipeline.run()` accepts and forwards `cursorContext` to `StyleTransformer.transform()` and `structureInput()`
- [ ] Staleness check: context discarded when source bundle ID doesn't match target app
- [ ] No AX calls on the insertion path — zero added latency
- [ ] All existing tests pass unchanged
- [ ] No behavioral change: `StyleTransformer` receives context but ignores it until Issue 3 is implemented (passed as `nil` or unused parameter)

## Blocked by

- Blocked by Issue 1 (CursorContext type and SelectionCapturer capture)

## User stories addressed

From PRD:
- 8. Stale context discarded when user switches apps during recording

## Type

AFK - Mechanical plumbing following established patterns in the codebase. No design decisions.

## Notes

- Follow the exact pattern used for `style` threading: `styleProvider()` → `RunState` → `SubmissionSnapshot` → `TextProcessingPipeline`
- The staleness check compares bundle IDs, not PIDs — an app relaunch during recording is unlikely but would still match correctly
