#!/usr/bin/env python3
"""Show that a comparison only ever compares like with like.

The ledger's promise is that the eval set may grow and its references may be
corrected without invalidating the runs recorded before that. What makes the
promise keepable is the Case Fingerprint: a case the arms did not answer
identically is reported as not comparable, and every other cell of the
comparison is untouched by the change. That is what these cases pin.

Nothing here calls a model — the arms' outputs are written directly, as
record_run.py would have archived them.

Run: ./test_compare_runs.py
"""

import json
import shutil
import sys
import tempfile
from pathlib import Path

from compare_runs import (
    AXIS_SEPARATION,
    MODE_SEPARATION,
    NOT_COMPARABLE,
    TIE,
    UNSCORED,
    by_category,
    compare,
    judge_axis,
    not_comparable_section,
    report,
)
from ledger import (
    JUDGE_FILES,
    ArchivedRun,
    ScoredRun,
    case_fingerprint,
    eval_set_fingerprint,
    subset_cases,
)
from record_run import named_subset
from score_run import score_run
from test_runner import run_tests

CASES = [
    {
        "id": "hedge_fronted",
        "category": "readability_transform",
        "input": "we should ship it on friday i think",
        "expected_output": "I think we should ship it on Friday.",
    },
    {
        "id": "voice_kept",
        "category": "voice_preservation",
        "input": "honestly the whole thing is a mess",
        "expected_output": "Honestly, the whole thing is a mess.",
    },
    {
        "id": "passthrough_short",
        "category": "passthrough",
        "input": "thanks",
        "expected_output": "Thanks.",
    },
]

# A punctuation difference on the second case, and a missed fronting on the first.
OUTPUTS_A = {
    "hedge_fronted": "I think we should ship it on Friday.",
    "voice_kept": "Honestly the whole thing is a mess.",
    "passthrough_short": "Thanks.",
}
OUTPUTS_B = {
    "hedge_fronted": "We should ship it on Friday, I think.",
    "voice_kept": "Honestly, the whole thing is a mess.",
    "passthrough_short": "Thanks.",
}

JUDGE_OVERALL = {"hedge_fronted": 0.9, "voice_kept": 0.8, "passthrough_short": 1.0}


def write_eval_set(path, cases, provenance=None):
    document = {"evals": cases}
    if provenance:
        document["reference_provenance"] = provenance
    path.write_text(json.dumps(document, ensure_ascii=False))


QUOTED = {
    "records": {
        "quoted": {
            "origin": "quoted_source",
            "fitted_toward": [],
            "basis": "Quoted verbatim from a source no candidate prompt wrote.",
        }
    }
}
FITTED_BASIS = "Authored in the commit that added prompt_readability and named it the winner."
FITTED = {
    "records": {
        "authored_with": {
            "origin": "authored_with_the_candidate_prompts",
            "fitted_toward": ["prompt_readability"],
            "basis": FITTED_BASIS,
        }
    }
}


def naming(record_id, cases):
    """The same cases, each naming the provenance record its reference came from."""
    return [{**case, "reference_provenance": record_id} for case in cases]


def scores_only(printed):
    """A comparison read as it read before any provenance was recorded: the
    fitted-reference block, the note that carries it into the tables and the mark on
    the arm it names, all taken back out."""
    kept, inside_block = [], False
    for line in printed.splitlines():
        if line.startswith("FITTED REFERENCES"):
            inside_block = True
        elif line.startswith("DETERMINISTIC AXIS"):
            inside_block = False
        if inside_block or line.startswith("Fitted references: "):
            continue
        kept.append(line.replace(" | references fitted toward this prompt", ""))
    return "\n".join(kept)


ANCHORED = judge_axis("anchored")
BLIND = judge_axis("blind")


def record(
    directory,
    eval_set_path,
    model,
    outputs,
    judged_by=None,
    judge_overall=JUDGE_OVERALL,
    subset=None,
    judge_mode="anchored",
    prompt_name="prompt_lean",
):
    """One run archived and scored as the ledger's own commands would leave it."""
    cases = subset_cases(json.loads(eval_set_path.read_text())["evals"], subset)
    (directory / "outputs").mkdir(parents=True)
    for case in cases:
        (directory / "outputs" / f"{case['id']}.txt").write_text(outputs[case["id"]])

    (directory / "manifest.json").write_text(
        json.dumps(
            {
                "run_id": directory.name,
                "recorded_at": "2026-09-04T12:00:00Z",
                "repo_commit": "0" * 40,
                "arm": {
                    "model": model,
                    "endpoint": "https://example.invalid/v1/messages",
                    "runtime": "test",
                    "prompt_name": prompt_name,
                    "prompt_sha256": "0" * 64,
                    "sampling": {"temperature": 0},
                },
                "eval_set": {
                    "name": str(eval_set_path),
                    "fingerprint": eval_set_fingerprint(cases),
                    "case_count": len(cases),
                    **({"subset": subset} if subset else {}),
                },
                "cases": [
                    {
                        "id": case["id"],
                        "category": case["category"],
                        "case_fingerprint": case_fingerprint(case),
                        "latency_ms": 1,
                        "output_file": f"outputs/{case['id']}.txt",
                    }
                    for case in cases
                ],
            }
        )
    )

    scores = score_run(ArchivedRun(directory))
    (directory / "deterministic.json").write_text(json.dumps(scores))
    if judged_by:
        (directory / JUDGE_FILES[judge_mode]).write_text(
            json.dumps(
                {
                    "run_id": directory.name,
                    "judge": {
                        "model": judged_by,
                        "mode": judge_mode,
                        "rubric": "agents/assessor.md",
                    },
                    "overall_mean": 0.9,
                    "dimension_means": {},
                    "cases": [
                        {
                            "id": case["id"],
                            "category": case["category"],
                            "judge_model": judged_by,
                            "judge_mode": judge_mode,
                            "overall": judge_overall[case["id"]],
                        }
                        for case in cases
                    ],
                }
            )
        )
    return ScoredRun(directory)


class Ledger:
    """A scratch ledger holding the arms these cases compare.

    C is B re-recorded after one case's reference was corrected: the same arm and
    the same outputs, against an eval set that has moved under it.
    """

    def __init__(self, root):
        self.eval_set = root / "evals.json"
        write_eval_set(self.eval_set, CASES)
        self.a = record(root / "run-a", self.eval_set, "model-a", OUTPUTS_A, "judge-x")
        self.b = record(root / "run-b", self.eval_set, "model-b", OUTPUTS_B, "judge-x")

        corrected = [dict(case) for case in CASES]
        corrected[1]["expected_output"] = "Honestly, the whole thing is a total mess."
        write_eval_set(self.eval_set, corrected)
        self.c = record(root / "run-c", self.eval_set, "model-b", OUTPUTS_B, "judge-x")


def cells(comparison, case_id):
    return next(case for case in comparison["cases"] if case["id"] == case_id)


def with_ledger(body):
    root = Path(tempfile.mkdtemp())
    try:
        return body(Ledger(root))
    finally:
        shutil.rmtree(root)


def test_arms_are_compared_per_case_and_per_category():
    def body(ledger):
        comparison = compare([ledger.a, ledger.b])
        assert all(case["comparable"] for case in comparison["cases"]), comparison

        # A left the hedge fronted where the reference wants it and lost a comma;
        # B fronted nothing and punctuated cleanly. Each wins its own case.
        assert cells(comparison, "hedge_fronted")["winner"]["deterministic"] == "A"
        assert cells(comparison, "voice_kept")["winner"]["deterministic"] == "B"
        assert cells(comparison, "passthrough_short")["winner"]["deterministic"] == TIE

        printed = report(comparison, [ledger.a, ledger.b])
        assert "readability_transform" in printed, printed
        assert "voice_preservation" in printed, printed

    with_ledger(body)


def test_a_blind_reading_is_never_ranked_against_an_anchored_one():
    """The two judge modes measure different things — one saw the reference, one
    did not — so they are two tables, never two columns of one, and neither arm
    wins anything in the other's mode."""

    def body(ledger):
        blind = record(
            ledger.a.directory.parent / "run-blind",
            ledger.eval_set,
            "model-b",
            OUTPUTS_B,
            "judge-x",
            {case_id: 1.0 for case_id in JUDGE_OVERALL},
            judge_mode="blind",
        )
        runs = [ledger.a, blind]
        comparison = compare(runs)
        assert comparison["judge_modes"] == ["blind", "anchored"], comparison["judge_modes"]

        case = cells(comparison, "hedge_fronted")
        # A carries only an anchored score, B only a blind one, so neither mode
        # has two scores to rank and neither names a winner.
        assert case[ANCHORED]["B"] is None and case[BLIND]["A"] is None, case
        assert case["winner"][ANCHORED] is None and case["winner"][BLIND] is None, case

        printed = report(comparison, runs)
        assert MODE_SEPARATION in printed, printed
        assert "JUDGE AXIS (blind)" in printed and "JUDGE AXIS (anchored)" in printed, printed
        assert "not judged blind" in printed and "not judged anchored" in printed, printed
        # Each mode's own table carries the arm that was read in it, and reads the
        # other arm as unscored rather than as a rival.
        blind_row, anchored_row = (
            next(
                line for line in section.splitlines() if line.startswith("hedge_fronted")
            )
            for section in printed.split("JUDGE AXIS (")[1:]
        )
        assert blind_row.split()[2:] == [UNSCORED, "1.0", UNSCORED], blind_row
        assert anchored_row.split()[2:] == ["0.9", UNSCORED, UNSCORED], anchored_row

    with_ledger(body)


def test_a_changed_case_is_not_comparable_and_the_rest_are_untouched():
    def body(ledger):
        before = compare([ledger.a, ledger.b])
        after = compare([ledger.a, ledger.c])

        changed = cells(after, "voice_kept")
        assert not changed["comparable"], changed
        assert "fingerprints differ" in changed["note"], changed
        assert changed["winner"]["deterministic"] is None, changed

        # B and C are the same arm over the same outputs, so every case the
        # correction did not touch reads exactly as it did before it.
        for case_id in ("hedge_fronted", "passthrough_short"):
            assert cells(after, case_id) == cells(before, case_id), case_id

        printed = report(after, [ledger.a, ledger.c])
        notes = "\n".join(not_comparable_section(after))
        assert "case fingerprints differ" in notes and "voice_kept" in notes, notes
        assert NOT_COMPARABLE in printed, printed
        # The case nobody may compare is quoted in neither the detail nor a mean.
        assert "total mess" not in printed, printed

    with_ledger(body)


def test_the_two_axes_are_reported_apart():
    def body(ledger):
        unjudged = record(
            ledger.a.directory.parent / "run-d", ledger.eval_set, "model-d", OUTPUTS_B
        )
        comparison = compare([ledger.c, unjudged])
        case = cells(comparison, "hedge_fronted")
        assert case["deterministic"]["B"]["word_score"] is not None, case
        # One arm's Judge Score with nothing beside it is a reading, not a result.
        assert case[ANCHORED]["B"] is None, case
        assert case["winner"][ANCHORED] is None, case

        printed = report(comparison, [ledger.c, unjudged])
        assert AXIS_SEPARATION in printed, printed
        assert "DETERMINISTIC AXIS" in printed and "JUDGE AXIS" in printed, printed
        assert "not judged" in printed, printed

    with_ledger(body)


def test_comparing_reads_the_scores_and_not_the_eval_set():
    def body(ledger):
        with_set = compare([ledger.a, ledger.b])
        ledger.eval_set.unlink()
        without_set = compare([ledger.a, ledger.b])
        assert without_set == with_set, without_set

        printed = report(without_set, [ledger.a, ledger.b])
        assert "no longer holds the case" in printed, printed

    with_ledger(body)


def test_an_arm_that_scored_zero_reads_as_zero_and_not_as_unscored():
    """A category mean of 0.0 is a measurement — the worst arm must still be
    readable per category, not blanked like an arm nobody scored."""

    def body(ledger):
        silent = record(
            ledger.a.directory.parent / "run-silent",
            ledger.eval_set,
            "model-silent",
            {case["id"]: "" for case in CASES},
            "judge-x",
            {case["id"]: 0.0 for case in CASES},
        )
        comparison = compare([ledger.c, silent])
        category = next(
            row for row in by_category(comparison)
            if row["category"] == "readability_transform"
        )
        assert category["deterministic"]["B"]["word_score"] == 0.0, category
        assert category[ANCHORED]["B"] == 0.0, category

        printed = report(comparison, [ledger.c, silent]).splitlines()
        rows = [line for line in printed if line.startswith("readability_transform")]
        # One row per axis, and neither may spend the unscored sentinel on a zero.
        assert len(rows) == 2, rows
        assert all(row.rstrip().endswith("0.0") for row in rows), rows

    with_ledger(body)


def test_an_arm_is_compared_only_on_the_subset_it_was_asked():
    """An arm that cannot answer part of the set — an English-only model against
    the multilingual cases — records a named subset of the one eval set. The case
    it was never asked reads n/c in its own column, and the arms that were asked it
    are compared there as usual."""

    def body(ledger):
        write_eval_set(ledger.eval_set, CASES)
        document = {
            "subsets": {
                "prose": {
                    "why": "the arm under test cannot answer a bare passthrough",
                    "excludes_categories": ["passthrough"],
                }
            },
            "evals": CASES,
        }
        subset = named_subset(document, "prose", ledger.eval_set)
        assert "passthrough_short" not in subset["case_ids"], subset

        root = ledger.a.directory.parent
        asked = record(root / "run-asked", ledger.eval_set, "model-a", OUTPUTS_A, "judge-x")
        also_asked = record(
            root / "run-also-asked", ledger.eval_set, "model-b", OUTPUTS_B, "judge-x"
        )
        partial = record(
            root / "run-partial", ledger.eval_set, "model-c", OUTPUTS_B, "judge-x",
            subset=subset,
        )
        assert partial.eval_set["case_count"] == len(CASES) - 1, partial.eval_set

        runs = [asked, also_asked, partial]
        comparison = compare(runs)
        skipped = cells(comparison, "passthrough_short")
        assert skipped["answered"] == {"A": True, "B": True, "C": False}, skipped
        assert "not recorded by run-partial" in skipped["note"], skipped
        # The two arms that were asked it are still compared on it; both answered
        # the reference, so neither beats the other.
        assert skipped["comparable"] and skipped["winner"]["deterministic"] == TIE, skipped

        passthrough = next(
            row for row in by_category(comparison) if row["category"] == "passthrough"
        )
        assert (passthrough["compared"], passthrough["not_comparable"]) == (1, 0), passthrough
        assert passthrough["answered"] == {"A": 1, "B": 1, "C": 0}, passthrough
        assert passthrough["deterministic"]["C"]["word_score"] is None, passthrough

        printed = report(comparison, runs)
        row = next(
            line for line in printed.splitlines() if line.startswith("passthrough_short")
        )
        # Only the arm that was not asked reads n/c, in its two cells.
        assert row.count(NOT_COMPARABLE) == 2, row
        assert "A answered 3" in printed and "C answered 2" in printed, printed
        notes = "\n".join(not_comparable_section(comparison))
        assert "not recorded by run-partial" in notes, notes
        assert "passthrough_short" in notes, notes

    with_ledger(body)


def test_recording_where_a_reference_came_from_changes_no_score():
    """Provenance is written beside a reference, never into it: the Case Fingerprint
    is the input and the reference alone, so every run already in the ledger reads
    exactly as it did before the answer key's history was written down."""

    def body(ledger):
        write_eval_set(ledger.eval_set, CASES)
        runs = [ledger.a, ledger.b]
        before = compare(runs)
        printed_before = report(before, runs)

        write_eval_set(ledger.eval_set, naming("quoted", CASES), QUOTED)
        on_disk = json.loads(ledger.eval_set.read_text())["evals"]
        assert [case_fingerprint(case) for case in on_disk] == [
            case_fingerprint(case) for case in CASES
        ], on_disk

        after = compare(runs)
        assert after == before, after
        printed_after = report(after, runs)
        assert scores_only(printed_after) == scores_only(printed_before), printed_after
        # Nothing here was fitted toward either arm's prompt, so nothing is warned about.
        assert "Fitted references: " not in printed_after, printed_after

    with_ledger(body)


def test_an_arm_is_named_where_the_references_were_fitted_toward_its_own_prompt():
    """A score against a key authored with the arm's own prompt is agreement with a
    specification, not model quality. The comparison says so next to the numbers, and
    a case whose origin nothing settles is counted as unknown rather than assumed."""

    def body(ledger):
        cases = naming("authored_with", CASES[:2]) + [CASES[2]]
        write_eval_set(ledger.eval_set, cases, FITTED)
        root = ledger.a.directory.parent
        lean = record(root / "run-lean", ledger.eval_set, "model-a", OUTPUTS_A, "judge-x")
        fitted = record(
            root / "run-fitted",
            ledger.eval_set,
            "model-b",
            OUTPUTS_B,
            "judge-x",
            prompt_name="prompt_readability",
        )
        runs = [lean, fitted]
        printed = report(compare(runs), runs)

        assert "2 of 3 compared references were fitted toward this prompt" in printed, printed
        assert "A  prompt_lean — no compared reference was fitted" in printed, printed
        assert "1 of 3 compared references record no provenance" in printed, printed
        assert FITTED_BASIS.split(" that ")[0] in printed, printed
        # The arm identity header, then both tables that read the reference.
        assert printed.count("references fitted toward this prompt") == 1, printed
        assert printed.count("Fitted references: B (prompt_readability, 2/3") == 2, printed

        # The warning is the only thing the fit adds: no cell of either table moves.
        write_eval_set(ledger.eval_set, CASES)
        neutral = report(compare(runs), runs)
        assert scores_only(printed) == scores_only(neutral), printed

    with_ledger(body)


def test_two_eval_sets_are_never_compared():
    def body(ledger):
        other_set = ledger.eval_set.parent / "evals_role_boundary.json"
        write_eval_set(other_set, CASES[:1])
        other = record(
            ledger.a.directory.parent / "run-e", other_set, "model-a", OUTPUTS_A
        )
        try:
            compare([ledger.a, other])
        except SystemExit as refusal:
            assert "different eval sets" in str(refusal), refusal
        else:
            raise AssertionError("comparing across two eval sets was allowed")

    with_ledger(body)


if __name__ == "__main__":
    sys.exit(1 if run_tests(globals()) else 0)
