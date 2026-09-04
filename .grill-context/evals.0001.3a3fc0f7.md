---
fragment: 3a3fc0f7
generation: 0001
branch: master
---

+ Eval Set
  A named, versioned collection of Eval Cases exercising one concern — dictation
  cleanup, assistant behaviour, role boundary. Two eval sets are never scored
  against each other, and replacing a set's cases makes prior results
  incomparable rather than merely stale.
  avoid: test suite, eval file, benchmark

+ Eval Case
  One recorded input paired with the reference output a careful human would have
  written for it, plus the concern it exercises. The reference encodes an
  editorial target, so it is an opinion under revision, not ground truth.
  avoid: test, fixture, sample

+ Eval Arm
  One measurable configuration run across an Eval Set: a model, a prompt, and
  the endpoint that served them. An arm is the unit of comparison — a claim that
  one model beats another is always a claim about two arms differing in exactly
  the model.
  avoid: run config, variant, condition

+ Eval Run
  One execution of one Eval Arm over one Eval Set, carrying its raw outputs and
  the identity of everything that produced them. A run is immutable once
  recorded; re-running a configuration creates a second run rather than
  replacing the first.
  avoid: execution, pass, trial

+ Run Ledger
  The committed history of every Eval Run. It exists so a comparison against
  past work costs nothing to repeat: an arm already in the ledger is never re-run
  merely to be compared against a new one.
  avoid: results dir, scores file, output cache

+ Case Fingerprint
  The identity of an Eval Case's meaning — its input together with its reference
  output. Two runs may be compared on a case only when their fingerprints agree,
  which is what lets cases be added or corrected without invalidating the whole
  ledger.
  avoid: case hash, case id, checksum

+ Deterministic Score
  A score that is a pure function of a reference output and an actual output, so
  that rescoring an archived Eval Run yields the same number forever. It is the
  ledger's primary axis precisely because it is reproducible, and it is only ever
  as good as the textual property it measures.
  avoid: automated score, string score, objective score

+ Judge Score
  A score assigned by a model reading an actual output against a rubric. It
  measures what no Deterministic Score reaches — preserved voice, over-editing —
  and is reproducible only within one judge model, so it always carries the
  identity of the judge that produced it.
  avoid: LLM score, subjective score, rubric score

+ Rescore
  Computing fresh scores over an archived Eval Run's stored outputs. It is the
  operation the Run Ledger is built to serve: a changed metric or a corrected
  reference is answered by rescoring history, never by spending on the models
  again.
  avoid: re-evaluate, re-run, backfill
