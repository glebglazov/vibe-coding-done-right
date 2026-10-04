---
fragment: A08F2782
generation: 0016
branch: master
---

+ Dictionary
  The one shared list of the words, names and fixed texts the user means when they speak, synced between macOS and iOS. Every entry in it is a Spelling Hint, and an entry with Trigger Phrases is also substituted exactly.
  avoid: Vocabulary, Known Terms, Word List, Glossary, Substitutions list
  under: Substitutions

+ Dictionary Entry
  One item in the Dictionary: one Replacement and zero or more Trigger Phrases. It is named by its Replacement. An entry with no Trigger Phrases is a Spelling Hint only; removing an entry's last Trigger Phrase leaves it in the Dictionary as a Spelling Hint.
  avoid: Known Term, Hint Entry, Word, Vocabulary item
  under: Substitutions

+ Spelling Hint
  The use of every Dictionary Entry's Replacement as a preferred spelling. It reaches each Transcription Model that declares the Spelling Hints Capability, and the LLM in every Mode or AI Prompt Mode that calls one. It is a soft hint the model may ignore, never a rule, and it never inserts text the user did not speak.
  avoid: vocabulary boost, context words, custom vocabulary, bias list
  under: Substitutions

~ Transcription Model Capability
  What one Transcription Model declares it can be told, typed by kind rather than as a list of string options — a language hint, a free-text prompt, Spelling Hints. Two Transcription Models differ in which kinds they declare, not merely in the values they accept, which is why Mode Parameter cannot express this. How a model uses a kind is its own business: Whisper turns Spelling Hints into prompt tokens, and Parakeet would turn them into a vocabulary boost.
  was: What one Transcription Model declares it can be told, typed by kind rather than as a list of string options — a language hint, a free-text prompt, a vocabulary boost. Two Transcription Models differ in which kinds they declare, not merely in the values they accept, which is why Mode Parameter cannot express this.
  avoid: model option, transcription parameter, model feature

~ Substitution
  The exact, deterministic swap of a Trigger Phrase for its Dictionary Entry's Replacement in the raw transcript. It applies on both macOS and iOS, in every mode, before any other text processing. Only a Dictionary Entry with Trigger Phrases causes one.
  was: One entry in the shared list that swaps spoken text for fixed text in the raw transcript. It holds one Replacement and any number of Trigger Phrases that produce it, and applies on both macOS and iOS before any other text processing. It is named by its Replacement — that is the thing the user meant — but it is read Trigger Phrases first, in the order the user thinks: what was said, then what it becomes.
  avoid: Variable, Snippet, Macro, Shortcut, Alias, Expansion, variant, mishearing entry
  under: Substitutions

~ Trigger Phrase
  One of the spoken texts that causes a Substitution when it appears in the transcript. A Dictionary Entry has zero or more; they are an unordered set, carry no precedence between them, and each carries its own add and remove stamp so a delete beats a stale add from a device that never saw it. Matched case-insensitively, on whole-word boundaries, longest-match-wins, left-to-right.
  was: One of the spoken texts that activates a Substitution when it appears in the transcript. A Substitution has one or more; they are an unordered set, carry no precedence between them, and each carries its own add and remove stamp so a delete beats a stale add from a device that never saw it. Matched case-insensitively, on whole-word boundaries, longest-match-wins, left-to-right.
  avoid: keyword, alias, shortcut, variable name, variant, form, spelling, heard-as
  under: Substitutions

~ Replacement
  The text the user means, held by a Dictionary Entry — e.g. a correctly spelled name, an email address, a phone number. There is exactly one per entry, and it names the entry wherever the user sees a list of them, though it is shown after the Trigger Phrases. It is always a Spelling Hint; when a Trigger Phrase matches, it is injected into the transcript before filler removal and before AI processing, and is not itself re-scanned for further Trigger Phrases.
  was: The fixed text a Substitution swaps in for any of its Trigger Phrases — e.g. an email address or a correctly spelled name. There is exactly one per Substitution, and it is what names the Substitution wherever the user sees a list of them. Naming is not ordering: the Replacement is what the entry is called and what a list is scanned for, and it is still shown after the Trigger Phrases that produce it. The Replacement is injected into the transcript before filler removal and before AI processing, and is not itself re-scanned for further Trigger Phrases.
  avoid: value, expansion, alias target, correction, term
  under: Substitutions

~ Substitution Convergence
  Two Dictionary Entries holding an identical Replacement are one entry that two devices created separately, and a sync pass merges them into it: the entry made first survives, the Trigger Phrases combine, and the other is deleted. An entry with no Trigger Phrases converges the same way, so a Spelling Hint made on one device and a Substitution for the same Replacement made on another become one entry. It is not a Trigger Phrase Clash.
  was: Two Substitutions holding an identical Replacement are one Substitution that two devices made separately, and a sync pass merges them into it: the entry made first survives, the Trigger Phrases combine, and the other is deleted as any Substitution is. It is not a Trigger Phrase Clash — a clash is two different Replacements competing for one phrase, which the user has to see and settle. Each Trigger Phrase carries when it was added and when it was removed, so combining two devices' phrases never brings back one that someone took off.
  avoid: dedupe, merge conflict, collision, duplicate entry
  under: Substitutions

~ Trigger Phrase Clash
  Two Dictionary Entries claiming the same Trigger Phrase. It is never refused — refusing lands on the user at the moment they are filing a phrase they just discovered. The most recently edited entry wins, and the losing phrase says so where it was typed.
  was: Two Substitutions claiming the same Trigger Phrase. It is never refused — refusing lands on the user at the moment he is filing a phrase he just discovered, which is the moment the feature exists to serve. The most recently edited Substitution wins, and the losing phrase says so where it was typed rather than announcing that something somewhere is wrong.
  avoid: duplicate trigger, conflict, collision, ambiguous match
  under: Substitutions
