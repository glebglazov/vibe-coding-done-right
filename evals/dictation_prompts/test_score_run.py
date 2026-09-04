#!/usr/bin/env python3
"""Show that the deterministic metric respects the project's severity ladder.

The metric this replaced was measured against this eval set and found to invert
that ladder: a punctuation-only difference — which the harness classes as
harmless style — scored below both of the content-level regressions it could not
see at all. Those three differences are here, taken from the eval set itself,
and they pin the ordering the right way round.

Run: ./test_score_run.py
"""

import json
import sys
from pathlib import Path

from score_run import CLOSE_SCORE, score_case

HERE = Path(__file__).resolve().parent

CASES = {
    case["id"]: case
    for case in json.loads((HERE / "evals.json").read_text())["evals"]
}

REORDER_CASE = CASES["russian_mixed"]
# The reorder the case exists to exercise, left undone: the reference fronts
# "как минимум", the output leaves it trailing as the speaker said it.
REORDER_MISSED = REORDER_CASE["expected_output"].replace(
    "как минимум два месяца", "два месяца как минимум"
)
COMMAS_STRIPPED = REORDER_CASE["expected_output"].replace(",", "")

FALSE_START_CASE = CASES["false_start_double_connector"]
FALSE_START_KEPT = FALSE_START_CASE["expected_output"].replace(
    "And then we hit", "And then and then we hit"
)


def score_reorder(actual):
    return score_case(REORDER_CASE["input"], REORDER_CASE["expected_output"], actual)


def test_matching_the_reference_is_exact():
    score = score_reorder(REORDER_CASE["expected_output"])
    assert score["verdict"] == "EXACT", score
    assert score["word_score"] == 1.0, score


def test_formatting_difference_stays_distinguishable_from_equality():
    styled = REORDER_CASE["expected_output"].replace("Слушай", "слушай") + "\n"
    score = score_reorder(styled)
    assert score["verdict"] == "NORM", score


def test_missed_reordering_costs_the_primary_score():
    score = score_reorder(REORDER_MISSED)
    assert score["verdict"] != "EXACT", score
    assert score["word_edits"] == 4, score
    assert score["word_score"] < 1.0, score
    # The words are all still there and still punctuated the same way; only their
    # order moved, so this is the primary axis' finding alone.
    assert score["punctuation_score"] == 1.0, score
    assert score["content_loss"] == 0 and score["invented"] == 0, score


def test_false_start_left_unconsolidated_is_visible():
    score = score_case(
        FALSE_START_CASE["input"], FALSE_START_CASE["expected_output"], FALSE_START_KEPT
    )
    assert score["word_edits"] == 2, score
    assert score["word_score"] < 1.0, score


def test_punctuation_difference_registers_without_dominating():
    score = score_reorder(COMMAS_STRIPPED)
    assert score["word_score"] == 1.0, score
    assert score["punctuation_score"] < CLOSE_SCORE, score
    assert score["punctuation_edits"] == REORDER_CASE["expected_output"].count(","), score
    assert score["verdict"] == "CLOSE", score


def test_severity_ladder_is_not_inverted():
    style = score_reorder(COMMAS_STRIPPED)["word_score"]
    reorder = score_reorder(REORDER_MISSED)["word_score"]
    false_start = score_case(
        FALSE_START_CASE["input"], FALSE_START_CASE["expected_output"], FALSE_START_KEPT
    )["word_score"]
    assert style > reorder, (style, reorder)
    assert style > false_start, (style, false_start)


def test_content_loss_and_invention_are_counted_asymmetrically():
    spoken = "we should ship it on friday because the tests are green"
    reference = "We should ship it on Friday, because the tests are green."
    dropped = score_case(spoken, reference, "We should ship it on Friday.")
    assert dropped["content_loss"] == 5, dropped
    assert dropped["invented"] == 0, dropped

    invented = score_case(
        spoken, reference, "We should ship it on Friday, however the tests are green."
    )
    # "because" is the speaker's word the reference kept; "however" is neither's.
    assert invented["content_loss"] == 1, invented
    assert invented["invented"] == 1, invented


def test_removing_a_filler_the_reference_also_drops_is_not_content_loss():
    spoken = "ну я думаю нам нужно переехать"
    score = score_case(spoken, "Я думаю, нам нужно переехать.", "Я думаю, нам нужно переехать.")
    assert score["content_loss"] == 0, score


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
