#!/usr/bin/env python3
"""Compare Eval Arms from the Run Ledger.

Usage:
  ./compare_runs.py ledger/20260904T101031Z__evals__claude-haiku-4-5-20251001__prompt_lean \\
                    ledger/20260904T101059Z__evals__gemma4-e4b__prompt_lean

This is what the ledger exists for: adding an arm to the matrix costs one
recording, and comparing it against every arm ever recorded costs nothing. No
model is called and no eval set is re-run — the scores already written beside
each run are read and laid side by side.

Two arms are compared on a case only where their Case Fingerprints agree. A case
whose input or reference has been corrected since one run was recorded is
reported as not comparable rather than silently compared, which is what lets the
eval set grow without invalidating the ledger's history.

The deterministic axis and the judge axis are reported as two separate readings.
A Deterministic Score is reproducible forever; a Judge Score holds only within
one judge model. Nothing here averages them, and no cell of one is weighed
against a cell of the other.
"""

import argparse
import sys
from statistics import mean

from ledger import ScoredRun, case_fingerprint, eval_set_cases
from score_run import SCORE_DIGITS, VERDICT_ORDER

# What a cell says when the arms did not answer the same case.
NOT_COMPARABLE = "n/c"
TIE = "="
UNSCORED = "-"
REFERENCE_CHANGED = "(the eval set no longer holds the case these runs answered)"

AXIS_SEPARATION = """\
The two axes below are separate readings and are not comparable with each other.
A Deterministic Score is a pure function of the reference output; a Judge Score
is one model's reading of a rubric. Neither is averaged into the other, and a
cell of one never answers a cell of the other."""


def arm_label(index):
    return chr(ord("A") + index)


def comparability(runs, case_id):
    """Whether every arm answered the same case, and where they parted if not."""
    fingerprints = {run.fingerprint(case_id) for run in runs}
    if len(fingerprints) == 1 and None not in fingerprints:
        return True, None
    missing = [run.run_id for run in runs if run.fingerprint(case_id) is None]
    if missing:
        return False, f"not recorded by {', '.join(missing)}"
    parted = ", ".join(
        f"{arm_label(index)}={run.fingerprint(case_id)[:12]}"
        for index, run in enumerate(runs)
    )
    return False, f"case fingerprints differ ({parted})"


def axis_cells(runs, axis, case_id):
    """Each arm's score for the case on one axis, keyed by arm label."""
    cells = {}
    for index, run in enumerate(runs):
        scores = getattr(run, axis)
        cells[arm_label(index)] = scores.cases.get(case_id) if scores else None
    return cells


def deterministic_rank(cell):
    """Highest primary score wins; punctuation, then verdict, break the tie.

    The word score is the primary axis, so it decides first. Verdict comes last
    because it is a reading of the numbers above it, not a number of its own.
    """
    if cell is None or "word_score" not in cell:
        return None
    return (
        cell["word_score"],
        cell["punctuation_score"],
        -VERDICT_ORDER.index(cell["verdict"]),
    )


def judge_rank(cell):
    if cell is None or "overall" not in cell:
        return None
    return cell["overall"]


def winner(cells, rank):
    """The arm ranked highest, TIE where nothing separates them, None where this
    axis cannot name one.

    Two scored cells are the minimum: one arm's score with nothing beside it is a
    reading, not a comparison, and naming it the winner would claim it beat an
    arm that was never scored.
    """
    ranked = [(label, rank(cell)) for label, cell in cells.items()]
    scored = [(label, value) for label, value in ranked if value is not None]
    if len(scored) < 2:
        return None
    best = max(value for _, value in scored)
    leaders = [label for label, value in scored if value == best]
    return leaders[0] if len(leaders) == 1 else TIE


def case_order(runs):
    """Every case any arm recorded, in the order the earliest arm to record it did."""
    ordered = []
    for run in runs:
        ordered.extend(case_id for case_id in run.case_ids() if case_id not in ordered)
    return ordered


def compare_case(runs, case_id):
    comparable, note = comparability(runs, case_id)
    deterministic = axis_cells(runs, "deterministic", case_id)
    judge = axis_cells(runs, "judge", case_id)
    category = next(
        run.category(case_id) for run in runs if run.category(case_id) is not None
    )
    return {
        "id": case_id,
        "category": category,
        "comparable": comparable,
        "note": note,
        "deterministic": deterministic,
        "judge": judge,
        "winner": {
            "deterministic": winner(deterministic, deterministic_rank) if comparable else None,
            "judge": winner(judge, judge_rank) if comparable else None,
        },
    }


def compare(runs):
    eval_sets = {run.eval_set["name"] for run in runs}
    if len(eval_sets) > 1:
        raise SystemExit(
            f"these runs answer different eval sets ({', '.join(sorted(eval_sets))}); "
            "two eval sets are never scored against each other."
        )
    return {
        "eval_set": sorted(eval_sets)[0],
        "arms": [
            {
                "label": arm_label(index),
                "run_id": run.run_id,
                "metric": run.deterministic.summary["metric"] if run.deterministic else None,
                "judged_by": run.judge.summary["judge"]["model"] if run.judge else None,
                **run.arm,
            }
            for index, run in enumerate(runs)
        ],
        "cases": [compare_case(runs, case_id) for case_id in case_order(runs)],
    }


def cell_mean(rows, axis, label, key):
    """A mean over the comparable rows alone: a cell nobody may compare is not a
    number that belongs in an average."""
    values = [
        row[axis][label][key]
        for row in rows
        if row["comparable"] and row[axis][label] and key in row[axis][label]
    ]
    return round(mean(values), SCORE_DIGITS) if values else None


def by_category(comparison):
    """The per-category read, over however many cases each category holds now."""
    categories = []
    for category in dict.fromkeys(case["category"] for case in comparison["cases"]):
        rows = [case for case in comparison["cases"] if case["category"] == category]
        comparable = [row for row in rows if row["comparable"]]
        categories.append(
            {
                "category": category,
                "compared": len(comparable),
                "not_comparable": len(rows) - len(comparable),
                "deterministic": {
                    arm["label"]: {
                        "word_score": cell_mean(rows, "deterministic", arm["label"], "word_score"),
                        "punctuation_score": cell_mean(
                            rows, "deterministic", arm["label"], "punctuation_score"
                        ),
                    }
                    for arm in comparison["arms"]
                },
                "judge": {
                    arm["label"]: cell_mean(rows, "judge", arm["label"], "overall")
                    for arm in comparison["arms"]
                },
            }
        )
    return categories


def headline(comparison, axis):
    """Wins, ties and exact matches over the cases the arms actually share."""
    comparable = [case for case in comparison["cases"] if case["comparable"]]
    wins = {arm["label"]: 0 for arm in comparison["arms"]}
    ties = 0
    for case in comparable:
        champion = case["winner"][axis]
        if champion == TIE:
            ties += 1
        elif champion is not None:
            wins[champion] += 1
    return {
        "compared": len(comparable),
        "not_comparable": len(comparison["cases"]) - len(comparable),
        "wins": wins,
        "ties": ties,
        "exact": {
            arm["label"]: sum(
                1
                for case in comparable
                if (case["deterministic"][arm["label"]] or {}).get("verdict") == "EXACT"
            )
            for arm in comparison["arms"]
        },
    }


def winner_text(case, axis):
    """A named winner, or why there is none: the arms did not answer the same case,
    or this axis has fewer than two scores for it."""
    if not case["comparable"]:
        return NOT_COMPARABLE
    return case["winner"][axis] or UNSCORED


def score_text(cell, key, comparable):
    if not comparable:
        return NOT_COMPARABLE
    if cell is None or key not in cell:
        return UNSCORED
    return f"{cell[key]}"


def table(header, rows, gap="  "):
    """One table, with every column as wide as its widest cell."""
    widths = [
        max(len(str(row[column])) for row in [header, *rows])
        for column in range(len(header))
    ]
    lines = [gap.join(str(cell).ljust(width) for cell, width in zip(header, widths))]
    lines.append("-" * len(lines[0]))
    for row in rows:
        lines.append(gap.join(str(cell).ljust(width) for cell, width in zip(row, widths)))
    return lines


def deterministic_section(comparison):
    labels = [arm["label"] for arm in comparison["arms"]]
    header = ["case", "category"]
    for label in labels:
        header += [f"{label} word", f"{label} punct"]
    header.append("winner")

    rows = []
    for case in comparison["cases"]:
        row = [case["id"], case["category"]]
        for label in labels:
            cell = case["deterministic"][label]
            row += [
                score_text(cell, "word_score", case["comparable"]),
                score_text(cell, "punctuation_score", case["comparable"]),
            ]
        row.append(winner_text(case, "deterministic"))
        rows.append(row)

    category_header = ["category", "cases", "n/c"] + [f"{label} word" for label in labels]
    category_rows = [
        [
            category["category"],
            category["compared"],
            category["not_comparable"],
            *(
                category["deterministic"][label]["word_score"] or UNSCORED
                for label in labels
            ),
        ]
        for category in by_category(comparison)
    ]

    counts = headline(comparison, "deterministic")
    metrics = {
        arm["label"]: run_metric(comparison, arm["label"]) for arm in comparison["arms"]
    }
    return [
        f"DETERMINISTIC AXIS — {' | '.join(f'{label}: {metric}' for label, metric in metrics.items())}",
        "",
        *table(header, rows),
        "",
        *table(category_header, category_rows),
        "",
        f"{counts['compared']} cases compared, {counts['not_comparable']} not comparable | "
        + " | ".join(
            f"{label} exact {counts['exact'][label]}, wins {counts['wins'][label]}"
            for label in labels
        )
        + f" | ties {counts['ties']}",
    ]


def run_metric(comparison, label):
    """The metric a run's deterministic scores were computed under. Two runs scored
    under different metrics are not two readings of the same thing."""
    arm = next(arm for arm in comparison["arms"] if arm["label"] == label)
    return arm.get("metric") or "not scored"


def judge_section(comparison):
    labels = [arm["label"] for arm in comparison["arms"]]
    judges = {
        arm["label"]: f"judged by {arm['judged_by']}" if arm["judged_by"] else "not judged"
        for arm in comparison["arms"]
    }
    lines = [
        "JUDGE AXIS — "
        + " | ".join(f"{label}: {judge}" for label, judge in judges.items())
    ]
    if len({arm["judged_by"] for arm in comparison["arms"]}) > 1:
        lines.append(
            "These arms were judged by different judges, or one was not judged: a Judge "
            "Score holds only within one judge model, so these columns do not compare."
        )

    header = ["case", "category", *(f"{label} overall" for label in labels), "winner"]
    rows = [
        [
            case["id"],
            case["category"],
            *(
                score_text(case["judge"][label], "overall", case["comparable"])
                for label in labels
            ),
            winner_text(case, "judge"),
        ]
        for case in comparison["cases"]
    ]

    category_header = ["category", "cases", *(f"{label} overall" for label in labels)]
    category_rows = [
        [
            category["category"],
            category["compared"],
            *(category["judge"][label] or UNSCORED for label in labels),
        ]
        for category in by_category(comparison)
    ]

    counts = headline(comparison, "judge")
    return [
        *lines,
        "",
        *table(header, rows),
        "",
        *table(category_header, category_rows),
        "",
        " | ".join(f"{label} wins {counts['wins'][label]}" for label in labels)
        + f" | ties {counts['ties']}",
    ]


def not_comparable_section(comparison):
    incomparable = [case for case in comparison["cases"] if not case["comparable"]]
    if not incomparable:
        return []
    return [
        "NOT COMPARABLE — these cases are not the same case in every arm",
        "",
        *(f"  {case['id']}: {case['note']}" for case in incomparable),
    ]


def references(comparison, runs):
    """Each case's reference output, where the eval set on disk still holds the case
    the runs answered.

    A reference corrected since a run was recorded is not what that run's output
    was scored against, so it is not quoted here as though it were.
    """
    try:
        on_disk = {case["id"]: case for case in eval_set_cases(comparison["eval_set"])}
    except FileNotFoundError:
        return {}
    kept = {}
    for case in comparison["cases"]:
        current = on_disk.get(case["id"])
        if case["comparable"] and current and case_fingerprint(current) == runs[0].fingerprint(case["id"]):
            kept[case["id"]] = current["expected_output"]
    return kept


def detail_section(comparison, runs):
    """The differing outputs themselves — the part of a comparison a human reads."""
    reference = references(comparison, runs)
    lines = ["DETAIL — cases where the arms' outputs differ"]
    for case in comparison["cases"]:
        if not case["comparable"]:
            continue
        outputs = {arm_label(index): run.output(case["id"]) for index, run in enumerate(runs)}
        if len(set(outputs.values())) == 1:
            continue
        scores = " ".join(
            f"{label}={score_text(case['deterministic'][label], 'word_score', True)}"
            for label in outputs
        )
        lines += [
            "",
            f"--- {case['id']}  [{case['category']}]  word {scores}  winner={case['winner']['deterministic']} ---",
            f"{'EXPECTED':<9}: {reference.get(case['id'], REFERENCE_CHANGED)}",
            *(f"{label:<9}: {text}" for label, text in outputs.items()),
        ]
    return lines


def report(comparison, runs):
    arms = [
        f"  {arm['label']}  {arm['run_id']}\n"
        f"     {arm['model']} @ {arm['endpoint']} | {arm['runtime']} | prompt {arm['prompt_name']} "
        f"({arm['prompt_sha256'][:12]})"
        for arm in comparison["arms"]
    ]
    sections = [
        [f"COMPARISON — eval set {comparison['eval_set']}", "", *arms, "", AXIS_SEPARATION],
        deterministic_section(comparison),
        judge_section(comparison),
        not_comparable_section(comparison),
        detail_section(comparison, runs),
    ]
    return "\n\n".join("\n".join(section) for section in sections if section)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "runs", nargs="+", help="ledger directories of the runs to compare"
    )
    arguments = parser.parse_args()
    if len(arguments.runs) < 2:
        raise SystemExit("a comparison needs at least two runs")

    runs = [ScoredRun(directory) for directory in arguments.runs]
    unscored = [run.run_id for run in runs if run.deterministic is None]
    if unscored:
        raise SystemExit(
            f"not scored on the deterministic axis: {', '.join(unscored)}. "
            "Run ./score_run.py on them first — it calls no model."
        )
    print(report(compare(runs), runs))


if __name__ == "__main__":
    sys.exit(main())
