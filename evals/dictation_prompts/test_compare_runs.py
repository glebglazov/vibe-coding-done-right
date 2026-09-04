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

from compare_runs import AXIS_SEPARATION, NOT_COMPARABLE, TIE, compare, report
from ledger import ArchivedRun, ScoredRun, case_fingerprint, eval_set_fingerprint
from score_run import score_run

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


def write_eval_set(path, cases):
    path.write_text(json.dumps({"evals": cases}, ensure_ascii=False))


def record(directory, eval_set_path, model, outputs, judged_by=None):
    """One run archived and scored as the ledger's own commands would leave it."""
    cases = json.loads(eval_set_path.read_text())["evals"]
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
                    "prompt_name": "prompt_lean",
                    "prompt_sha256": "0" * 64,
                    "sampling": {"temperature": 0},
                },
                "eval_set": {
                    "name": str(eval_set_path),
                    "fingerprint": eval_set_fingerprint(cases),
                    "case_count": len(cases),
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
        (directory / "judge.json").write_text(
            json.dumps(
                {
                    "run_id": directory.name,
                    "judge": {"model": judged_by, "rubric": "agents/assessor.md"},
                    "overall_mean": 0.9,
                    "dimension_means": {},
                    "cases": [
                        {
                            "id": case["id"],
                            "category": case["category"],
                            "judge_model": judged_by,
                            "overall": JUDGE_OVERALL[case["id"]],
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
        assert "voice_kept: case fingerprints differ" in printed, printed
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
        assert case["judge"]["B"] is None, case
        assert case["winner"]["judge"] is None, case

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


def main():
    failures = 0
    for name, case in sorted(globals().items()):
        if not name.startswith("test_"):
            continue
        try:
            case()
            print(f"PASS {name}")
        except AssertionError as failure:
            failures += 1
            print(f"FAIL {name}: {failure}")
    return failures


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
