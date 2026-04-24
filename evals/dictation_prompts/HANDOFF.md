# Dictation prompt A/B — run + assess

Comparing two system prompts on a 21-case dictation eval set, to decide whether a lean principles-based prompt can replace the current rules+6-examples live prompt without regressing.

## Context

- **A (live)**: `prompts/prompt_readability.txt` — the prompt currently shipped in `vcdr-mac/Core/Settings/BuiltInPrompts.swift` as `defaultDictation`. Has rules + 6 few-shot examples.
- **B (lean)**: `prompts/prompt_lean.txt` — new principles-only prompt, ~1/3 the length, no few-shot examples.
- **Evals**: `evals.json` — 21 cases across 8 categories (readability_transform, voice_preservation, content_preservation, self_correction, realistic_mixed, passthrough, capture, multilingual). Expected outputs encode the *aggressive-readability* target — what a careful human would write if they polished the dictation by hand.
- **Goal**: readability with voice/style preservation. Model: `claude-haiku-4-5-20251001`.

## Run

```bash
cd /workspaces/vibe-coding-done-right/evals/dictation_prompts
export ANTHROPIC_API_KEY=$(op run "op://Private/Anthropic/api_key")
./run_comparison.sh            # ~42 calls (~2-3 min), writes to outputs/
./score_comparison.sh > /tmp/score_report.txt
head -60 /tmp/score_report.txt   # summary + table
cat /tmp/score_report.txt        # full detail, cases where A and B differ
```

If `op` isn't installed, any other way to populate `ANTHROPIC_API_KEY` works — the script just needs it exported.

## What the scorer produces

- **EXACT** — output matches `expected_output` byte-for-byte.
- **NORM** — matches modulo punctuation style (em-dash vs hyphen, curly vs straight quotes) and case.
- **CLOSE** — >90% Jaccard on word tokens (minor wording diff).
- **DIFF** — >75% (noticeable diff).
- **FAIL** — below.

Summary reports: exact-match count per prompt, per-case winner, and per-case diff.

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

- **`jq: error`**: one of the eval inputs may have funny escaping. Inspect with `jq '.evals[INDEX]' evals.json`.
- **Empty outputs / `PARTIAL`**: API errors. Check `curl https://api.anthropic.com/v1/messages ...` manually for one case to see the error.
- **Score looks wrong**: scorer normalizes case and dash/quote styles but treats punctuation attached to words as part of the token. Spot-check the DETAIL section against the raw outputs in `outputs/`.

## Files

- `evals.json` — 21 test cases (fresh set; old set was overwritten).
- `prompts/prompt_readability.txt` — A (current live).
- `prompts/prompt_lean.txt` — B (candidate).
- `prompts/prompt_current.txt` — legacy strict prompt, retained as historical baseline.
- `run_comparison.sh` — runner (direct Anthropic API via curl).
- `score_comparison.sh` — scorer.
- `outputs/evals__prompt_readability/<case>.txt` — A's outputs.
- `outputs/evals__prompt_lean/<case>.txt` — B's outputs.
