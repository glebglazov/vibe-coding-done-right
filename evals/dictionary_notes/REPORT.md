# Dictionary Notes eval

Question: when the transcription engine mishears a Dictionary word, does a
per-entry Note beside the spelling make the LLM write the Dictionary spelling
more often than spellings alone, without more false insertions?

## Verdict

Notes raise the hit rate in every model and mode, by more than the spread.
In Dictation, false insertions rise little or not clearly. In Assistant, Notes
raise false insertions sharply, from 3% to 23% (Haiku) and from 7% to 33%
(Gemini). The causes are an unasked "Gleb" sign-off from the Note "my own name",
and an entry added because the request matches its Note's topic (dentist,
niece, Vue app, landlord). Arm D adds a rule to the block intro against both.
It has no measurable effect. So the intro text cannot control this, and a
Note should not reach Assistant modes in this form.

The first run (`ledger/`, 18 + 6 negatives) said "no rise in false
insertions". The second run (`ledger-v2/`, 67 + 41 negatives) replaces that
verdict.

## Design

- Dictionary: `dictionary.json`, 15 entries (names, tech terms, places).
  Katelyn ("my dentist") and Caitlin ("colleague on the data team") sound the
  same on purpose.
- Eval Sets: `dictation.json` (45 misheard, 67 sounds-alike) and
  `assistant.json` (15 misheard, 41 sounds-alike). The first run used the
  first 18 and 6 sounds-alike cases.
- Arms: A no hints. B today's `<spelling_hints>` block, byte-identical to the
  output of `Shared/Substitutions/SpellingHints.swift`. C is B with
  `(note)` after each spelling. D (`spellings_notes_guarded`, `ledger-v2/`
  only) is C with this intro sentence added: "Use it only to decide which
  entry the speaker meant, never as a reason to write an entry, sign a
  message or address someone."
- Negatives in `ledger-v2/` carry a `trap`: other_person, self_name,
  note_topic, common_word, topic_other_thing.
- Mode prompts: from `vcdr-server/prompts.go`.
- Models: `claude-haiku-4-5-20251001` and `gemini-3.1-flash-lite`, the
  default model of each cloud adapter.
- Sampling: provider default temperature and a 1024 output-token cap, as the
  app sends. Three runs per arm.
- Score axes, per run in `spelling.json`:
  - hit: the expected spelling appears as an exact whole word (misheard cases).
  - false insertion: a Dictionary spelling that the input does not have
    (sounds-alike cases).
  - wrong entry: a different Dictionary spelling (misheard cases).
  - note leak: Note text in the output that is not in the input and that no
    arm without Notes wrote for the same case.

## Results, second run (`ledger-v2/`)

Mean of 3 runs, lowest and highest run in parentheses. Note leak is 0% in
every cell. Rerun with `./score.py --ledger ledger-v2 [--flips]`.

| model | mode | arm | hit | false insertion | wrong entry |
|---|---|---|---|---|---|
| haiku-4.5 | dictation (45+67) | A no hints | 23.0% (22–24) | 0% | 0% |
| haiku-4.5 | dictation | B spellings | 62.2% (62–62) | 3.5% (3–4) | 5.2% (4–7) |
| haiku-4.5 | dictation | C + notes | 75.6% (76–76) | 4.0% (3–6) | 4.4% (4–4) |
| haiku-4.5 | dictation | D + notes, guarded | 76.3% (76–78) | 5.0% (3–6) | 5.2% (4–7) |
| gemini-3.1-flash-lite | dictation | A | 31.1% (31–31) | 0% | 0% |
| gemini-3.1-flash-lite | dictation | B | 84.4% (82–87) | 15.4% (13–18) | 7.4% (7–9) |
| gemini-3.1-flash-lite | dictation | C | 94.8% (93–96) | 17.9% (18–18) | 3.0% (2–4) |
| gemini-3.1-flash-lite | dictation | D | 96.3% (96–98) | 20.9% (21–21) | 4.4% (4–4) |
| haiku-4.5 | assistant (15+41) | A | 11.1% (7–13) | 0% | 0% |
| haiku-4.5 | assistant | B | 57.8% (47–67) | 3.3% (2–5) | 0% |
| haiku-4.5 | assistant | C | 82.2% (80–87) | 22.8% (22–24) | 17.8% (13–20) |
| haiku-4.5 | assistant | D | 88.9% (87–93) | 21.1% (17–24) | 13.3% (13–13) |
| gemini-3.1-flash-lite | assistant | A | 22.2% (20–27) | 0% | 0% |
| gemini-3.1-flash-lite | assistant | B | 71.1% (67–80) | 7.3% (7–7) | 13.3% (7–20) |
| gemini-3.1-flash-lite | assistant | C | 93.3% (93–93) | 32.5% (29–37) | 17.8% (13–20) |
| gemini-3.1-flash-lite | assistant | D | 93.3% (93–93) | 30.9% (27–34) | 17.8% (13–20) |

False insertions by trap, k/n over 3 runs:

| model | mode | arm | other_person | self_name | note_topic | common_word | topic_other_thing |
|---|---|---|---|---|---|---|---|
| haiku | assistant | B | 3/24 | 0/33 | 1/24 | 0/24 | 0/18 |
| haiku | assistant | C | 13/24 | 4/33 | 9/24 | 0/24 | 2/18 |
| haiku | assistant | D | 12/24 | 4/33 | 10/24 | 0/24 | 0/18 |
| haiku | dictation | B | 7/51 | 0/24 | 0/42 | 0/57 | 0/27 |
| haiku | dictation | C | 7/51 | 0/24 | 0/42 | 0/57 | 1/27 |
| haiku | dictation | D | 9/51 | 0/24 | 0/42 | 0/57 | 1/27 |
| gemini | assistant | B | 8/24 | 1/33 | 0/24 | 0/24 | 0/18 |
| gemini | assistant | C | 13/24 | 9/33 | 15/24 | 0/24 | 3/18 |
| gemini | assistant | D | 10/24 | 10/33 | 15/24 | 0/24 | 3/18 |
| gemini | dictation | B | 31/51 | 0/24 | 0/42 | 0/57 | 0/27 |
| gemini | dictation | C | 35/51 | 0/24 | 1/42 | 0/57 | 0/27 |
| gemini | dictation | D | 37/51 | 0/24 | 3/42 | 2/57 | 0/27 |

Unasked "Gleb" (negatives + misheard cases where Gleb was the wrong entry):

| model | mode | B | C | D |
|---|---|---|---|---|
| haiku | assistant | 0 + 0 | 18 + 8 | 20 + 6 |
| haiku | dictation | 0 | 0 | 1 + 0 |
| gemini | assistant | 0 + 3 | 21 + 8 | 22 + 8 |
| gemini | dictation | 4 + 0 | 9 + 0 | 9 + 0 |

In Assistant almost all are a sign-off at the end of a message. In Dictation,
Gemini turns "Glen" into "Gleb" in all 9 Glen answers with Notes.

## Results, first run (`ledger/`)

Kept for the record. Its negatives were too few: one Assistant case moved the
false-insertion rate by 17 points. Rerun with `./score.py`.

| model | mode | arm | hit | false insertion | wrong entry |
|---|---|---|---|---|---|
| haiku-4.5 | dictation | B | 61.5% (60–62) | 5.6% | 4.4% |
| haiku-4.5 | dictation | C | 77.0% (76–78) | 5.6% | 3.7% |
| gemini-3.1-flash-lite | dictation | B | 84.4% (84–84) | 27.8% | 8.1% |
| gemini-3.1-flash-lite | dictation | C | 96.3% (96–98) | 20.4% (17–22) | 1.5% |
| haiku-4.5 | assistant | B | 55.6% (47–60) | 16.7% | 4.4% |
| haiku-4.5 | assistant | C | 82.2% (80–87) | 16.7% | 15.6% |
| gemini-3.1-flash-lite | assistant | B | 68.9% (67–73) | 16.7% | 17.8% |
| gemini-3.1-flash-lite | assistant | C | 93.3% (93–93) | 16.7% | 20.0% |

## Caveats

- The same author wrote the cases and the Notes, and many cases reuse words from
  the Notes. Real Notes will match speech less closely, so the size of the gain
  is probably an upper bound. The direction holds.
- The mishearings are made up, not real Whisper output.
- The spread is sampling noise on one case set, not case-set variance.
- The same author wrote the negatives and the Notes, so the note_topic rates
  show what can go wrong, not how often real users will see it.
- The existing harness pins temperature 0. This eval does not, to see variance.
- Calls: 1,512 (first run) + 3,024 (second run, A/B/C) + 1,008 (arm D).
  Tokens were not recorded.
