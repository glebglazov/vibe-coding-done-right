# ADR-0021: The iOS Transcription Model Library becomes plural

## Status

Accepted. Amends [ADR-0018](0018-a-transcription-model-may-be-removed-unless-something-names-it.md).

## Context

[ADR-0018](0018-a-transcription-model-may-be-removed-unless-something-names-it.md)
recorded that iOS "ships the seam with a Library of one", deliberately: macOS
transcribes a finished recording, where iOS drives a live view through
FluidAudio's sliding window, and WhisperKit's live path is chunked re-decoding
with different confirmation semantics. Parakeet alone could drive that path, so
the Library screen, the Default Transcription Model and the Transcription
Override were all built on macOS and left off iOS.

The consequence is that the two products diverged in what a person can say
about their own transcription, not only in what the engine can do. iOS shows a
read-only model name; every choice macOS offers is absent.

## Decision

iOS's Library becomes plural: it offers the same multilingual Whisper variants
macOS does alongside Parakeet, with a Default Transcription Model chosen in
Settings and a Transcription Override carried per Prompt Mode.

That requires the WhisperKit streaming work ADR-0018 deferred. It is the price
of the decision rather than a detail of it: a Default Model picker over a
Library of one, or an Override that can only re-pick the model it overrides, is
a control that lies about what the app can do, so the engine work lands before
the UI does.

## Consequences

ADR-0018's removal rule is untouched — a model may still be removed unless it
is the Default or something names it, and on iOS "something" now includes a
Prompt Mode. Only its "Library of one" consequence is amended here.

A Transcription Override is no longer macOS-only, and so no longer belongs to
the macOS glossary. It attaches to a Mode on macOS and to a Prompt Mode on iOS
— a closed set of three the app ships, not a list a person authors — which is
why the two concepts keep separate names.

The confirmation semantics of a chunked re-decoding live view are **not**
settled by this ADR. It records that iOS will run Whisper, not how the live
view reconciles it; that design is its own decision.
