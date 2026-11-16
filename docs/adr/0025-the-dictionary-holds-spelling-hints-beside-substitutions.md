# The Dictionary holds Spelling Hints beside Substitutions

> **Amended by [ADR-0026](0026-a-dictionary-note-reaches-only-modes-that-rewrite-what-was-said.md):** a Dictionary Entry can
> hold a Note. It goes with its spelling to Dictation prompts only. Custom prompts and
> every Transcription Model still get the spellings alone.

Users want the app to spell some words right without first finding out how the engine misspells them: their name, a phone number, a product name. That is a list of words the user means, and every Replacement already is one. So there is one list, the **Dictionary**, and not a second list beside Substitutions. A Trigger Phrase becomes optional: a Dictionary Entry with no Trigger Phrases is a Spelling Hint only, and an entry with Trigger Phrases is a Spelling Hint and is also substituted exactly. This reverses "a Substitution has one or more Trigger Phrases".

Every Replacement is a Spelling Hint in two places. The first is the transcription adapter: Spelling Hints are a Transcription Model Capability, a run hands the Dictionary's hints to the provider, and each model that declares the Capability decides how to use them. Whisper declares it and turns them into prompt tokens. Parakeet does not declare it yet; its vocabulary boost (ADR-0017) is how it will. The second is the system prompt of every Mode or AI Prompt Mode that calls an LLM. A Spelling Hint never causes an AI call by itself.

## Considered options

- **A second list of Known Terms, Substitutions unchanged.** Rejected: the same name could live in both lists, and Substitution Convergence could not merge a hint made on one device with a Substitution for the same Replacement made on another. Every Replacement would also have to be copied by hand to get its spelling hinted.
- **Write the hints into Whisper's free-text prompt setting.** Rejected: that ties a synced, cross-model list to one family's settings, and a second model with a different hint mechanism would need its own copy. A Capability lets each model take the same list its own way, and a model that cannot take it says so.
- **Hints to the LLM only.** Rejected: Verbatim and non-AI Modes would gain nothing, and the word would reach the LLM already misspelled. ADR-0017 already chose Whisper's prompt as the vocabulary mechanism.

## Consequences

- "Substitution" now names the act of swapping a Trigger Phrase for its Replacement, not the list item. The user-facing list is renamed to Dictionary on both platforms.
- Removing the last Trigger Phrase of an entry keeps the entry as a Spelling Hint. Deleting an entry is a separate, explicit act.
- A model's settings screen shows whether it uses the Dictionary, because the screen is built from its Capabilities. Parakeet's screen says it does not use it yet.
- Inside Whisper's adapter, the Vocabulary Prompt the user types and the Spelling Hints share one prompt-token budget. Spelling Hints that do not fit are left out, and Whisper's settings screen says how many. A long prompt is a known cause of Whisper repeat loops (ADR-0017), so the budget is not raised for the Dictionary.
- Spelling Hints are sent to the cloud LLM provider with every AI request, including a phone number if the user adds one. The Dictionary screen says so.
- Another device on an older build will receive entries with zero live Trigger Phrases. No build since the Trigger Phrase list drops or rejects such an entry, and the matcher of every build skips an empty phrase. A build from before the list titles it "New Substitution", which is cosmetic.
- A retry sends the hints the platform's retry already reads: macOS replays the original attempt, hints included; iOS reads the Dictionary again, as it already reads the current mode and style again.
