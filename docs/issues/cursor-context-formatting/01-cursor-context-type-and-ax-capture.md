# Issue 1: CursorContext Type and SelectionCapturer AX Capture

**Status:** Done (2026-04-12 13:25:10)

## Parent PRD

[PRD: Cursor Context-Aware Formatting](../../../PRD-Cursor-Context-Formatting.md)

## What to build

Define the `CursorContext` data type and fold cursor context reading into the existing `SelectionCapturer` AX focused element lookup. This reuses the same cross-process AX round-trip already performed for selection capture, saving 10-100ms and eliminating a race condition where separate calls could see different focused elements.

Two AX paths (matching existing selection capture strategy):

- **Path A (native Cocoa):** Use `kAXSelectedTextRangeAttribute` to get cursor position, then `kAXStringForRangeParameterizedAttribute` to read a 200-character window before and after. Works in TextEdit, Notes, Xcode, Obsidian, and browser textareas.
- **Path B (WebKit):** Use `AXSelectedTextMarkerRange` to get start/end markers, walk backward/forward with marker navigation attributes, then extract strings. Works in Safari content views.

Delete the spike code (`CursorContextProbe.swift` and its hook in `SelectionCapturer`). Production code returns values instead of logging.

## Acceptance Criteria

- [ ] `CursorContext` struct defined with `beforeText: String?` and `afterText: String?`, plus `sourceBundleID: String?` for staleness checks
- [ ] `CursorContext` conforms to `Sendable`, `Codable`, and `Equatable`
- [ ] `SelectionCapturer.capture()` returns cursor context alongside selected text (e.g., as a tuple or result struct)
- [ ] Path A reads up to 200 characters before and after cursor via `kAXStringForRangeParameterizedAttribute`
- [ ] Path B reads context via text marker walk when Path A attributes are unavailable
- [ ] Context capture returns `nil` gracefully when AX is unavailable (terminals, Telegram, password fields)
- [ ] `AXEnhancedUserInterface` enablement (already in `SelectionCapturer`) benefits context capture for Chromium apps
- [ ] Spike code deleted: `CursorContextProbe.swift` removed, hook in `SelectionCapturer.swift` removed
- [ ] Existing selection capture behavior unchanged — no regression in captured selection text
- [ ] Build succeeds with no new warnings

## Blocked by

None - can start immediately. This is the foundation for pipeline threading and context-aware formatting.

## User stories addressed

From PRD:
- 7. Cursor context captured at recording start, no delay at insertion
- 9. Context capture works in native Cocoa apps via AX range attributes
- 10. Context capture works in WebKit-based apps via AX text markers
- 11. Context capture works in Chromium-based apps after AXEnhancedUserInterface

## Type

AFK - Pure AX integration work with no design decisions remaining. Spike validated feasibility across app categories.

## Notes

- The 200-character window is a starting point — can be widened later if AI benefits from more context
- Path B marker walk is capped at 400 steps as a safety bound against runaway AX calls
- `sourceBundleID` is stored so downstream consumers can check for staleness without re-querying AX
