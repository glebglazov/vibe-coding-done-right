# ADR-0024: A pinned model is removed with consent; only the Default is refused

## Status

Accepted. Amends [ADR-0018](0018-a-transcription-model-may-be-removed-unless-something-names-it.md)
decision 2, and the first rule of [ADR-0023](0023-a-model-select-offers-only-installed-models.md).

## Context

[ADR-0018](0018-a-transcription-model-may-be-removed-unless-something-names-it.md)
made removal refusable on two grounds: the model is the Default Transcription
Model, or a Mode's Transcription Override points at it. Its second decision was
"removal is refused, never silently repointed" — repointing a Mode changes what
that Mode produces, and doing so unasked is a lie about the gesture.

The refusal is the wrong instrument for the second ground. It leaves the person
holding 1.6 GB they want back, with a chore: open every Mode the message names,
repoint each one at another model, come back, and press Remove. Every one of
those repoints is the same act the refusal was protecting them from — they just
have to perform it by hand, one screen at a time, with no summary of what they
are about to change.

The word "silently" is doing the real work in 0018's second decision. What is
wrong is repointing *without saying so*, not repointing.

There is a second, smaller problem. 0018 and 0023 both say a Mode "names" a
model, and the code with it: `removalRefusal` reads
`settings.modes.filter { … }.map(\.name)`, where `naming` and `name` mean
unrelated things one line apart, and a Mode's `name` is a user-typed string.

## Decision

1. **The Default is refused; a pinned model asks.** Removing the Default
   Transcription Model stays impossible — that refusal is what guarantees a
   model select always has something to offer, which is
   [ADR-0023](0023-a-model-select-offers-only-installed-models.md)'s foundation
   and is untouched here. Removing a model that Modes pin is offered, disclosing
   which Modes pin it and what they will use instead, and waits for consent.
2. **Consent unpins; it does not repoint.** Agreeing clears the model from each
   of those Overrides, so those Modes follow the Default from then on and move
   with it if the Default later changes. Writing the Default's current identity
   into each Override would pin a model nobody chose and quietly sever the Mode
   from the Default it fell back to.
3. **The disclosure names both ends.** "Email and Notes pin Whisper Large V3
   Turbo. Remove it and they will use Parakeet (the Default Model)." A
   consequence the person cannot read is not one they consented to.
4. **A removal with no consequence stays immediate.** Nothing else asks. The
   dialog exists to disclose an effect on other things; putting one in front of
   every removal trains the person to dismiss the one that matters.
5. **The relationship is called a pin.** A Mode's Transcription Override *pins*
   a Transcription Model; clearing it *unpins*. Replaces "names" in the code, the
   glossary and the user-facing copy. It carries the two things the relationship
   actually has — deliberate, and stays put — and it is not a Mode's `name`.
   "Binding" was the other candidate and is rejected: `Binding` is SwiftUI's, in
   use in the very files this vocabulary renders in.

## Consequences

- The refusal type splits. `ModelRemovalRefusal` keeps only `.isDefaultModel`;
  the pinned case becomes a separate consequence type, answered by a dialog
  rather than by a disabled button. A refusal and a consequence are met with
  different gestures, so one type that could be either would make every caller
  re-ask which it was holding.
- A Mode's family-keyed settings patches survive the unpin — only the model is
  cleared. This is 0018's fourth decision applied to the Override: pinning the
  model again later should find its own answers waiting.
- Both platforms move together, Modes and Prompt Modes alike, because the
  refusal type is Shared and would otherwise mean two things.
