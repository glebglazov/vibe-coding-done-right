# ADR-0018: A Transcription Model may be removed unless something names it

## Status

Accepted.

## Context

Once models can be installed they must be removable — a Whisper variant is
627 MB and a Parakeet bundle 461 MB. Neither SDK helps: WhisperKit exposes no
delete API and no local-inventory API (its own reference app deletes the
variant folder with `FileManager.removeItem` and enumerates local models by
reading the directory), and FluidAudio's inventory is `modelsExist(at:)`
against a path. So the Library is code we own on both sides, and the invariant
that keeps the app able to transcribe is ours to state.

"Keep at least one installed" is the obvious rule and the wrong one. It is
satisfiable while the Default Transcription Model is the one you deleted, and
it says nothing about a Mode whose Transcription Override names a model that is
now gone.

Both SDKs accept a caller-owned directory — `AsrModels.download(to:)` and
WhisperKit's `downloadBase:` — so where the models live is a choice, not a
constraint.

## Decision

1. **The invariant is on the Default, not on a count.** The Default
   Transcription Model is always installed. A model may be removed whenever it
   is not the Default and no Mode's Transcription Override names it.
2. **Removal is refused, never silently repointed.** Deleting a model three
   Modes use reports that fact and stops. Repointing them at the Default would
   change what those Modes transcribe with, and therefore what they produce,
   without saying so.
3. **No model is special.** Parakeet is not an undeletable floor. Making it one
   hard-codes today's answer into the invariant, and the moment Apple's
   `SpeechTranscriber` (no download, no cold load) or Nemotron is the better
   Default, the 461 MB should be reclaimable.
4. **Settings outlive the model.** Removing a model does not remove its
   Transcription Model Settings. They are bytes against a 461 MB bundle, and
   reinstalling in a month should return the model configured as it was — the
   same promise as switching away and back.
5. **One owned root.** Models live under a directory VCDR owns, passed to both
   SDKs, so "what is installed, how big, remove it" is a directory listing
   rather than a protocol method every future provider must implement
   correctly. An existing Parakeet download at FluidAudio's default path is
   moved into the root once on first launch; if it is not there, it downloads
   normally.
6. **The Library's membership is per-platform.** A platform offers only models
   its own transcription path can drive. macOS transcribes a finished
   recording; iOS drives a live view through FluidAudio's sliding window over
   the offline Parakeet encoder, and WhisperKit's live path is chunked
   re-decoding with different confirmation semantics. So Whisper is macOS-only
   until that work is done, and iOS ships the seam with a Library of one.

## Consequences

- iOS's deliverable is the seam and one model. This is deliberate: offering
  Whisper on iPhone would make the live view behave differently with nothing to
  explain it. **Amended by [ADR-0021](0021-the-ios-library-becomes-plural.md):**
  iOS's Library becomes plural, and the WhisperKit streaming work deferred in
  point 6 above is funded rather than deferred. The removal rule this ADR
  decides is unaffected.
- VCDR owns a directory two SDKs also believe they manage. Both take the path
  as a parameter for exactly this reason, but an SDK changing its layout inside
  that directory is a risk the Library absorbs.
- `fetchAvailableModels` returns only variants supported on the current device,
  filtered through a remote config — so "what can I install" is a network
  question, and the Library screen has a state for not knowing yet.
- The Library screen renders the full per-model state — not installed,
  downloading with progress, installed, loading, ready, failed — because a
  download without progress is unusable. The menu bar and recording pill keep
  their current single label; naming these states is the handoff to
  [[not-ready-says-nothing]], which owns rendering them there.
