#!/usr/bin/env python3
"""Show that the index never prints a mean as more than it is.

The index is the table everybody reads first, so a cell of it is read as the
run's score on that axis. Two ways that goes wrong are pinned here: a run the
judge read none of, which has no mean at all, and a run the judge read part of,
whose mean is over fewer cases than the run holds. Both would otherwise print as
a plain number beside runs read whole.

The runs are built by test_compare_runs' recorder — the same scratch ledger, laid
out as the ledger's own commands leave one.

Run: ./test_index_ledger.py
"""

import shutil
import sys
import tempfile
from pathlib import Path

from index_ledger import MISSING, index
from test_compare_runs import CASES, JUDGE_OVERALL, OUTPUTS_A, record, write_eval_set
from test_runner import run_tests


def judged(overall):
    """One run, judged as the given case scores say — a None being a case the judge
    never got through."""
    root = Path(tempfile.mkdtemp())
    eval_set = root / "evals.json"
    write_eval_set(eval_set, CASES)
    return root, record(root / "run-a", eval_set, "model-a", OUTPUTS_A, "judge-x", overall)


def indexed(overall):
    """The run's row in the index, as its cells."""
    root, run = judged(overall)
    try:
        row = next(line for line in index([run]).splitlines() if line.startswith("| run-a"))
    finally:
        shutil.rmtree(root)
    return [cell.strip() for cell in row.strip("| ").split(" | ")]


def test_a_run_the_judge_read_none_of_has_no_mean_and_reads_as_unscored():
    """A judge file whose every case errored — the API balance ran out before the
    first one — holds a null mean. Printing the null as a value would put a run
    nobody scored in the same column as the runs somebody did."""
    cells = indexed({case_id: None for case_id in JUDGE_OVERALL})
    blind, anchored = cells[-2:]
    assert (blind, anchored) == (MISSING, MISSING), cells
    assert "None" not in cells, cells
    # Only the axis nobody could read is missing: the deterministic scores were
    # computed from the archive, and are numbers with nothing beside them.
    assert float(cells[7]) > 0, cells


def test_a_mean_over_part_of_a_run_carries_the_part():
    """0.95 over two of three cases is not the same reading as 0.95 over three, so
    the count travels with the number and only the partial cell carries it."""
    cells = indexed({**JUDGE_OVERALL, "voice_kept": None})
    assert cells[-1] == "0.95 (judge-x, 2/3 cases)", cells
    # The deterministic axis read every case, so nothing there carries a count.
    assert not any("cases" in cell for cell in cells[7:9]), cells


def test_a_run_the_judge_read_whole_prints_the_bare_mean():
    cells = indexed(JUDGE_OVERALL)
    assert cells[-1] == "0.9 (judge-x)", cells
    assert not any("cases" in cell for cell in cells), cells


if __name__ == "__main__":
    sys.exit(1 if run_tests(globals()) else 0)
