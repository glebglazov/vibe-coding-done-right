#!/usr/bin/env python3
"""Show that a Judge Score follows the rubric and stays on its own axis.

The judge model itself is the one boundary here that cannot be exercised
offline, so it is the only thing stood in for: these cases drive the rubric's
weights, the two parts of it that are arithmetic rather than judgement, and the
refusal to let a model grade its own arm.

Run: ./test_judge_run.py
"""

import json
import sys
from pathlib import Path

import judge_run
from judge_run import Judge, judge_run as judge_archived_run
from ledger import LEDGER, ArchivedRun
from test_runner import run_tests

HERE = Path(__file__).resolve().parent

def haiku_run():
    """The most recent Haiku run in the ledger that still answers the eval set as
    it stands.

    A run recorded before the set grew cannot be reopened for scoring — that is
    the ledger's own guard, and picking around it here keeps these cases about the
    judge rather than about which run happens to be oldest.
    """
    for directory in sorted(LEDGER.glob("*__claude-haiku-4-5-20251001__*"), reverse=True):
        try:
            return ArchivedRun(directory)
        except SystemExit:
            continue
    raise AssertionError("no Haiku run in the ledger answers the eval set as it stands")


RUN = haiku_run()

PERFECT = {
    "punctuation": 1,
    "voice": 1,
    "captures": 1,
    "content": 1,
    "format": 1,
    "notes": "matches",
}


class StubBackend:
    """The judge model, stood in for: the same reply to every case."""

    def __init__(self, reply, model="claude-opus-5"):
        self.model = model
        self.endpoint = "stub://messages"
        self.sampling = {"temperature": 0}
        self.reply = reply
        self.calls = 0

    def runtime(self):
        return "stub"

    def complete(self, system_prompt, user_message):
        self.calls += 1
        return self.reply


def judge_with(**dimensions):
    return Judge(StubBackend(json.dumps({**PERFECT, **dimensions})))


def case(case_id):
    return {
        case["id"]: case
        for case in json.loads((HERE / "evals.json").read_text())["evals"]
    }[case_id]


def test_overall_uses_the_rubrics_documented_weights():
    judge = judge_with()
    assert judge.weights == {
        "content": 0.30,
        "punctuation": 0.20,
        "voice": 0.20,
        "captures": 0.15,
        "format": 0.15,
    }, judge.weights
    dimensions, _ = judge.score(case("casual_voice_preserved"), "anything")
    assert judge.overall(dimensions) == 1.0, dimensions

    halved_voice = judge_with(voice=0.5)
    dimensions, _ = halved_voice.score(case("casual_voice_preserved"), "anything")
    assert halved_voice.overall(dimensions) == 0.9, dimensions


def test_capture_tag_preservation_is_scored_binary():
    judge = judge_with(captures=0.8)
    dimensions, _ = judge.score(case("capture_with_code"), "anything")
    assert dimensions["captures"] == 0.0, dimensions


def test_a_case_without_capture_tags_scores_captures_by_definition():
    judge = judge_with(captures=0.4)
    dimensions, _ = judge.score(case("casual_voice_preserved"), "anything")
    assert dimensions["captures"] == 1.0, dimensions


def test_every_judged_case_carries_the_judge_that_produced_it():
    scores = judge_archived_run(RUN, judge_with())
    assert scores["judge"]["model"] == "claude-opus-5", scores["judge"]
    assert all(score["judge_model"] == "claude-opus-5" for score in scores["cases"])
    # The judge axis reports only itself: no deterministic number is read in, and
    # nothing here blends the two.
    assert "word_score_mean" not in scores and "metric" not in scores, sorted(scores)


def test_a_model_may_not_grade_its_own_arm():
    argv = sys.argv
    sys.argv = [
        "judge_run.py", str(RUN.directory), "--judge-model", "claude-haiku-4-5-20251001"
    ]
    try:
        judge_run.main()
    except SystemExit as refusal:
        assert "must not grade its own arm" in str(refusal), refusal
    else:
        raise AssertionError("judging an arm with its own model was allowed")
    finally:
        sys.argv = argv


if __name__ == "__main__":
    sys.exit(1 if run_tests(globals()) else 0)
