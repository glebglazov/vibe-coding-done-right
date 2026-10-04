# The Dictionary holds Spelling Hints beside Substitutions

Users want the app to spell some words right without first finding out how the engine misspells them: their name, a phone number, a product name. That is a list of words the user means, and every Replacement already is one. So there is one list, the **Dictionary**, and not a second list beside Substitutions. A Trigger Phrase becomes optional: a Dictionary Entry with no Trigger Phrases is a Spelling Hint only, and an entry with Trigger Phrases is a Spelling Hint and is also substituted exactly. This reverses "a Substitution has one or more Trigger Phrases".

Every Replacement is a Spelling Hint in two places: the Transcription Model's vocabulary mechanism (Whisper's prompt today, Parakeet's vocabulary boost when it ships) and the system prompt of every Mode or AI Prompt Mode that calls an LLM. A Spelling Hint never causes an AI call by itself.

## Considered options

- **A second list of Known Terms, Substitutions unchanged.** Rejected: the same name could live in both lists, and Substitution Convergence could not merge a hint made on one device with a Substitution for the same Replacement made on another. Every Replacement would also have to be copied by hand to get its spelling hinted.
- **Hints to the LLM only.** Rejected: Verbatim and non-AI Modes would gain nothing, and the word would reach the LLM already misspelled. ADR-0017 already chose Whisper's prompt as the vocabulary mechanism.

## Consequences

- "Substitution" now names the act of swapping a Trigger Phrase for its Replacement, not the list item. The user-facing list is renamed to Dictionary on both platforms.
- Removing the last Trigger Phrase of an entry keeps the entry as a Spelling Hint. Deleting an entry is a separate, explicit act.
- Whisper's prompt is shared between the Vocabulary Prompt the user types and the Spelling Hints, inside the visible ~200-token cap. Spelling Hints that do not fit are left out, and the settings screen says how many. A long prompt is a known cause of Whisper repeat loops (ADR-0017), so the cap is not raised for the Dictionary.
- Spelling Hints are sent to the cloud LLM provider with every AI request, including a phone number if the user adds one. The Dictionary screen says so.
- Another device on an older build will receive entries with zero live Trigger Phrases. The record format can already hold that state (every phrase removed), but older builds must be checked to show such an entry and not drop or reject it.
