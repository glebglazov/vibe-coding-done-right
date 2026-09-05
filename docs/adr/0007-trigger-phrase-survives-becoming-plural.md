# Trigger Phrase stays the name when a Substitution holds many of them

A Substitution now holds one Replacement and any number of input phrases, and the input side keeps the name it already had: **Trigger Phrase**, plural **Trigger Phrases**, shown to the user as "Triggers". The alternatives were all built on the premise that the relation is *mishearing* — the engine returns "power zha" for "Powierża" and the user files the wrong shape against the right word. That premise describes half the feature. The glossary's own worked examples of a Trigger Phrase are `"oh my zsh"` and `"my personal email"`: nobody mishears those, the user says them deliberately so they expand into fixed text. A name drawn from mishearing quietly narrows a feature that already does two things.

## Considered options

- **Heard as** — the strongest of the mishearing names, and it reads as a sentence in the UI: *Powierża — heard as: "power zha", "powerja"*. Rejected because it is a claim about how the phrase got there, and for a deliberate spoken shortcut the claim is false. Adopting it would mean repositioning Substitutions as mishearing-correction only and rewriting the shortcut examples out of the glossary — a real option, but not the one taken.
- **Variants / Forms / Spellings** — same defect with less precision. "Variant of what?" has no answer for `"my personal email"`, whose Replacement is an email address it is not a variant of.
- **Aliases** — accurate for both uses, and already on the glossary's `avoid` list for exactly the reason it is rejected here: it is a programmer's word sitting on a label the user reads every time the feature is opened.
- **Triggers alone, as the domain term** — says what they do, not what they are, which is the right trade for a UI label and the wrong one for a glossary entry. Kept as the label; Trigger Phrase remains the term.

## Consequences

- No migration of recorded language: the term is already in the Shared glossary, in `Substitution.swift`, and in the substitutions-as-per-entry-files decision. Only its cardinality changes.
- The name stays honest if the feature grows a third use. It commits to nothing about *why* a phrase produces the Replacement, which is the property that made the mishearing names fragile.
- Both apps use "Triggers" verbatim. Where the two interfaces differ they differ in layout, never in wording.
