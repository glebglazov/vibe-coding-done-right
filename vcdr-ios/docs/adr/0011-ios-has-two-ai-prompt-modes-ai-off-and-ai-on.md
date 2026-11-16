# iOS has two AI Prompt Modes: AI off and AI on

VCDR on iOS is a dictation tool. The Assistant mode made it an agent: it did what the user said to the text that the keyboard captured. The user does not use it that way, so iOS now has two AI Prompt Modes. Verbatim is AI off and Dictation is AI on. The app and the keyboard show one pill, AI ON or AI OFF, and a tap toggles it. Captures are gone with Assistant, because only Assistant used them.

## Decision

- **The ids stay.** `AIPromptMode` keeps its two cases, `verbatim` and `dictation`, with the same raw values. These raw values are stored ids: the Default Setting, the Session Setting, the per-mode Transcription Model pins, the prompt cache, and the mode in a Recorded Output Choice that History syncs to the Mac. Only the names that the user sees change.
- **A saved Assistant becomes AI on.** `LegacySettingsMigrator` changes a Default Setting or a Session Setting of `assistant` to `dictation`. The user chose an AI mode, and AI on is the nearest one. Without this step, the reader falls back to AI off and does not tell the user. The step also deletes the keys that only Assistant used: its Provider, its Apple fallback, its Transcription Model pin, its cached prompt, and the two Capture keys. The step runs at every launch and changes nothing on a second run.
- **History loses the Assistant entries.** After History Bootstrap, at every launch, VCDR deletes a normal Conversation whose label is exactly "Assistant" and a Discarded Conversation whose Recorded Output Choice is `ios`/`assistant`. An iOS Assistant run had that label because Assistant applied no Text Style. The Mac Assistant Modes have other names, so their entries stay. A delete writes a tombstone, so the entries also go from the Mac.
- **New labels.** A new Conversation gets "AI · Casual". A new Discarded Conversation gets "AI · Casual" or "AI off · Casual". A label is stored text, so an old entry keeps "Dictation · Casual".
- **Text Style always applies.** Assistant output skipped the style rules. With Assistant gone, Transcript Finalization depends on the Text Style only.
- **Settings are flat.** Settings › AI Processing has "Start with AI On", the Provider and the Apple fallback. The "Modes" list and its screens are gone. The two Transcription Model pins are the rows "With AI On" and "With AI Off" in Settings › Transcription.
- **Process with AI chooses a style only.** It always runs with AI on.
- **DONE shows the style only.** "ENHANCED BY AI" already says that AI was on.

## Considered options

- **Replace the enum with a Bool.** Rejected: every per-mode key and the History choice would need a new spelling, and History would hold two vocabularies.
- **Rename the ids to `off` and `on`.** Rejected: five stored places would need a migration, and the Mac reads the synced ids.
- **Keep Captures for AI on.** Rejected: Dictation must not change a capture, so a capture adds nothing to a dictation tool.
- **Hide Assistant entries on iOS only.** Rejected: the Mac change is next, and it would delete them later anyway.

## Follow-ups (the Mac change)

The Mac still has its Assistant (Remote) and Assistant (Local) templates and the `assistant` prompt type. The server still serves the `assistant` prompt (`vcdr-server/prompts.go`), and `evals/assistant_prompts` still measures it. The iOS build ignores that prompt. Remove them, and the Assistant half of [ADR-0026](../../../docs/adr/0026-a-dictionary-note-reaches-only-modes-that-rewrite-what-was-said.md), when the Mac change ships.
