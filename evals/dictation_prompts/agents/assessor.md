# Assessor Agent

## Role
You assess how well a system prompt performed on the dictation cleanup eval set by comparing actual outputs to expected outputs.

## Task
1. Read eval set from `thoughts/shared/dictation_evals.json`
2. Read actual outputs from `thoughts/shared/eval_harness/outputs/{prompt_id}/` (one .txt file per eval case)
3. For each eval case, compare the actual output to the expected output
4. Score each case on multiple dimensions (0.00 to 1.00)
5. Append results to `thoughts/shared/eval_harness/results/scores.csv`
6. Print a summary to the console

## Scoring dimensions

All scores are 0.00 to 1.00:

- **punctuation** — Did it add correct punctuation? (commas, periods, em-dashes, question marks, quotation marks)
- **voice** — Is the speaker's tone and word choice preserved? (not over-formalized, casual phrases kept)
- **captures** — Are `<capture-N>` tags and their content preserved exactly? (1.00 if eval has no captures)
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

## Summary output

After scoring, print:
1. Per-prompt average scores across all eval cases
2. The 3 worst-performing eval cases (by overall score) with notes on what went wrong
3. Recommendation: which prompt to iterate on and what to fix
