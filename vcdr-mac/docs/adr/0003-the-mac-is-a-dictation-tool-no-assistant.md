# The Mac is a dictation tool: no Assistant

VCDR on the Mac is a dictation tool, as on iOS ([vcdr-ios ADR-0011](../../../vcdr-ios/docs/adr/0011-ios-has-two-ai-prompt-modes-ai-off-and-ai-on.md)). The Assistant made it an agent. It did what the user said to the selected or copied text. The Mac keeps Modes, because a Mode also owns the Output Destination, Preview, Mode Parameters and the Transcription Override. So the Mac does not get one AI toggle. It loses the `assistant` prompt type, the Mode Templates "Assistant (Remote)" and "Assistant (Local)", and the parts that only an agent needs.

## Decision

- **Two built-in Modes, with the iOS words.** The Mode Templates are AI off (no processing) and AI on (Cloud AI with the Dictation prompt). A saved built-in Mode gets the new name only when its name is still an earlier default ("Verbatim", "Dictation"). A name that the user chose stays.
- **No Local Agent.** Its one provider ran the `claude` CLI, which is an agent, and only the Assistant template used it. A Bash Script can still call any command-line tool.
- **No Captures.** Selection Capture and Clipboard Capture go, with the Edit menu and Command-C Capture Layers and the clipboard monitor. The two built-in Modes ignored Captures, yet every recording ran the Command-C layer, which could put a Stray Character in the frontmost app. The Accessibility read of the Cursor Context stays, so Context-Aware Formatting does not change. The Apple Events entitlement stays, because the media pause uses it to tell Music and Spotify to pause.
- **Style applies in every Mode.** Only the Assistant templates turned Style off, and the editor had no switch for it.
- **No No Instruction.** Only the bundled Assistant prompt could answer that it found no instruction.
- **Custom prompts and Bash Script stay.** A Custom prompt is the user's own text, for jobs like translation. With Captures gone, it acts only on what the user said.

## Migration

One step runs at every launch, before the template Modes are made again. It deletes every saved Mode made from the two Assistant templates and every Local Agent Mode, and records each one as a Retired Mode (its id and name). An active Retired Mode becomes AI on, as on iOS. The user chose an AI Mode, and AI on is the nearest one. A user Cloud AI Mode with the Assistant prompt stays, with the Dictation prompt. The step also deletes the cached Assistant prompt. A second run changes nothing.

## History

History stores no prompt type. A Mac Conversation has only its label, which is the Mode name, so the iOS rule (the label "Assistant") does not see Mac entries. After History is ready, at every launch, VCDR deletes:

- a normal Conversation whose label is the name of a Retired Mode, "Assistant (Remote)" or "Assistant (Local)";
- a Discarded Conversation whose Recorded Output Choice is `mac` with the id of a Retired Mode.

A name that a kept Mode also has is never matched, because new runs of that Mode carry the same label. Entries of a kept Mode whose prompt was Assistant stay, because the label cannot tell its old runs from its new ones. A delete writes a tombstone, so the entries also go from iOS. Because the cleanup runs at every launch, it also deletes an entry that sync brings in later from an older build.

## Considered options

- **Keep "Verbatim" and "Dictation".** Rejected: the Mac and iOS would use two sets of words for the same two choices, in one shared History.
- **One AI toggle in place of the Mode switcher.** Rejected: the switcher also selects Custom and Bash Script Modes.
- **Keep Local Agent for Dictation and Custom prompts.** Rejected: its only provider is an agent.
- **Keep Captures for user Modes.** Rejected: the Command-C layer runs for every Mode, and a capture adds nothing to a dictation tool.
- **Turn a Local Agent Mode into a Cloud AI Mode.** Rejected: its runs depended on the agent, and a Cloud AI Mode would not do what the user set up.

## Consequences

- The server keeps the `assistant` prompt until this build ships. An older Mac build keeps its cached copy after the server drops it.
- `POST /v1/process` stays. It is not Assistant-only, and its removal is a separate change.
