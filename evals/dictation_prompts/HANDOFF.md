# Dictation prompt A/B — run + assess

Comparing two system prompts on a 28-case dictation eval set, to decide whether a lean principles-based prompt can replace the current rules+6-examples live prompt without regressing.

## Context

- **A (live)**: `prompts/prompt_readability.txt` — the prompt currently shipped in `vcdr-mac/Core/Settings/BuiltInPrompts.swift` as `defaultDictation`. Has rules + 6 few-shot examples.
- **B (lean)**: `prompts/prompt_lean.txt` — new principles-only prompt, ~1/3 the length, no few-shot examples.
- **Evals**: `evals.json` — 28 cases across 8 categories (readability_transform, voice_preservation, content_preservation, self_correction, realistic_mixed, passthrough, capture, multilingual). Expected outputs encode the *aggressive-readability* target — what a careful human would write if they polished the dictation by hand. The seven `multilingual` cases each name their reference's origin in `reference_source`, and every case names where its reference came from in `reference_provenance` — see [Where the answer key came from](#where-the-answer-key-came-from-2026-09-04) before reading any score as model quality.
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
./record_run.py --provider apple --model apple-afm \
                --prompt prompts/prompt_readability.txt --subset english   # the on-device model
./score_run.py ledger/<run-id>   # per-case table, and ledger/<run-id>/deterministic.json
./judge_run.py ledger/<run-id>                    # blind: no reference shown -> judge_blind.json
./judge_run.py --mode anchored ledger/<run-id>    # the reference too -> judge.json
./compare_runs.py ledger/<run-a> ledger/<run-b>   # the two arms side by side
./index_ledger.py                # regenerate ledger/index.md
```

The key is for the arms. `judge_run.py` reaches its judge through the local Claude Code CLI by default and spends that subscription instead, so a judge pass runs whether or not the key has a balance; `--via api` calls the Anthropic API with the key as it did before. The two are not interchangeable readings — see "One judge, one transport, one mode" below.

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

### The two judge modes, and what each measures

`--mode blind` (the default) shows the judge the dictation and the arm's output,
and nothing else: no expected output, and not the eval set's `exercises` line
either, which names the transformation the reference wants in prose. It scores
against `agents/assessor.md`'s **Blind scoring guidelines**, whose every deduction
is stated against the dictation or the output itself. **This is the mode that is a
second opinion**: it can disagree with the reference, because it has never seen it.

`--mode anchored` shows the judge the expected output too, and scores against the
**Scoring guidelines**, which open with "if actual output matches expected output
exactly, all scores = 1.00" and define every dimension as deductions away from
that reference. **An anchored Judge Score is not evidence independent of the
reference**, and so not independent of the deterministic axis either, which is a
pure function of that same reference. Where the two axes agreed under this mode,
the agreement was a property of the shared anchor.

The modes are kept apart the way the axes are:

- Two files. Blind lands in `judge_blind.json`, anchored in `judge.json`; neither
  overwrites the other, and a file whose recorded mode disagrees with the file it
  sits in is refused rather than read as either.
- The mode is on the file (`judge.mode`) and on every case (`judge_mode`), because
  these rows get copied around. A file written before the modes were told apart
  names none and is the anchored reading — that is what its judge saw.
- A comparison prints one table per mode and never one column holding both, and
  `ledger/index.md` carries one judge column per mode.
- Nothing averages a blind score with an anchored one, or either with a
  Deterministic Score.

A blind rubric that named a reference would be an anchored rubric under another
name, so `judge_run.py` refuses to judge blind if the rubric sections it applies
mention an expected or reference output at all.

### One judge, one transport, one mode

A Judge Score is reproducible only within one judge model, one transport and one
mode. Every case carries the model and the mode; the run's judge record carries
the transport as its `runtime`. Nothing averages them together, and Judge Scores
from different judges are not comparable.

The transport is part of the identity because only the API backend can pin
sampling: `--via api` sends `temperature: 0`, and the CLI exposes no such setting,
so a reading taken through it records `temperature: null` — not zero, but *not
claimed*. The same judge model over two samplings is two measurements, and
`compare_runs.py` marks a judge column whose arms were not all read through the
same one.

The CLI judge is an agent, which the API judge is not, so two things are fixed in
the backend rather than left to whoever runs it: it is given no tools at all, and
the project's own configuration is kept out of its context. An agent holding a
file tool could open `evals.json` and find the reference, and a blind reading
taken by a judge that has seen the reference is an anchored reading with extra
steps.


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
- **JUDGE AXIS (blind)** and **JUDGE AXIS (anchored)** — one table per judge mode,
  each arm's `overall`, named with the judge that produced it. An arm read in the
  other mode is unscored here and wins nothing here.

The two axes are separate readings and never combine. Nothing averages them, and
arms judged by different judges — or through different transports, or by different
modes, or one judged and one not — are labelled as not comparable on the judge
axis, because a Judge Score holds only within one judge model, one transport and
one mode. An arm whose judge only got partway through it carries the case count it
was read over, since a mean over part of a run is not the run's score. A winner is named only where at
least two arms carry a score in the same mode.

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

## Where the answer key came from (2026-09-04)

Both scored axes measure distance from `expected_output`, so what a score means
depends on where that text came from. Every case in `evals.json` and
`evals_role_boundary.json` now names a `reference_provenance` record, and the
records sit once at the top of each set: the commit the reference was authored
in, who authored it, the candidate prompt (if any) it was fitted toward, and the
evidence for that. A case naming no record — or one its set does not define —
reads as **unknown**, and is never given the origin its neighbours carry. No case
in either set is unknown today.

Provenance is written beside a reference, never into one. The Case Fingerprint is
the input and the reference alone, so every run already in the ledger compares
exactly as it did before; `./test_compare_runs.py` pins that a pre-existing
comparison reads identically after the provenance is recorded.

**What the history says.** `git log --follow` on `evals.json` gives seven
commits. Two of them revised expected outputs toward a candidate prompt: `c71bb88`
("toward aggressive compaction and restructuring", 17 outputs changed, reporting
`prompt_007` scoring best against the outputs it had just moved) and `7be5444`
("use prompts which modify text less", 23 changed). **Neither reaches any case in
the set today**: `97a3139` replaced all 22 cases with fresh ones, and no input or
expected output now here is carried over from the cases those two revisions
touched — the closest surviving match to any pre-`97a3139` case is under half
similar and shares no text. The revised outputs are gone with the cases that held
them.

The fit that does survive is `97a3139`'s own, and it is the tighter one:

- The 21 English cases and `russian_mixed` were authored **in the same commit**
  that added `prompts/prompt_readability.txt` and `prompts/prompt_lean.txt`, and
  that commit reports `prompt_readability` winning 12/22 EXACT against those very
  expected outputs. The set description written there names the
  aggressive-readability target, which is `prompt_readability`'s design goal. The
  commit carries a `Co-Authored-By: Claude Opus 4.7` trailer — the same model
  family as the cloud arm measured against the key. Which of the two was written
  to fit the other is not settled by the history, so the record states the fit and
  not a direction. Either way, an arm running `prompt_readability` is not scored
  independently of the key.
- The six `multilingual` cases added by `3fcff6f` quote an external text verbatim —
  Tatoeba, a `ru.wikipedia` revision, a type in this repository — named per case
  in `reference_source`, with the mechanical rule that derives the input from it.
  No candidate prompt could have shaped them, and they are fitted toward nothing.
- The nine cases of `evals_role_boundary.json` (`e924e66`) were authored in the
  commit that added the role-boundary rule to `prompt_readability.txt` and split
  `prompt_readability_baseline.txt` off as the control without that rule. They
  state the behaviour the rule was written to produce, so they are fitted toward
  `prompt_readability` too.

**What a comparison prints.** `compare_runs.py` reads the provenance of the cases
it actually compares and says, next to the numbers rather than only here:

- the arm identity header marks any arm with `| references fitted toward this
  prompt`;
- a `FITTED REFERENCES` block gives each arm its count (`22 of 22 compared
  references were fitted toward this prompt`), the number of compared references
  with no provenance, and the record's own evidence;
- a `Fitted references: …` line sits under the DETERMINISTIC AXIS header and under
  the **anchored** judge table — the two readings that saw the key. The blind judge
  table carries no such line, because a blind reading never saw the reference and
  a key fitted toward a prompt cannot reach it.

The counts are per comparison, so they follow the cases: a `prompt_readability`
arm over the whole set reads 22/22, and the same arm over the `multilingual`
subset reads 1/7 — only the legacy `russian_mixed` case there is fitted.

**How to read the numbers now.** On the whole English set, a `prompt_readability`
arm's deterministic score, and its anchored judge score, are agreement with a key
authored alongside its own prompt: a reading of specification fit as much as of
model quality. A `prompt_lean` arm on the same cases is measured against a key
written toward the other candidate, which is a handicap of unknown size, not a
neutral baseline either. Comparisons *between models on one prompt* — Haiku vs
gemma4:e2b, both on `prompt_readability` — are unaffected, since both arms carry
the same fit. Comparisons *between prompts* are the ones the provenance qualifies.

**What would have to change for a score to be read as neutral.** References
authored from a source independent of every prompt under test, by someone who is
not a model of a family under test; frozen before any arm is measured; and never
revised after seeing an arm's output, with the winner not declared in the commit
that writes the key. The `multilingual` category already meets the first of these
and is the closest thing here to a neutral deterministic reading; the blind judge
axis is neutral by construction, since it never sees the key at all. Rewriting the
English references to meet the rest is a product decision about what good
dictation cleanup *is*, so nothing here rewrites one.

## Local models vs Haiku (2026-09-04)

**Every judge number in this section is an anchored reading** — the judge was shown the
case's expected output. See "The blind reading" below for what that mode does and does not
measure; the same arms read blind do not order the same way.

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

**Every judge number in this section is an anchored reading** — the judge was shown the
case's expected output. See "The blind reading" below for what that mode does and does not
measure; the same arms read blind do not order the same way.

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

## Apple's on-device model, as an arm (2026-09-05)

`--provider apple --model apple-afm` records Apple Foundation Models — the model behind Apple
Intelligence, already shipping in the iOS app as `AppleAFMProvider` and as the cascade fallback.
This is the arm that answers whether the app can fall back to the device when no cloud provider is
configured, instead of falling back to the raw transcript.

**It is reached by a command, not an endpoint.** FoundationModels serves no HTTP, so `afm/AFMShim.swift`
stands in for one: it reads `{"system", "user", "maximumResponseTokens"}` on stdin and writes
`{"text"}` on stdout. `record_run.py` builds it with `swiftc` when the source is newer than the
binary, so the run's outputs came from the source in the commit its manifest names. The shim opens
the same `LanguageModelSession` the app's `AFMClient` opens, with the system prompt as its
instructions and `<dictation>…</dictation>` as its prompt — what this measures is the provider that
would ship, not an approximation of it.

**Greedy, because there is nothing else to pin.** This API offers no seed. Temperature alone leaves
the model free to vary between runs, so the arm asks for `.greedy` sampling and records that as its
`sampling`.

**The version is the OS build.** Apple ships no id for this model, so `apple-afm` is the only name
the arm accepts — a second spelling would read as a second model in the ledger — and the runtime
records `apple-foundation-models on macOS <version> (<build>)`. Two runs a system update apart are
told apart by that line and nothing else.

**A device without the model refuses the run.** The arm probes `SystemLanguageModel.default.availability`
before the first case and records it in the manifest. Where Apple Intelligence is off it exits with
the reason rather than writing a ledger run of identical failures:

```
the on-device model is unavailable: appleIntelligenceNotEnabled. Turn Apple Intelligence on in
System Settings > Apple Intelligence & Siri, wait for the model to download, and record again.
```

**The first reading** — `ledger/20260905T113332Z__evals-english__apple-afm__prompt_readability`,
21 English cases, `prompt_readability`, macOS 26.5.1 (25F80), 2-4s per case with no failures:

| axis | apple-afm |
|---|---|
| deterministic word / punctuation | 0.902 / 0.701 |
| verdicts | EXACT 2, NORM 1, CLOSE 11, DIFF 5, FAIL 2 |
| judge, blind (opus-5 via CLI) | 0.956 overall — punctuation 0.995, content 0.948, voice 0.912, format 0.981 |
| judge, anchored (opus-5 via CLI) | 0.841 overall — content 0.781, voice 0.833 |

**It follows a prompt.** This is the difference from S1-mini, which cannot read one: the on-device
model was given `prompt_readability` unchanged and answered it, which is why its row sits on the
prompt axis as well as the model axis.

**It breaks the capture contract.** On `capture_with_code` it strips the `<capture id="1">` tags and
wraps the whole answer in a code fence — captures 0.0 on both judge readings, and the one case where
the format score moves at all. Whatever the app does with a capture tag, this model does not preserve
it. That is a shipping blocker for the capture path specifically, not for dictation generally.

**Its other weak spot is self-correction.** `self_correction_own` is the worst case in the set
(word 0.474, anchored voice 0.5): the model resolves a spoken correction by rewriting the sentence
rather than by dropping the retracted half.

**Against S1-mini on the same 21 cases** (deterministic axis; A = apple-afm, B = S1-mini):
A wins 5, B wins 9, ties 7. Read by category, the two models fail in different places —

| category | apple-afm | S1-mini |
|---|---|---|
| readability_transform (6) | 0.858 | 0.799 |
| content_preservation (3) | 0.883 | 0.963 |
| self_correction (2) | 0.737 | 0.865 |
| realistic_mixed (4) | 0.932 | 0.971 |
| capture (1) | 0.938 | 1.0 |
| voice_preservation (3), passthrough (2) | 1.0 | 1.0 |

Apple's model edits more aggressively toward readability; S1-mini stays closer to the transcript and
so loses less content. Note the comparison's own warning on that table: these references were fitted
toward `prompt_readability`, the prompt apple-afm ran, so the deterministic columns are not a neutral
reading of model quality. The blind judge reading is the one that does not share that fit.

**The judge axis does not compare across these two runs**, and the tool says so: apple-afm was judged
through the CLI, the S1-mini run through the API. Re-judging S1-mini with `--via cli` would make the
columns comparable and cost no credits — it would overwrite that run's existing judge files, so it is
left as a decision rather than done.

## The multilingual reading (2026-09-04)

**Every judge number in this section is an anchored reading** — the judge was shown the
case's expected output. See "The blind reading" below for what that mode does and does not
measure; the same arms read blind do not order the same way.

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

## The blind reading, and what it does to the anchored one (2026-09-04)

The judge axis exists to read what the token metric cannot see. Until now it did
not: the judge was shown the case's expected output and scored deductions away
from it, so both axes were anchored to the same reference and their agreement was
a property of that anchor rather than two readings converging.

Three arms were re-judged blind by `claude-opus-5` — the same archived outputs,
the same rubric dimensions and weights, no reference in the prompt. The anchored
files are untouched and stand as the record of what that mode read.

**The ordering does not survive.** Anchored, the three arms rank A (0.955) >
B (0.925) > C (0.897), and Haiku wins 10 cases to gemma's 2. Blind, they rank
B (0.983) > A (0.974) > C (0.970), and gemma wins 6 cases to Haiku's 3 with 11
ties. Haiku loses the top of the table.

| arm | anchored overall | blind overall | anchored wins | blind wins |
|---|---|---|---|---|
| A — haiku / prompt_readability (22 cases) | 0.955 | 0.974 | 10 | 3 |
| B — gemma4:e2b / prompt_readability (22 cases) | 0.925 | 0.983 | 2 | 6 |
| C — s1-mini / s1_mini, english subset (21 cases) | 0.897 | 0.970 | 3 | 2 |
| ties | | | 7 | 11 |

Per category, which is where it has to be said, since a run-level mean can hide a
swap in both directions:

| category | cases | anchored order | blind order | survives? |
|---|---|---|---|---|
| readability_transform | 6 | A 0.983 > B 0.922 > C 0.848 | B 0.99 > C 0.981 > A 0.967 | **no — reversed**, A goes first to last |
| voice_preservation | 3 | A 0.993 > C 0.983 > B 0.98 | A = B = C = 1.0 | **no** — the order collapses to a tie |
| content_preservation | 3 | B 0.985 > A 0.945 > C 0.907 | B = C 0.993 > A 0.98 | partly — B stays over A, C rises from last to tied first |
| self_correction | 2 | A 0.985 > B 0.812 > C 0.715 | A 0.97 > B 0.935 > C 0.78 | **yes** — same order, gaps much smaller |
| realistic_mixed | 4 | C 0.92 > A 0.871 > B 0.868 | C 0.988 > A 0.961 > B 0.958 | **yes** |
| passthrough | 2 | B = C 0.99 > A 0.958 | B = C 1.0 > A 0.98 | **yes** |
| capture | 1 | C 0.984 > A 0.98 > B 0.96 | A = B = C = 1.0 | **no** — the order collapses to a tie |
| multilingual | 1 | A 0.94 > B 0.9 | B 1.0 > A 0.945 | **no — reversed** (C was not asked this case) |

So the anchored reading was not harmless, and this has to be said out loud:
**every judge number recorded in this ledger before today is an anchored reading,
and an anchored reading is in part a reading of the reference's authorship.** The
expected outputs encode one particular writer's target — an aggressive-readability
polish, written to a Claude-shaped idea of what the sentence should become — and
the anchored judge rewards the arm whose output most resembles it. Haiku's lead
over the local models on the judge axis is largely that resemblance, not a quality
the judge found in the text on its own. Where the two agree — self_correction,
realistic_mixed, passthrough — the finding is a real one and holds without the
reference.

Two more things the blind reading shows:

- **Everything scores higher blind** (0.97–0.983 against 0.897–0.955), and the
  spread between arms collapses from 0.058 to 0.013. A blind judge asked "is this
  clean, in the speaker's voice, and unchanged in meaning?" answers yes for all
  three arms nearly all the time. The blind axis separates arms poorly, and that is
  itself the reading: on the dimensions decidable without a reference, these three
  arms are close to each other, and the anchored axis' separation is separation on
  agreement with one writer's taste.
- **Punctuation is where the modes disagree most** — 0.809/0.873/0.911 anchored
  against 0.952/0.982/0.987 blind. The anchored judge was scoring departures from
  the reference's punctuation style; the blind judge scores whether the sentence is
  punctuated correctly at all, and by that standard all three arms are fine.

Reproduce (no re-recording; the outputs are archived):

```bash
# --via api: these readings were taken through the API, and the transport is part
# of what makes them reproducible.
export ANTHROPIC_API_KEY=$(op-cache read "op://Private/Anthropic/api_key")
for run in ledger/20260904T114458Z__evals__claude-haiku-4-5-20251001__prompt_readability \
           ledger/20260904T115807Z__evals__gemma4-e2b__prompt_readability \
           ledger/20260904T142156Z__evals-english__hf.co-superwhisper-s1-mini-GGUF-Q4_K_M__s1_mini; do
  ./judge_run.py --mode blind --via api "$run"
done
./compare_runs.py ledger/20260904T114458Z__evals__claude-haiku-4-5-20251001__prompt_readability \
                  ledger/20260904T115807Z__evals__gemma4-e2b__prompt_readability \
                  ledger/20260904T142156Z__evals-english__hf.co-superwhisper-s1-mini-GGUF-Q4_K_M__s1_mini
```

Reopening those first two runs needed one change to the ledger: `ArchivedRun`
checked the whole eval set's fingerprint, so a run recorded before the
multilingual category was widened could no longer be scored or judged at all,
though every case it answered was untouched. The check is now per case — every case
the run answered must still fingerprint to what it answered — which is the same
guarantee stated the way the comparison already states it, and is what lets the set
grow without stranding the runs recorded before it.

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

- `evals.json` — 28 test cases (fresh set; old set was overwritten), the named subsets an arm may be asked instead of all of them, each multilingual case's `reference_source`, and the `reference_provenance` record every case names.
- `evals_role_boundary.json` — 9 role-boundary cases, scored on the same axis, with their own provenance record.
- `prompts/prompt_readability.txt` — A (current live).
- `prompts/prompt_lean.txt` — B (candidate).
- `prompts/prompt_current.txt` — legacy strict prompt, retained as historical baseline.
- `prompts/s1_mini.txt` — S1-mini's required system prompt, verbatim; not a candidate prompt.
- `afm/AFMShim.swift` — one call to Apple's on-device model, as a command; the arm's stand-in for an endpoint.
- `record_run.py` — records one arm over one eval set into the ledger.
- `ledger.py` — the ledger itself: fingerprints, reference provenance, and reopening an archived run.
- `score_run.py` — the deterministic scorer.
- `judge_run.py` — the judge-axis scorer.
- `compare_runs.py` — lays recorded arms side by side, on both axes.
- `index_ledger.py` — regenerates `ledger/index.md` from the runs.
- `agents/assessor.md` — the rubric the judge scores against.
- `test_score_run.py` — the metric's own cases.
- `test_judge_run.py` — the judge's rubric arithmetic and its contestant refusal.
- `test_record_run.py` — the on-device arm: the message it sends, the version it records, and what it refuses.
- `test_compare_runs.py` — what a comparison may and may not compare.
- `test_runner.py` — the runner the test files share.
- `ledger/<run-id>/manifest.json` — what produced the run.
- `ledger/<run-id>/outputs/<case>.txt` — the arm's raw output, byte-for-byte.
- `ledger/<run-id>/deterministic.json` — the deterministic scores.
- `ledger/<run-id>/judge.json` — the anchored judge scores (the judge saw the reference).
- `ledger/<run-id>/judge_blind.json` — the blind judge scores (the judge did not).
- `ledger/index.md` — every run in the ledger, generated.
