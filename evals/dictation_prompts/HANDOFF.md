# Dictation prompt A/B — run + assess

Comparing two system prompts on a 22-case dictation eval set, to decide whether a lean principles-based prompt can replace the current rules+6-examples live prompt without regressing.

## Context

- **A (live)**: `prompts/prompt_readability.txt` — the prompt currently shipped in `vcdr-mac/Core/Settings/BuiltInPrompts.swift` as `defaultDictation`. Has rules + 6 few-shot examples.
- **B (lean)**: `prompts/prompt_lean.txt` — new principles-only prompt, ~1/3 the length, no few-shot examples.
- **Evals**: `evals.json` — 28 cases across 8 categories (readability_transform, voice_preservation, content_preservation, self_correction, realistic_mixed, passthrough, capture, multilingual). Expected outputs encode the *aggressive-readability* target — what a careful human would write if they polished the dictation by hand. The seven `multilingual` cases each name where their reference was quoted from, in `reference_source`.
- **Goal**: readability with voice/style preservation. Model: `claude-haiku-4-5-20251001`.

## Run

```bash
cd /workspaces/vibe-coding-done-right/evals/dictation_prompts
export ANTHROPIC_API_KEY=$(op-cache read "op://Private/Anthropic/api_key")
./record_run.py --model claude-haiku-4-5-20251001 --prompt prompts/prompt_readability.txt
./record_run.py --model claude-haiku-4-5-20251001 --prompt prompts/prompt_lean.txt
./record_run.py --provider openai-chat --model qwen3.5:2b --prompt prompts/prompt_lean.txt \
                --disable-thinking          # send the setting that turns thinking mode off
./record_run.py --provider s1-mini --model hf.co/superwhisper/s1-mini-GGUF:Q4_K_M \
                --prompt prompts/s1_mini.txt --subset english   # only the cases the arm admits
./record_run.py --provider s1-mini --model hf.co/superwhisper/s1-mini-GGUF:Q4_K_M \
                --prompt prompts/s1_mini.txt --subset multilingual   # the non-English category alone
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
- **LANG** — the output is not written in the languages it was dictated in. A
  translation is a category error, not a bad transcript: every word of it is
  "wrong" and the edit distance reads that as a mildly low score, so it takes a
  verdict of its own and the report names both languages under the table.
- **ERROR** — the arm's call failed; there is no output to score.

- `word` — the primary score: order-sensitive edit distance over the two word sequences. Reordering (R15) and false-start repetition (R5) are what the eval set tests, so both cost here.
- `punct` — the same distance over the punctuation sequence alone (R2), scored apart from words so a comma difference never masquerades as a wording difference.
- `loss` — words the speaker said and the reference kept, dropped from the output (R17).
- `inv` — words in the output that appear in neither the input nor the reference.

A case's languages are read off its script and its function words: Cyrillic names
Russian, the one Cyrillic language in the set, and the two Latin-alphabet
languages are named by the words neither can avoid — which is what keeps `Docker`
and `rkt` inside a Russian sentence from counting as English. The reading is a
set, so half of a code-switched sentence coming back in the other half's language
is named too. Where nothing decides — a text with no function words of either
Latin language — no drift is claimed.

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
  means, and the headline counts: cases compared, cases each arm answered, exact
  matches per arm, wins per arm, ties.
- **JUDGE AXIS** — each arm's `overall`, named with the judge that produced it.

The two axes are separate readings and never combine. Nothing averages them, and
arms judged by different judges — or one judged and one not — are labelled as not
comparable on the judge axis, because a Judge Score holds only within one judge
model. A winner is named only where at least two arms carry a score.

Two arms are compared on a case only where their **Case Fingerprints** agree.
Where they do not — the reference was corrected between the runs — the whole row
reads `n/c`, enters no mean and no headline count, and the reason is listed under
NOT COMPARABLE. Every other cell is untouched, which is what lets the eval set
grow and its references be corrected without invalidating the ledger's history.
`./test_compare_runs.py` pins that: it re-records an arm after correcting one
case's reference and asserts the affected row falls out while every other row
reads exactly as it did before.

A case an arm was never **asked** is a different matter: a subset is a smaller
question, not a different one. That arm's cells read `n/c` with the run that did
not record the case named, and the arms that were asked it are compared on it as
usual. Their per-category mean is annotated `0.813 (7/21)` wherever an arm
answered fewer cases than the category compares, so two means are never read side
by side as though they covered the same cases, and the headline names how many
cases each arm answered.

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

Two of this section's readings are superseded below, by the S1-mini section: `qwen3.5:2b` was
re-measured with thinking off and does answer, and `gemma4:e2b` is no longer the only viable local
candidate. The six rows here stand as the record of what these six arms did.

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

## S1-mini, a purpose-built normalizer (2026-09-04)

A seventh arm: `hf.co/superwhisper/s1-mini-GGUF:Q4_K_M` — a 0.6B text normalizer built for exactly
this workload (Apache 2.0 plus a naming clause; the model keeps the name "S1-mini" by
"Superwhisper"). `ollama pull hf.co/superwhisper/s1-mini-GGUF:Q4_K_M` is the whole install, 484 MB.

**It is comparable on the model axis, not on the prompt axis.** S1-mini is a normalizer, not an
instruction follower: it will not read `prompt_lean` or `prompt_readability`. It requires its own
system prompt, committed verbatim as `prompts/s1_mini.txt`, and a control line
`[Styling: …] [Structure: …] [Context: …]` at the head of every input. That prompt is the model's
own scaffolding rather than a candidate under test, so a row of this arm against a Haiku or gemma
row answers "which model", never "which prompt". Read its numbers against the other models', not
against the two prompts' spread.

**The pinned tone, and what it leaves unmeasured.** One arm, one tone: `Styling: semi-formal`,
`Structure: prose`, `Context: general`. Semi-formal is the register whose output shape matches this
eval set's references — standard written English with contractions kept. Left unmeasured: the other
three registers (`casual`, `semi-casual`, `formal` — the README documents four, not five),
`Structure: lists`, and `Context: email`. A reference set written to the aggressive-readability
target cannot score those; measuring them needs references written for them. The model's published
94.8% token accuracy is on its own held-out English set, not on this one, and the two numbers do not
answer each other.

**English only, so it answers a subset of the one eval set.** `evals.json` names its subsets;
`english` is every case outside the `multilingual` category, and `--subset english` records those 21.
No copy of the eval set was made. In a comparison, the cases this arm was not asked read `n/c` in
its own columns with the run named, and the arms that were asked them are compared as usual.

The "English only" part of that was an assumption, not a measurement. It has since been measured —
see [The multilingual reading](#the-multilingual-reading-2026-09-04): the arm answers German better
than it answers Russian, and its Russian failures are silent ones.

**Thinking off is a property of the arm.** Every arm now records `arm.thinking_disabled` in its
manifest — what it sent to turn thinking off, or `null` where it sent nothing:

- `--provider openai-chat --disable-thinking` sends `reasoning_effort: "none"`. This is what
  `qwen3.5:2b` needed; `chat_template_kwargs` and ollama's `think: false` are both ignored on that
  endpoint.
- `--provider s1-mini` cannot use any request field: the chat template ollama builds for this GGUF
  opens a `<think>` block it never closes, and the model — trained with thinking off — answers with
  an empty string through `/v1/chat/completions` whatever is sent. So the arm posts to
  `/api/generate` with `raw: true` and writes the documented turn layout itself, empty think block
  included. That prefix is the setting, and the manifest records it.

**Where S1-mini lands** (means over the 21 English cases, from the comparison below):

| category | S1-mini | haiku / prompt_readability | gemma4:e2b / prompt_readability |
|---|---|---|---|
| readability_transform (6) | 0.799 | 0.99 | 0.877 |
| voice_preservation (3) | 1.0 | 1.0 | 1.0 |
| content_preservation (3) | 0.963 | 0.947 | 0.987 |
| self_correction (2) | 0.865 | 1.0 | 0.834 |
| realistic_mixed (4) | 0.971 | 0.947 | 0.954 |
| passthrough (2) | 1.0 | 0.974 | 1.0 |
| capture (1) | 1.0 | 1.0 | 1.0 |

Headline, deterministic axis: 21 compared, 1 n/c; S1-mini exact 3 / wins 2, Haiku exact 10 / wins 9,
gemma exact 4 / wins 2, 8 ties. Judge axis (claude-opus-5 throughout): S1-mini 3 wins, Haiku 9,
gemma 2, 7 ties; run-level judge overall 0.897 for S1-mini against 0.955 (Haiku) and 0.925 (gemma) —
but those two run-level means include `russian_mixed` and S1-mini's does not, so the per-category
table above is the honest read.

It loses where the eval set asks for a *rewrite* rather than a normalization: fronting a trailing
"I think", de-duplicating a tic, reading "weeks, like 3 to 4" as "three to four weeks". It wins on
the long realistic cases, where the bigger models over-edit and it does not. It preserves captures
and passthroughs perfectly.

**Latency.** 0.31 s/case mean (min 0.08 s, max 2.02 s, 6.5 s for all 21 cases) — roughly 23× faster
than `gemma4:e2b` at ~7.1 s/case, and 3–5× faster than Haiku's cloud round trip at 1.07–1.41 s/case,
with no network in the path at all.

### qwen3.5:2b, measured again with thinking off

The earlier `qwen3.5:2b` runs scored 0.0 on every axis because the model burned its whole
`max_tokens` budget on a `reasoning` field. That was a reading of one sampling config, not of the
model. Both are re-recorded with `--disable-thinking`; the zero-scoring runs stay in the ledger
untouched, as the record of what that config does.

| run | word | punct | judge | mean latency |
|---|---|---|---|---|
| qwen3.5:2b / prompt_lean, thinking on | 0.0 | 0.0 | 0.143 | 37.9 s |
| qwen3.5:2b / prompt_lean, thinking off | 0.837 | 0.529 | 0.803 | 1.2 s |
| qwen3.5:2b / prompt_readability, thinking on | 0.0 | 0.0 | 0.143 | 33.7 s |
| qwen3.5:2b / prompt_readability, thinking off | 0.892 | 0.696 | 0.836 | 1.8 s |

With thinking off the model answers, ~30× faster, and lands below both `gemma4:e2b` and S1-mini on
both axes. It is the only local arm that still loses content at scale (83 words dropped and 53
invented on `prompt_lean`, mostly on `capture_with_code` and `russian_mixed`).

Reproduce the three-way model comparison from the ledger (no model call, no re-run):

```bash
./compare_runs.py \
  ledger/20260904T142156Z__evals-english__hf.co-superwhisper-s1-mini-GGUF-Q4_K_M__s1_mini \
  ledger/20260904T114458Z__evals__claude-haiku-4-5-20251001__prompt_readability \
  ledger/20260904T115807Z__evals__gemma4-e2b__prompt_readability
```

## The multilingual reading (2026-09-04)

The non-English category was one case, so the question the whole local-model decision rests on was
a single data point — and the purpose-built normalizer had been excused from it on an assumption
nobody had measured. The category now holds seven cases, and every candidate arm is recorded
against all seven.

**The seven cases, and where their references come from.** A reference written by an arm under test
measures nothing, and one written by the model family that wrote the existing references measures
little more. So every new reference is quoted from a named source, and each case carries a
`reference_source` field saying what was quoted:

| case | what it asks | reference |
|---|---|---|
| `russian_mixed` | Russian, reordering + punctuation | authored with the original set by Claude — the legacy case, now flagged as such |
| `russian_monolingual` | Russian, sentence boundary + commas | Tatoeba #1682438 |
| `russian_with_english_terms` | `Kubernetes`, `K8s`, `Docker`, `rkt` inside Russian sentences | ru.wikipedia «Kubernetes», revision 152709276 |
| `russian_english_code_switch` | Russian frame, English clause, mid-sentence | Tatoeba #13259226 spliced with its own human translation #11611733 |
| `german_monolingual` | German, noun capitalization + sentence boundary | Tatoeba #5683711 |
| `german_passthrough` | already correct German, must come back unchanged | Tatoeba #12567092 |
| `russian_capture_tag` | Russian prose around a `<capture id="1">` block | Tatoeba #7862116 and #7110376; the block quotes `Shared/Substitutions/SubstitutionTombstone.swift` |

Each input is derived from its reference by one recorded rule — lowercased, punctuation removed, a
contraction's apostrophe kept — so no input carries an answer its reference does not. These are
published sentences read aloud rather than spontaneous speech: they measure punctuation,
capitalization and language preservation, and they do not measure disfluency repair. The 21 English
cases already do that.

**Where the arms land** (all seven cases, both axes, judge `claude-opus-5`):

| arm | word | punct | judge | LANG | mean latency |
|---|---|---|---|---|---|
| `claude-haiku-4-5-20251001` / prompt_readability | 0.916 | 0.906 | 0.911 | 1 | 1.02 s |
| `gemma4:e2b` / prompt_readability | 0.97 | 0.89 | 0.939 | 0 | 7.41 s |
| `qwen3.5:2b` / prompt_readability, thinking off | 0.857 | 0.611 | 0.737 | 1 | 2.20 s |
| S1-mini / s1_mini, `--subset multilingual` | 0.813 | 0.615 | 0.752 | 1 | 0.25 s |

- **`gemma4:e2b` is the only arm that answered every case in the language it was dictated in.** It
  is also the only one that kept the code-switched sentence intact, byte-for-byte. Its weakness is
  German punctuation: it merged the two German sentences into one (`punct` 0.333).
- **Haiku is the strongest arm and still fails the code-switch**, translating the English clause into
  Russian. A cascade that falls back to the cloud does not fix that failure — it shares it.
- **`qwen3.5:2b` invents a capture tag.** It wrapped two Russian answers in `<capture id="1">…</capture>`
  that no input contained (22 invented words, judge `format` 0.0 on both), and translated the
  code-switched clause. Its German punctuation scored 0.0.
- **S1-mini damages the opening word of Russian input**: «слушай» → «Лучай» and «у меня» → «Мне», in
  two of its four Russian prose cases. It also dropped a whole `<capture>` block (15 words lost,
  judge `captures` 0.0) and translated the code-switched clause. German is its best category — both
  German cases at `word` 1.0, the passthrough EXACT — which is the opposite of the "English-only"
  assumption it was excused under.

**The corruption is the model, not the harness.** Same Russian input, temperature 0, six layouts:

| layout | answer |
|---|---|
| raw + empty think block (the arm's own) | «Лучай я думаю …» — first word corrupted |
| raw + empty think block, control line removed | «Нам нужно переехать …» — first word dropped |
| raw + a non-empty think block | the model continued the think text and answered nothing else |
| raw + no think block | empty string |
| `/v1/chat/completions`, ollama's template | empty string |
| `/api/generate`, ollama's template | empty string |

Every layout that answers at all damages the first word, and the recorded run shows the same damage
on a second Russian case. So the finding is attributed to the model.

The decision gate's other probe — German answered in English — **did not reproduce**. Both German
cases came back in German from all four arms, and two further German probes through the same arms
(one carrying a negation) came back in German too. The LANG verdict exists regardless, and what it
catches on the record is the code-switch: three of four arms answered `en+ru` with `ru`.

**A non-word cannot be named here, so the reference names it.** «Лучай» is a real word replaced by a
non-word, and deciding that needs a Russian lexicon. The deterministic axis is a pure function of
the case and the output — the same numbers from a fresh checkout forever — and a system
spell-checker is neither pinned nor present (this machine has an English `/usr/share/dict/words`,
and no `hunspell` or `aspell`); shipping a Russian word list into the repository to score one case
is not worth its weight. So the corruption is caught by the reference instead: `inv` counts a word
appearing in neither the input nor the reference, which is exactly what «Лучай» is, and the judge
scored that case 0.59 with `content` 0.5.

**What the widened category leaves unmeasured.** Term capitalization: the normalizer folds case as
harmless style, so S1-mini's `Rkt` for `rkt` costs nothing on the word axis and only the judge saw
it. Two languages: Russian and German, on read-aloud prose. And the two mixed-script cases — the
code-switch and the capture block — are the cases where a language cannot be named from one text, so
`languages()` abstains on their inputs; drift is caught there only because the *output* named one
language while the input named two.

**What it means for a cascade fallback.** A local stage is out of its depth on non-English exactly
where the failure is silent — nothing errors, nothing comes back empty. Read `LANG` and the capture
check as fallback triggers, not the word score: a translation punctuates perfectly (`punct` 1.0 on
the code-switch for every arm) and scores 0.5 on words, which no threshold separates from an
ordinary near miss. And do not read a cloud fallback as a fix for code-switching, since Haiku
translates it too.

Reproduce the four-arm reading, and then the same four beside the arm that was excused from the
category (no model call, no re-run):

```bash
./compare_runs.py \
  ledger/20260904T153759Z__evals-multilingual__claude-haiku-4-5-20251001__prompt_readability \
  ledger/20260904T153651Z__evals-multilingual__gemma4-e2b__prompt_readability \
  ledger/20260904T153743Z__evals-multilingual__qwen3.5-2b__prompt_readability \
  ledger/20260904T153649Z__evals-multilingual__hf.co-superwhisper-s1-mini-GGUF-Q4_K_M__s1_mini \
  ledger/20260904T142156Z__evals-english__hf.co-superwhisper-s1-mini-GGUF-Q4_K_M__s1_mini
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
- **"has changed since ... was recorded"**: the eval set grew or a reference was edited after the run. The archived outputs no longer answer that set, so the run cannot be rescored or re-judged — re-record the arm. Its already-written score files stay valid and still compare, case by case, against any later run. Every run recorded before the multilingual category was widened is in that state.
- **Score looks wrong**: `./test_score_run.py` pins the metric against the three differences it was built to rank correctly. Otherwise spot-check `ledger/<run-id>/outputs/<case>.txt` against `expected_output` — the raw output is kept byte-for-byte.

## Files

- `evals.json` — 28 test cases (fresh set; old set was overwritten), the named subsets an arm may be asked instead of all of them, and each multilingual case's `reference_source`.
- `evals_role_boundary.json` — 9 role-boundary cases, scored on the same axis.
- `prompts/prompt_readability.txt` — A (current live).
- `prompts/prompt_lean.txt` — B (candidate).
- `prompts/prompt_current.txt` — legacy strict prompt, retained as historical baseline.
- `prompts/s1_mini.txt` — S1-mini's required system prompt, verbatim; not a candidate prompt.
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
