# ADR-0019: A Language Hint is never set from a guess

## Status

Accepted.

## Context

Whisper's `language` option reads like a preference and is not one. It places a
`<|ru|>`-style token into the decoder prompt
`<|startoftranscript|><|lang|><|transcribe|>`, which primes the decoder to emit
that language's tokens — and Whisper was separately trained on the X→English
translation task. A hint that does not match the speech therefore tends to
produce a *translation* rather than a bad transcript: fluent, plausible text in
the wrong language, with no error and nothing to notice.

The maintainer answer on exactly this case is that the behaviour "is not
documented, and any resulting behaviour wouldn't accurately be described as a
bug — the behaviour is simply unspecified here", and that the model "will be
primed to output French words, so that's probably tipped the odds in favour of
this sort of behaviour happening"
([openai/whisper #2285](https://github.com/openai/whisper/discussions/2285)).
whisper.cpp carries the same reports — audio silently translated into the
forced language, "often poorly"
([#2678](https://github.com/ggml-org/whisper.cpp/issues/2678),
[#1800](https://github.com/ggml-org/whisper.cpp/issues/1800)).

This matters here because VCDR's own dictation mixes English and Russian, and
because every convenient way to populate a language setting is a guess: the
system locale, the keyboard layout, the last language detected, a "primary
language" onboarding question. Each of them produces a wrong hint for a
bilingual user on the utterance where it costs most.

The same trap exists one layer down. FluidAudio's newer `language:` parameter
is not a model input at all but a post-hoc script filter — `.english`
suppresses Cyrillic candidates and `.russian` suppresses Latin ones — so
setting it would actively break mixed dictation, and its own documentation
lists "real mixed-language switches being removed or delayed" as a failure
mode.

## Decision

A Language Hint is only ever set deliberately by a person, for a Transcription
Override they know to be monolingual. It is never derived.

1. **Detect is the default and a real value**, meaning "send nothing" — for
   Whisper, omit the language token and let it detect from the first 30 seconds.
2. **Nothing populates the hint automatically.** Not the system locale, not the
   keyboard layout, not a detected language from a previous run, and no
   onboarding question about a primary language.
3. **Parakeet declares no Language Hint at all**, because it has none: one
   SentencePiece vocabulary spans Latin and Cyrillic and language is a property
   of each emitted token. This is a Capability a model does not have, not a
   Capability set to a default — which is
   [ADR-0017](0017-a-transcription-model-declares-typed-capabilities-not-mode-parameters.md)'s
   reason for existing.
4. **A script-filtering `language:` parameter is not a Language Hint** and must
   not be wired to one if FluidAudio is upgraded past 0.12.x. It suppresses the
   other script rather than informing the model.

## Consequences

- A person who mixes languages leaves every mode on Detect and loses nothing.
  The hint exists for a mode that is known-monolingual, which for this
  project's own author is currently none of them.
- Whisper picks one language per 30-second window even on Detect, so it remains
  the weaker model for mixed speech regardless of this decision. Parakeet's
  per-token implicit language is the better default for EN+RU, with NVIDIA's
  own caveat that it is "not fully tuned" for code-switching.
- A future contributor will find an empty language setting and be tempted to
  helpfully default it from the locale. This ADR is the answer to that.
