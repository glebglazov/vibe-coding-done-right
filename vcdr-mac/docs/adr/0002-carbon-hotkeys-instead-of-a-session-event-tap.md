# Carbon hotkeys instead of a session event tap

VCDR's global hotkeys died silently and intermittently. The cause is macOS Secure Event
Input, a process-global reference-counted flag: while any process holds it, macOS stops
delivering key events to every session-level `CGEventTap` on the machine. It does not
disable the tap — `EventTapManager` still reports `isInstalled`, no `tapDisabledByTimeout`
fires, nothing is logged. Password managers are the usual holder.

We are replacing every `CGEventTap` with `RegisterEventHotKey`, and deleting the tap
mechanism rather than keeping it as a fallback.

## What was measured

Not inferred. A harness registered a Carbon hotkey and a listen-only event tap in one
process while a separate process held Secure Input for an 18-second window:

```
RESULT                 BEFORE DURING  AFTER
Carbon hotkey             7     13      9
CGEventTap (today)       10      0      9
```

A second round of probes (`/tmp/sitest2`, macOS 26.5.1) settled the open questions:

| Question | Result |
|---|---|
| Does `CGEventPost` of a paste survive Secure Input? | Yes — 12/12 delivered with the flag confirmed held |
| Sequoia `⇧⌥` registration defect (forums 763878)? | Not reproducible here — 19/19 registered, `⇧⌥P` included |
| Does `kEventHotKeyPressed` autorepeat? | No — Carbon filters autorepeat events (3 normal → 3 fires, 3 autorepeat → 0) |
| Still global from an accessory app? | Yes — fires while never frontmost, over three frontmost apps, and over a genuinely full-screen window |
| Two processes claiming one combination? | Both register `noErr` and both receive the press |

Untested: delivery of macOS-reserved combinations (`⌘Space`, `⌘Tab`, `⌃↑`). They register
without error, but a head-insert tap could steal them and Carbon probably cannot. No
current binding is affected.

## Consequences

**A Carbon hotkey always consumes; there is no pass-through.** `isEnabled` and
`isSuppressed` let a matched key through unconsumed; Carbon has no equivalent. Both flags
become register/unregister, expressed as ownership of a registration handle so there is no
boolean to leave in the wrong state. Cancel and destination arming are derived from
`status.phase` in one place rather than assigned from nine, because a missed disarm would
leave `⇧Tab` eaten system-wide — a worse bug than the one being fixed.

**Superset matching becomes precomputation.** `matchBinding`'s semantics are preserved by
computing, per keycode, which destination wins each of the 16 modifier combinations, and
registering only the winners. `matchBinding` stays the core of that computation.

**Accessibility stops gating hotkey liveness.** `RegisterEventHotKey` needs no grant, so the
`AXIsProcessTrusted()` guard goes. Accessibility is still required for paste and the Cursor Context read,
so the app's only one-shot prompt moves to the first untrusted paste; the Home tab already
carries the standing notice.

**`SecureInputMonitor` is removed.** It was shipped in `9b8f9ef` to explain why hotkeys were
dying. After this change Secure Input has no observable effect on VCDR — hotkeys survive it
and, as measured above, so does paste delivery. A permanent warning about a condition that
degrades nothing would train the user to ignore the surface that also carries the real
Microphone and Accessibility warnings. The knowledge is preserved here rather than in code.

## Rejected

**Keeping taps as a fallback.** Nothing in VCDR needs modifiers-only matching or
non-consuming observation, which is all a tap can still do that Carbon cannot. Two
mechanisms would mean two failure modes and no way to tell which one was live.

**Reporting shortcut conflicts in the recorder UI.** There is nothing to report:
`eventHotKeyExistsErr` is process-local, cross-process claims both succeed, and both
processes receive the press.
