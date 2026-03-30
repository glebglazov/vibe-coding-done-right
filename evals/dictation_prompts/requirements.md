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

## R4. Aggressive filler word removal

Remove fillers and verbal crutches: "like", "you know", "kind of", "basically", "I mean", "so yeah", "actually", "ну", "короче" (Russian). Also remove hedging phrases that weaken the message: "I think" (when used as a verbal tic, not genuine uncertainty), "sort of", "a little bit".

Remove aggressively — when in doubt, remove. Only keep a filler word if removing it would change the meaning or lose a genuinely casual tone marker.

- REMOVE: "you like actually work" → "you work"
- REMOVE: "basically the launch date is May" → "the launch date is May"
- REMOVE: "I think Jake's version is better" → "Jake's version is better"
- REMOVE: "So yeah, basically" → (just state the conclusion)
- REMOVE: "Oh, and I almost forgot" → "And" or "We also need to"
- KEEP: "I think we need to reconsider" (genuine hedged opinion)
- KEEP: "I think I need to use a different potato" (genuine uncertainty)

## R5. False start consolidation

When the speaker starts a thought, breaks off mid-sentence, and restarts it, keep only the completed version:

- "we need to. we need to reconsider" → "we need to reconsider"
- "I haven't really. like I haven't taken a proper break" → "I haven't really taken a proper break"
- "that. that tracks" → "that tracks"
- "where. where prices" → "where prices"
- "потому что. ну потому что тесты" → "потому что тесты"

## R6. Self-correction — speaker's own thought

When the speaker changes their own mind mid-thought, collapse to the final decision. Remove the initial wrong choice entirely:

- "would be React. oh wait actually no Vue would be better because..." → "would be Vue, because..."
- "fly into Lisbon and then maybe. actually wait no Porto might be better" → "fly into Porto"
- "I was going to say Django but. no actually FastAPI makes more sense" → "FastAPI makes the most sense"

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

## R10. Compound word hyphenation

- "mid April" → "mid-April"
- "in memory" → "in-memory" (when used as compound adjective)
- "copy paste" → "copy-paste"
- "более менее" → "более-менее" (Russian)

## R11. Voice preservation

Keep the speaker's vocabulary and personality. Do NOT over-formalize:

- DO NOT replace "But" with "However", "Also" with "Additionally", etc.
- DO NOT add words, ideas, or transitions that weren't in the original
- Preserve casual vocabulary — the speaker's word choices stay, even if informal
- But DO remove verbal crutches and filler patterns (see R4) — those are not "voice"

## R12. Trailing incomplete thoughts

Clean up sentences that trail off without a conclusion:

- "but that was last week so." → "but that was last week."
- "need to buy milk and." → "need to buy milk."
- "ну такой неприятный когда" → remove the filler lead-in, connect directly

## R13. Capture tag preservation

`<capture id="N">...</capture>` tags and their entire content must be preserved **byte-for-byte**. They always appear at the end of the input, separated from dictated text by `\n\n`. Keep them exactly where they are. Do not modify, reformat, reorder, or remove any content inside capture tags.

## R14. Output format

Return ONLY the cleaned text. No preamble ("Here's the corrected text:"), no trailing commentary, no explanations, no markdown formatting. Just the cleaned text.

## R15. Minor reordering for clarity

Small word-order improvements are acceptable when they clearly improve readability without changing meaning:

- "два дня минимум" → "минимум два дня"
- "hours like three or four" → "three or four hours"
- "a little bit of. I think it was miso paste" → "a little bit of miso paste, I think"

## R16. Sentence structure

- Split long run-on sentences at natural breath points
- But don't over-split — preserve the natural conversational flow
- Don't merge separate ideas into one sentence

## R17. Thought restructuring and compaction

Actively restructure scattered or rambling dictation for clarity:

- If the speaker takes a long time to reach their point, tighten the path — remove redundant phrasing, merge fragmented ideas
- If the same idea is expressed twice in different words, keep the better version and drop the other
- Remove wordy intros: "So the way X works is basically" → "X has two levels:" or similar
- Remove redundant commentary: "so that's another thing we need to factor in" (adds nothing after stating the fact)
- Compact where possible without losing meaning: "a little bit of miso paste, I think" → "miso paste"
- Do NOT reorder ideas or move conclusions first — preserve the speaker's narrative flow
- Do NOT add words or ideas that weren't in the original

## R18. List formatting

When the speaker is clearly listing items (tasks, action items, things to buy, steps), format them as a bullet list:

```
- First item
- Second item
- Third item
```

Use unordered lists (dashes), not numbered lists. Only apply this when the dictation is genuinely a list — not for narrative text that happens to mention multiple things.
