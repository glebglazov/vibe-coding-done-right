# ADR-0020: Transcription Model Settings belong to a Family, not to a Model

## Status

Accepted.

## Context

Whisper's two settings — a Language Hint and a free-text vocabulary prompt —
were keyed by Transcription Model, because a model is what everything else in
the app keys by: Library membership, a Mode's override, the provider registry.
With exactly one Whisper in the Library that keying was invisible.

Adding the other Whisper sizes makes it wrong. A Language Hint names the
language *the speech is in*; a vocabulary prompt names *the speaker's* proper
nouns. Neither is a property of which size of Whisper decodes the audio, so
per-model keying would ask a person to retype the same two answers once per
size, and switching from `small` to `large-v3` to compare quality would
silently drop the prompt that made the comparison fair.

## Decision

The settings-owning unit is a **Transcription Model Family**: every Whisper is
one family, Parakeet is its own. `TranscriptionModelSettingsStore` keys by
family, a Transcription Override's patch keys by family, and a Capability is
declared by the family rather than by each member.

Values already stored under `whisper-large-v3-turbo` are adopted as the Whisper
family's on first read, so nobody's vocabulary prompt disappears.

## Considered options

**Keyed by model, declared by family** — every Whisper declares the same
Capabilities but keeps its own values. Rejected: it preserves the retyping this
change exists to remove.

**One family holding every Whisper variant, including the English-only ones.**
Rejected: WhisperKit's `.en` variants cannot accept a Language Hint at all
(language detection is multilingual-only, `WhisperKit.swift:547`), so the
family would have to declare the *intersection* of its members' Capabilities
and thereby offer no Language Hint to anyone. The Library therefore holds only
multilingual Whisper variants. Should the `.en` models ever be wanted, the
honest shape is a second family, not a widened one.

## Consequences

A family whose members disagree about a Capability is not one family. That is
the rule to apply when a future model is added — it decides whether the model
joins an existing family or starts a new one, and it is why the Library's
Whisper membership is multilingual-only rather than complete.

`TranscriptionSettingOrigin.inherited(from:)` now names a family, so a Mode's
screen reads "From Whisper settings" rather than naming a model that does not
own the value.
