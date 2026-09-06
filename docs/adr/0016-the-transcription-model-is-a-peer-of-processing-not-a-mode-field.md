# ADR-0016: The Transcription Model is a peer of processing, not a Mode field

## Status

Accepted.

## Context

Making the audio model configurable looks at first like adding a field to
`Mode` beside `aiProvider`, because that is where every other model-ish choice
lives. The macOS glossary does not support that reading. A Mode is "the
selected processing recipe for a Capture Session" — every clause of its
definition is about text that already exists — while transcription is a step of
the Capture Session one stage earlier, named as such in the Capture Session
entry itself.

The platforms also disagree on what a Mode is. `vcdr-ios` has no `Mode` at all:
it has `AIPromptMode`, a fixed three-case enum whose settings are individual
`@AppStorage` keys. A design that hangs the model off a Mode has nothing to
attach to on iOS, and the model choice is wanted on both.

Per-mode models were considered as the primary shape and rejected as the
primary shape only. The Parakeet CoreML bundle is 461 MB on disk and the
Whisper variant chosen alongside it is 627 MB; making every mode carry its own
model means either several resident at once or a CoreML/ANE cold load on every
mode switch, and cold load is the cost this effort has spent its time fighting.

## Decision

The Transcription Model belongs to the recording run, not to the Mode. There is
one Default Transcription Model per device, configured in its own Transcription
section beside the Transcription Model Library, and a Mode may override it.

1. **Settings belong to the model, not to any selection of it.** Transcription
   Model Settings are held in a store keyed by model, at both levels. Choosing
   model A, configuring it, using model B for a week and returning to A
   preserves A's settings, because nothing about them was ever attached to the
   selection.
2. **A Transcription Override is a sparse patch, per setting.** A Mode may
   override the model alone and inherit that model's settings, or override
   individual settings too; anything it does not set falls through to the
   model's own. A whole-blob snapshot was rejected because it would silently
   stop the global settings screen from reaching the modes that matter most.
3. **The effective settings are computed, so the UI must show provenance.** A
   Mode's transcription screen distinguishes an inherited value from an
   overridden one — "Language: Detect (from Whisper defaults)" — because the
   point of the task is transparency about what runs and what it was told.
4. **The Override is macOS-only.** iOS receives the Default Transcription Model
   and Transcription Model Settings, and no override, because it has no Mode to
   hang one on. Adding override keys to `AIPromptMode` was rejected: it would
   put a user-facing override on an enum the user cannot edit.
5. **Models are not evicted.** A model loaded in this process stays loaded until
   quit. The realistic worst case is the Default plus one override, around
   1.1 GB; evicting would buy bounded memory by reintroducing a cold load on
   every mode switch, which is the cost the user actually feels. Keeping the
   Default resident and evicting only the least-recently-used override is the
   upgrade if memory proves to be a real problem, and it changes none of the
   concepts above.
6. **An override model is downloaded when the override is configured**, not at
   first use, so first use is warm. First use of an override that is somehow
   absent still starts recording and downloads while the user speaks —
   [ADR-0006](0006-recording-is-never-refused-for-an-unready-model.md) holds.
   Silently transcribing with the Default instead was rejected: it produces
   plausible output from a model the Mode does not name, with nothing to see.
7. **Nothing transcription-related syncs between devices.** The Library is
   inherently per-device — different disks, and different membership per
   platform — so a synced Default would name models that are not installed and
   turn each device into a download prompt before it can dictate.

## Consequences

- The Transcription section is a new top-level settings area on both platforms,
  and the Mode screen gains an override affordance rather than a model picker.
- Two levels of a model-keyed store exist. A Mode's effective settings are
  resolved at use, never stored, so a bug in resolution shows up as the wrong
  model being told the wrong thing — the resolution belongs in one place with
  tests that drive it from Mode to provider call.
- iOS ships a thinner version of the same concepts, and its Library holds one
  model until someone does the WhisperKit streaming work
  ([ADR-0018](0018-a-transcription-model-may-be-removed-unless-something-names-it.md)).
- `TranscriptionSettings.removeFillerWords` stays a global setting. It is not a
  property of a model, and making it per-Mode is an independent change to Mode
  that this work deliberately does not carry.
