# Dictation prompt A/B — run + assess

Comparing two system prompts on a 22-case dictation eval set, to decide whether a lean principles-based prompt can replace the current rules+6-examples live prompt without regressing.

## Context

- **A (live)**: `prompts/prompt_readability.txt` — the prompt currently shipped in `vcdr-mac/Core/Settings/BuiltInPrompts.swift` as `defaultDictation`. Has rules + 6 few-shot examples.
- **B (lean)**: `prompts/prompt_lean.txt` — new principles-only prompt, ~1/3 the length, no few-shot examples.
- **Evals**: `evals.json` — 22 cases across 8 categories (readability_transform, voice_preservation, content_preservation, self_correction, realistic_mixed, passthrough, capture, multilingual). Expected outputs encode the *aggressive-readability* target — what a careful human would write if they polished the dictation by hand.
- **Goal**: readability with voice/style preservation. Model: `claude-haiku-4-5-20251001`.

## Run

```bash
cd /workspaces/vibe-coding-done-right/evals/dictation_prompts
export ANTHROPIC_API_KEY=$(op-cache read "op://Private/Anthropic/api_key")
./record_run.py --model claude-haiku-4-5-20251001 --prompt prompts/prompt_readability.txt
./record_run.py --model claude-haiku-4-5-20251001 --prompt prompts/prompt_lean.txt
./score_run.py ledger/<run-id>   # per-case table, and ledger/<run-id>/deterministic.json
./judge_run.py ledger/<run-id>   # rubric scores, and ledger/<run-id>/judge.json
```

If `op-cache` isn't installed, any other way to populate `ANTHROPIC_API_KEY` works — the script just needs it exported.

Recording costs one API call per case; deterministic scoring costs nothing and calls no model. Judging costs one judge call per case. Both read the ledger only, so any archived run can be rescored and re-judged at any time and never has to be re-run to be compared.

## What the scorer produces

Per case, a verdict and four numbers:

- **EXACT** — output matches `expected_output` byte-for-byte.
- **NORM** — matches modulo dash style, quote style, case and whitespace.
- **CLOSE** / **DIFF** / **FAIL** — `word` above 0.9 / above 0.75 / below.
- **ERROR** — the arm's call failed; there is no output to score.

- `word` — the primary score: order-sensitive edit distance over the two word sequences. Reordering (R15) and false-start repetition (R5) are what the eval set tests, so both cost here.
- `punct` — the same distance over the punctuation sequence alone (R2), scored apart from words so a comma difference never masquerades as a wording difference.
- `loss` — words the speaker said and the reference kept, dropped from the output (R17).
- `inv` — words in the output that appear in neither the input nor the reference.

`loss` and `inv` are the over-editing signal. On the role-boundary set they also read as obedience: a model that answered the dictated instruction instead of transcribing it invented most of what it wrote.

## What the judge produces

`judge_run.py` reads the same archived outputs and has a model grade them against
`agents/assessor.md` — the six-dimension rubric, whose weights it parses out of
that document rather than restating them. It reaches what no deterministic number
does: whether the speaker's voice survived, and whether the model over-edited.

The standing judge is `claude-opus-5`, pinned with `--judge-model`. Haiku is a
contestant in this matrix, so it cannot judge; a run recorded with the same model
named as judge is refused outright.

A Judge Score is reproducible only within one judge model. So it lands in
`judge.json` beside — never inside — `deterministic.json`, every case carries the
judge's model id, and the two axes are read side by side. Nothing averages them
together, and Judge Scores from different judges are not comparable.


## What to report back

**Headline**: A exact / B exact / A-wins / B-wins / ties.

**Key per-category question**: does B (lean) regress in any *specific* category compared to A (live)? E.g., does dropping the few-shot examples hurt `readability_transform` cases that used to have direct examples (trailing_hedge_fronted, list_collapse_and, cascade_conditions_preserved, self_correction_quoted)?

**Flag regressions by severity**:
- **Content loss** (dropped words, rewrote dialogue inside quotes): serious — block shipping.
- **Style drift** (flattened voice, substituted vocabulary, dropped opener like "So"): medium — likely block or require targeted fix.
- **Punctuation differences** (colon vs period, em-dash vs comma): style — fine.

**Recommendation**: one of
1. **Ship B (lean)** — if B matches A within noise or wins overall with no serious regressions.
2. **Keep A (live)** — if B drops measurably on multiple categories.
3. **Iterate** — if B regresses on exactly 1-2 patterns that would need a targeted few-shot added back (name them).

Include:
- The summary table (case × category × A score × B score × winner).
- 3-5 illustrative diffs (pick the most informative — prefer real regressions and clean wins over style-only differences).
- A one-line recommendation.

## If things go wrong

- **`ERROR` verdicts**: the arm's call failed at record time; the manifest holds the error per case. Re-record that arm.
- **"has changed since ... was recorded"**: a reference output was edited after the run. The archived outputs no longer answer those cases — re-record the arm against the new eval set.
- **Score looks wrong**: `./test_score_run.py` pins the metric against the three differences it was built to rank correctly. Otherwise spot-check `ledger/<run-id>/outputs/<case>.txt` against `expected_output` — the raw output is kept byte-for-byte.

## Files

- `evals.json` — 22 test cases (fresh set; old set was overwritten).
- `evals_role_boundary.json` — 9 role-boundary cases, scored on the same axis.
- `prompts/prompt_readability.txt` — A (current live).
- `prompts/prompt_lean.txt` — B (candidate).
- `prompts/prompt_current.txt` — legacy strict prompt, retained as historical baseline.
- `record_run.py` — records one arm over one eval set into the ledger.
- `ledger.py` — the ledger itself: fingerprints, and reopening an archived run.
- `score_run.py` — the deterministic scorer.
- `judge_run.py` — the judge-axis scorer.
- `agents/assessor.md` — the rubric the judge scores against.
- `test_score_run.py` — the metric's own cases.
- `test_judge_run.py` — the judge's rubric arithmetic and its contestant refusal.
- `ledger/<run-id>/manifest.json` — what produced the run.
- `ledger/<run-id>/outputs/<case>.txt` — the arm's raw output, byte-for-byte.
- `ledger/<run-id>/deterministic.json` — the deterministic scores.
- `ledger/<run-id>/judge.json` — the judge scores, and the judge that produced them.
