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
./compare_runs.py ledger/<run-a> ledger/<run-b>   # the two arms side by side
./index_ledger.py                # regenerate ledger/index.md
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


## What a comparison produces

`compare_runs.py` takes two or more ledger directories and lays their arms side
by side. It reads the score files already written beside each run, so it calls no
model, needs no live arm, and does not re-run or re-score anything: adding an arm
to the matrix costs one recording, and comparing it against every arm ever
recorded costs nothing.

Per case and per category it prints two tables:

- **DETERMINISTIC AXIS** — each arm's `word` and `punct`, the per-case winner
  (highest word score; punctuation, then verdict, break the tie), per-category
  means, and the headline counts: cases compared, exact matches per arm, wins per
  arm, ties.
- **JUDGE AXIS** — each arm's `overall`, named with the judge that produced it.

The two axes are separate readings and never combine. Nothing averages them, and
arms judged by different judges — or one judged and one not — are labelled as not
comparable on the judge axis, because a Judge Score holds only within one judge
model. A winner is named only where at least two arms carry a score.

Two arms are compared on a case only where their **Case Fingerprints** agree.
Where they do not — the reference was corrected, or one arm never recorded the
case — the row reads `n/c`, is excluded from every mean and headline count, and
the reason is listed under NOT COMPARABLE. Every other cell is untouched, which
is what lets the eval set grow and its references be corrected without
invalidating the ledger's history. `./test_compare_runs.py` pins that: it
re-records an arm after correcting one case's reference and asserts the affected
row falls out while every other row reads exactly as it did before.

Comparing runs over two different eval sets is refused outright — two eval sets
are never scored against each other.

Finally, DETAIL quotes the reference and each arm's actual output for every
comparable case where the arms differ.

## What the index is

`ledger/index.md` is a browsable table of every run the ledger holds: what
produced it, and its means on each axis. `./index_ledger.py` regenerates it from
the runs themselves, so it cannot drift — never edit it by hand, and re-run the
command after recording, scoring or judging.

## Local models vs Haiku (2026-09-04)

The three-model, two-prompt matrix this whole set exists to produce: `claude-haiku-4-5-20251001`,
`qwen3.5:2b` and `gemma4:e2b`, each on `prompt_lean` and `prompt_readability`, over `evals.json`.
Both local models were pulled via `ollama pull` and confirmed to serve at
`http://127.0.0.1:11434/v1/chat/completions` under `ollama 0.33.2`. All three models ran on
`prompt_lean` before any model ran on `prompt_readability`, so an interrupted matrix would still
answer whether a ceiling belongs to the model or the prompt. All six arms are in the ledger, each
scored on both axes:

| run | word | punct | judge |
|---|---|---|---|
| haiku / prompt_lean | 0.948 | 0.57 | 0.889 |
| qwen3.5:2b / prompt_lean | 0.0 | 0.0 | 0.143 |
| gemma4:e2b / prompt_lean | 0.921 | 0.628 | 0.877 |
| haiku / prompt_readability | 0.977 | 0.831 | 0.955 |
| qwen3.5:2b / prompt_readability | 0.0 | 0.0 | 0.143 |
| gemma4:e2b / prompt_readability | 0.936 | 0.744 | 0.925 |

**qwen3.5:2b violates the output-format requirement (R14) on every one of the 22 cases, on both
prompts.** Its `content` field comes back empty; probing the raw endpoint shows why: with the full
system prompt (~920 prompt tokens for `prompt_lean`), the model spends its entire `max_tokens: 2048`
budget on the `reasoning` field and hits `finish_reason: "length"` before writing an answer. This is
recorded and scored as returned — 0.0 on every axis — not patched around (raising `max_tokens` or
disabling thinking would hide a real failure of this model at this sampling config). `gemma4:e2b`
shows no such leakage; its outputs are clean text with no preamble or reasoning residue.

Measured per-case latency (mean / min / max over 22 cases, from each manifest's `latency_ms`):

| model | prompt | mean | min | max |
|---|---|---|---|---|
| qwen3.5:2b | prompt_lean | 37.9 s | 31.4 s | 77.5 s |
| qwen3.5:2b | prompt_readability | 33.7 s | 31.6 s | 57.3 s |
| gemma4:e2b | prompt_lean | 7.3 s | 3.5 s | 28.4 s |
| gemma4:e2b | prompt_readability | 7.1 s | 3.5 s | 14.1 s |

Both are faster than the 28 s/case reference point from the 9.6 GB model. qwen3.5:2b's latency is
inflated by burning its whole token budget on reasoning it then discards.

`gemma4:e2b` is the only viable local candidate here: on the deterministic axis it tracks Haiku
within noise on both prompts (no large prompt-length gap — the long-prompt risk the vault research
flags does not show up for this model), and the judge axis agrees (0.877 / 0.925 vs Haiku's
0.889 / 0.955). qwen3.5:2b cannot be assessed on content quality at all under this harness's sampling
config, since it never emits one.

Reproduce the six-way comparison from the ledger (no model call, no re-run):

```bash
./compare_runs.py \
  ledger/20260904T101031Z__evals__claude-haiku-4-5-20251001__prompt_lean \
  ledger/20260904T112759Z__evals__qwen3.5-2b__prompt_lean \
  ledger/20260904T114209Z__evals__gemma4-e2b__prompt_lean \
  ledger/20260904T114458Z__evals__claude-haiku-4-5-20251001__prompt_readability \
  ledger/20260904T114536Z__evals__qwen3.5-2b__prompt_readability \
  ledger/20260904T115807Z__evals__gemma4-e2b__prompt_readability
```

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
- `compare_runs.py` — lays recorded arms side by side, on both axes.
- `index_ledger.py` — regenerates `ledger/index.md` from the runs.
- `agents/assessor.md` — the rubric the judge scores against.
- `test_score_run.py` — the metric's own cases.
- `test_judge_run.py` — the judge's rubric arithmetic and its contestant refusal.
- `test_compare_runs.py` — what a comparison may and may not compare.
- `test_runner.py` — the runner the three test files share.
- `ledger/<run-id>/manifest.json` — what produced the run.
- `ledger/<run-id>/outputs/<case>.txt` — the arm's raw output, byte-for-byte.
- `ledger/<run-id>/deterministic.json` — the deterministic scores.
- `ledger/<run-id>/judge.json` — the judge scores, and the judge that produced them.
- `ledger/index.md` — every run in the ledger, generated.
