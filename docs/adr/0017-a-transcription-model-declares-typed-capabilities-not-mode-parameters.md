# ADR-0017: A Transcription Model declares typed Capabilities, not Mode Parameters

## Status

Accepted.

## Context

The codebase already has a shape for "a provider declares its own options":
`ModeParameter` is `{name, options: [{label, value}]}`, populated per provider
by `LocalAgentProvider.defaultParameters`, and it is how Claude Code's
Haiku/Sonnet/Opus choice is expressed. Reusing it for audio models is the
smallest change available and it was the obvious candidate.

It cannot express what the models actually accept. Whisper takes a free-text
`initial_prompt` and a language token that has a "send nothing" absence;
Parakeet takes a free-text vocabulary list. `ModeParameter` is a closed list of
strings, so each of these would have to be smuggled in as a fake option label.
`ModeParameter` is also load-bearing elsewhere: its `environmentVariableSuffix`
feeds `VCDR_PARAM_*` into shell commands, which makes it a *processing*
concept. Widening it to carry free text would change what it means at every
existing call site.

The deeper reason is that this is a new situation for the codebase. Cloud AI
backends differ from each other in the *values* they accept — model names —
which a closed list expresses exactly. Two audio models differ in the *kind* of
thing they can be told at all: Parakeet has no language token and no text
prompt, by design, and no value of any `ModeParameter` can represent that
absence.

## Decision

A Transcription Model declares a typed set of Transcription Model Capabilities,
each a kind rather than a list of strings, and the settings UI renders per kind.
`ModeParameter` is untouched and stays a processing concept.

Two kinds ship:

1. **Language Hint** — a set of supported locales plus a detect value meaning
   "send nothing". See
   [ADR-0019](0019-a-language-hint-is-never-set-from-a-guess.md) for why the
   detect value is not merely a default.
2. **Free-text prompt** — Whisper's `initial_prompt`, capped visibly in the UI
   at roughly 200 tokens. It is the model's vocabulary mechanism: proper nouns
   and jargon in the prompt bias spelling, and it costs no extra download.

**Vocabulary boost is named and deferred.** It is Parakeet's only hint
mechanism, and in FluidAudio it needs a separate ~130 MB CTC encoder on top of
the 461 MB model — so a Capability would itself be a download, giving a model a
second readiness state inside itself. That is a task of its own, and it is the
capability most likely to be used daily, so it should not be an afterthought of
this one.

## Consequences

- A model's settings screen is generated from its declared Capabilities, so
  adding a model with an unfamiliar hint means adding a Capability kind, not
  widening a string list.
- Whisper alone exercises both shipped kinds, which is why it is the second
  model: the seam is only proven by a model whose settings Parakeet cannot
  express.
- The free-text prompt is a soft hint the model may ignore, and it is a known
  contributor to Whisper's repeat-loop and hallucination failure modes. The
  visible cap is the guardrail; the UI should not present it as a reliable
  instruction.
