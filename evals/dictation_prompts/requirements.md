# Dictation Cleanup Prompt Requirements

Requirements derived from analyzing all input-expected output pairs in `dictation_evals.json`. Prompt generators MUST address every requirement below.

## R1. Multilingual support

The prompt must work with any language. The same cleanup principles apply regardless of language (tested with English and Russian). Do not assume English.

## R2. Punctuation

Add missing commas, periods, question marks, colons, and em-dashes. Specific patterns observed:

- **Em-dashes** for asides, parenthetical thoughts, and contrast shifts: "go somewhere — doesn't even matter where", "isn't technical — it's that nobody wants to own it"
- **Colons** to introduce explanations: "basically: you have your primary cache"
- **Commas** at clause boundaries, after introductory phrases, and around parenthetical inserts
- **Question marks** on rhetorical questions: "But that's kind of the point, right?"
- **Periods** to terminate sentences (input often omits them entirely)

## R3. Capitalization

- Fix sentence-start capitalization: "so the way" → "So the way"
- Capitalize proper nouns: "john" → "John", "гугл" → "Google"

## R4. Selective filler word removal

Remove ONLY these specific filler words when they add nothing to meaning:

- "like" (when used as filler, NOT when comparing: "it's like X" stays)
- "you know", "I mean"
- "well" (as weak sentence opener), "so" (as weak opener without meaning)
- "yeah" (as filler, NOT "But yeah" which is a voice marker)
- "uh", "um"
- "ну" (Russian filler)

**KEEP these voice markers (do not remove):**
- "But yeah", "So yeah" — conversational transitions
- "Oh" — reaction marker ("Oh, and I almost forgot")
- "honestly", "actually" — emphasis markers
- "I think" — opinion marker (NOT filler)
- Opening phrases: "So I've been thinking...", "You know what's weird", "Короче"
- Hedging words: maybe, probably, might, I guess

## R5. False start consolidation

When the speaker starts a thought, breaks off mid-sentence, and restarts it, keep only the completed version:

- "we need to. we need to reconsider" → "we need to reconsider"
- "I haven't really. like I haven't taken a proper break" → "I haven't really taken a proper break"
- "that. that tracks" → "that tracks"
- "where. where prices" → "where prices"
- "потому что. ну потому что тесты" → "потому что тесты"

## R6. Self-correction — speaker's own thought

When the speaker changes their own mind mid-thought, collapse to the final decision but KEEP the reasoning:

- "would be React. oh wait actually no Vue would be better because..." → "would be Vue, because..."
- "fly into Lisbon and then maybe. actually wait no Porto might be better" → "fly into Porto"
- "I was going to say Django but. no actually FastAPI makes more sense" → "FastAPI makes more sense"

**IMPORTANT:** Keep the reasoning that follows the correction (the "because..." clause).

## R7. Self-correction — quoting others

When the speaker is REPORTING someone else's self-correction, PRESERVE the correction and wrap it in quotation marks as dialogue:

- Input: "he was like yeah I think we should go with Lisbon. oh wait no not Lisbon I meant Porto"
- Output: he was like "yeah, I think we should go with Lisbon — oh wait, no, not Lisbon, I meant Porto."

This is the hardest requirement. The distinction: if the speaker is narrating their own decision process, collapse it. If they're quoting someone else's words, preserve it as dialogue.

## R8. Quotation marks

Add quotation marks around reported speech:

- "someone says oh we should automate this" → someone says "oh, we should automate this,"
- "he was like yeah I think..." → he was like "yeah, I think..."
- "it would say hey that just cost you $37" → it would say "hey, that just cost you $37"
- "they say I wish I'd spent more time" → they say "I wish I'd spent more time..."

## R9. Number and unit formatting

- "37 dollars" → "$37"
- "400 round trip" → "$400 round trip"
- "70 percent" → "70%"
- Written-out numbers → digits: "thirty seven dollars" → "$37", "two thousand and eight" → "2008", "fifteen percent" → "15%"

## R10. Compound word hyphenation

- "mid April" → "mid-April"
- "in memory" → "in-memory" (when used as compound adjective)
- "copy paste" → "copy-paste"
- "более менее" → "более-менее" (Russian)

## R11. Voice preservation

Keep the speaker's vocabulary, personality, and EXACT phrasing:

- DO NOT replace "But" with "However", "Also" with "Additionally", etc.
- DO NOT add words, ideas, or transitions that weren't in the original
- DO NOT remove opening phrases: "So I've been thinking...", "You know what's weird..."
- DO NOT remove reasoning clauses: "because...", "since..." stay
- DO NOT remove hedging words: maybe, probably, I think, I guess
- Preserve casual vocabulary — the speaker's word choices stay
- Keep ALL content — even if it seems redundant to you

## R12. Trailing incomplete thoughts

Clean up sentences that trail off without a conclusion:

- "but that was last week so." → "but that was last week."
- "need to buy milk and." → "need to buy milk."

## R13. Capture tag preservation

`<capture-N>...</capture-N>` tags and their entire content must be preserved **byte-for-byte**. They always appear at the end of the input, separated from dictated text by `\n\n`. Keep them exactly where they are. Do not modify, reformat, reorder, or remove any content inside capture tags.

## R14. Output format

Return ONLY the cleaned text. No preamble ("Here's the corrected text:"), no trailing commentary, no explanations, no markdown formatting. Just the cleaned text.

## R15. Minor reordering for clarity

Small word-order improvements are acceptable when they clearly improve readability without changing meaning:

- "два дня минимум" → "минимум два дня"
- "hours like three or four" → "three or four hours"

## R16. Sentence structure

- Split long run-on sentences at natural breath points
- But don't over-split — preserve the natural conversational flow
- Don't merge separate ideas into one sentence
- DON'T reorder ideas or move conclusions first — preserve the speaker's narrative flow

## R17. Content preservation (NO restructuring)

**CRITICAL:** Do NOT restructure, compact, or rewrite the speaker's thoughts:

- DON'T remove wordy intros: "So the way X works is basically" stays as-is
- DON'T compact phrases: "a little bit of miso paste, I think" stays
- DON'T remove commentary: "so that's another thing we need to factor in" stays
- DON'T tighten paths to conclusions
- DON'T remove redundant phrasing — if the speaker said it twice, keep both
- DON'T change paragraph structure

The goal is structure cleanup (punctuation, grammar, formatting), NOT content editing.
