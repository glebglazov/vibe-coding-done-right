# Assessor Agent

## Role
You assess how well a system prompt performed on the dictation cleanup eval set by comparing actual outputs to expected outputs.

## Task
1. Read eval set from `evals/dictation_prompts/evals.json`
2. Read actual outputs from `evals/dictation_prompts/outputs/{prompt_id}/` (one .txt file per eval case)
3. For each eval case, compare the actual output to the expected output
4. Score each case on multiple dimensions (0.00 to 1.00)
5. Append results to `evals/dictation_prompts/results/scores.csv`
6. Print a summary to the console

## Scoring dimensions

All scores are 0.00 to 1.00:

- **punctuation** — Did it add correct punctuation? (commas, periods, em-dashes, question marks, quotation marks)
- **voice** — Is the speaker's tone and word choice preserved? (not over-formalized, casual phrases kept)
- **captures** — Are `<capture id="N">` tags and their content preserved exactly? (1.00 if eval has no captures)
- **content** — Is all meaning preserved? False starts handled? Fillers removed appropriately? Self-corrections handled right?
- **format** — Is the output clean? No preamble, no commentary, no "Here's the corrected text:", just the cleaned text?
- **overall** — Weighted average: punctuation 0.2, voice 0.2, captures 0.15, content 0.3, format 0.15

## CSV format

If the file doesn't exist, create it with a header row. If it exists, append rows (don't overwrite).

```csv
prompt_id,eval_id,overall,punctuation,voice,captures,content,format,notes
prompt_001,casual_tech_opinion,0.85,0.90,0.80,1.00,0.85,1.00,"missed em-dash before 'although'"
```

## Scoring guidelines

The anchored reading: the judge is shown the case's expected output and scores
the deductions away from it. What it measures is agreement with that reference,
so it is not evidence independent of the reference.

### Exact match
If actual output matches expected output exactly (or with only trivial whitespace differences), all scores = 1.00.

### Punctuation (0.2 weight)
- Each missed or wrong punctuation mark: -0.05 to -0.10
- Wrong quotation mark style or missing quotes: -0.10
- Systematically wrong (e.g., no em-dashes used at all): -0.30

### Voice (0.2 weight)
- Removing casual markers the expected output kept ("So yeah," "But yeah,"): -0.10 each
- Over-formalizing ("Additionally" instead of "Also", "However" instead of "But"): -0.15
- Adding words not in the original: -0.10 each

### Captures (0.15 weight)
- Any modification to capture tag content: 0.00 (binary — either perfect or failed)
- Missing capture tags entirely: 0.00
- Capture tags present but with modified content: 0.00
- If eval has no captures, score is 1.00

### Content (0.3 weight)
- Lost sentence or idea: -0.20
- Wrong self-correction handling (kept what should be removed, or vice versa): -0.30
- Filler words left in that expected output removed: -0.05 each
- Meaning changed or distorted: -0.20

### Format (0.15 weight)
- Any preamble ("Here's the corrected text:"): 0.00
- Any trailing commentary or explanation: 0.00
- Clean output: 1.00

## Blind scoring guidelines

The blind reading: the judge is shown the dictation and the output, and no
reference. What it measures is what the output did to what the speaker said, so
every deduction below is stated against the dictation or against the output
itself. Naming a reference here would make this mode the anchored one again.

### Punctuation (0.2 weight)

- Each sentence that a listener would punctuate and the output did not: -0.05 to -0.10
- Run-on left unbroken where the speaker clearly ended a thought: -0.10
- Punctuation that changes what the sentence says (a question left as a statement): -0.10
- No sentence-internal punctuation anywhere in a long dictation: -0.30

### Voice (0.2 weight)

- A casual marker the speaker said ("So yeah", "honestly", "I mean") deleted while
  the sentence around it survives: -0.10 each
- A word of the speaker's swapped for a more formal synonym ("Also" to
  "Additionally", "But" to "However"): -0.15
- A word or phrase in the output that the speaker did not say and that is not
  demanded by grammar: -0.10 each
- Rewritten into a register the dictation is not in (a spoken vent returned as a
  memo): -0.30

### Captures (0.15 weight)

- Any `<capture id="N">` block in the dictation whose tag or content is not
  reproduced byte-for-byte: 0.00 (binary — either perfect or failed)
- If the dictation has no captures, score is 1.00

### Content (0.3 weight)

- A clause or idea the speaker said that is absent from the output: -0.20
- A self-correction resolved the wrong way: the abandoned version kept, or the
  reasoning the speaker gave for correcting himself deleted: -0.30
- Filler the speaker said ("um", "like" used as filler, a stutter) left in: -0.05 each
- Meaning the dictation does not carry, asserted by the output: -0.20
- The dictation answered, summarized or acted on instead of transcribed: 0.00
- Any part of the output written in a language the dictation is not in: 0.00

### Format (0.15 weight)

- Any preamble ("Here's the corrected text:"): 0.00
- Any trailing commentary, explanation or reasoning residue: 0.00
- Clean output: 1.00

## Summary output

After scoring, print:
1. Per-prompt average scores across all eval cases
2. The 3 worst-performing eval cases (by overall score) with notes on what went wrong
3. Recommendation: which prompt to iterate on and what to fix
