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
eval set grow without invalidating the ledger's history. A case an arm was never
asked — a subset run — is a smaller question rather than a different one: that
arm's cell reads n/c and the arms that were asked it are compared as usual.

The deterministic axis and the judge axis are reported as two separate readings.
A Deterministic Score is reproducible forever; a Judge Score holds only within
one judge model. Nothing here averages them, and no cell of one is weighed
against a cell of the other.

Both of those axes measure distance from a reference, so the report says where the
reference came from. An arm whose own prompt the references were authored with is
named beside its numbers: its score is agreement with a key written to its own
specification, which is not the same reading as another arm's.
"""

import argparse
import sys
import textwrap
from statistics import mean

from ledger import (
    JUDGE_FILES,
    ScoredRun,
    case_fingerprint,
    case_provenance,
    eval_set_cases,
    eval_set_document,
)
from score_run import SCORE_DIGITS, VERDICT_ORDER

# What a cell says when the arms did not answer the same case.
NOT_COMPARABLE = "n/c"
TIE = "="
UNSCORED = "-"
REFERENCE_CHANGED = "(the eval set no longer holds the case these runs answered)"
PROVENANCE_UNREADABLE = (
    "FITTED REFERENCES — the eval set is not on disk here, so where these references "
    "came from cannot be read and no arm may be called neutral."
)

AXIS_SEPARATION = """\
The two axes below are separate readings and are not comparable with each other.
A Deterministic Score is a pure function of the reference output; a Judge Score
is one model's reading of a rubric. Neither is averaged into the other, and a
cell of one never answers a cell of the other."""

MODE_SEPARATION = """\
The judge axis is printed once per mode, and the modes are not comparable with
each other. A blind reading never saw the reference; an anchored one scores
deductions away from it and so is not evidence independent of the deterministic
axis. Neither is averaged into the other, and no column holds both."""

DETERMINISTIC = "deterministic"


def judge_axis(mode):
    """How a comparison names one judge mode's scores: an axis of its own, so no
    table and no mean can hold two modes at once."""
    return f"judge:{mode}"


def axis_readings(run):
    """Every axis this run carries a score file for, keyed as a comparison names it."""
    return {
        DETERMINISTIC: run.deterministic,
        **{judge_axis(mode): scores for mode, scores in run.judges.items()},
    }


def arm_label(index):
    return chr(ord("A") + index)


def comparability(runs, case_id):
    """Whether the arms that answered the case answered the same case, and which
    arms never answered it at all.

    Two arms answering different versions of a case — a reference corrected
    between the runs — throw the whole row away: the two cells are not two
    readings of one thing. An arm that was never asked the case throws away
    nothing but its own cell, since a subset is a smaller question and not a
    different one.
    """
    answered = {run.fingerprint(case_id) for run in runs if run.fingerprint(case_id)}
    missing = [run.run_id for run in runs if run.fingerprint(case_id) is None]
    if len(answered) > 1:
        parted = ", ".join(
            f"{arm_label(index)}={run.fingerprint(case_id)[:12]}"
            for index, run in enumerate(runs)
            if run.fingerprint(case_id)
        )
        return False, f"case fingerprints differ ({parted})"
    return True, f"not recorded by {', '.join(missing)}" if missing else None


def axis_cells(runs, axis, case_id):
    """Each arm's score for the case on one axis, keyed by arm label."""
    cells = {}
    for index, run in enumerate(runs):
        scores = axis_readings(run).get(axis)
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


def compare_case(runs, case_id, axes):
    comparable, note = comparability(runs, case_id)
    cells = {axis: axis_cells(runs, axis, case_id) for axis in axes}
    category = next(
        run.category(case_id) for run in runs if run.category(case_id) is not None
    )
    return {
        "id": case_id,
        "category": category,
        "comparable": comparable,
        "note": note,
        "answered": {
            arm_label(index): run.fingerprint(case_id) is not None
            for index, run in enumerate(runs)
        },
        **cells,
        "winner": {
            axis: winner(cells[axis], rank_on(axis)) if comparable else None
            for axis in axes
        },
    }


def rank_on(axis):
    return deterministic_rank if axis == DETERMINISTIC else judge_rank


def judge_modes(runs):
    """The judge modes any of these arms was read in, in the order the ledger names
    them, so a comparison prints one table per mode and never one table for both."""
    return [mode for mode in JUDGE_FILES if any(mode in run.judges for run in runs)]


def compare(runs):
    eval_sets = {run.eval_set["name"] for run in runs}
    if len(eval_sets) > 1:
        raise SystemExit(
            f"these runs answer different eval sets ({', '.join(sorted(eval_sets))}); "
            "two eval sets are never scored against each other."
        )
    modes = judge_modes(runs)
    axes = [DETERMINISTIC, *(judge_axis(mode) for mode in modes)]
    return {
        "eval_set": sorted(eval_sets)[0],
        "judge_modes": modes,
        "arms": [
            {
                "label": arm_label(index),
                "run_id": run.run_id,
                "metric": run.deterministic.summary["metric"] if run.deterministic else None,
                "judged_by": {
                    mode: run.judges[mode].summary["judge"]["model"] if mode in run.judges else None
                    for mode in modes
                },
                # Which transport took each reading. Only an HTTP backend can pin
                # sampling, so the same judge model read through the CLI and
                # through the API is two measurements, and neither column may hold
                # both without saying so.
                "judged_via": {
                    mode: run.judges[mode].summary["judge"].get("runtime")
                    if mode in run.judges
                    else None
                    for mode in modes
                },
                # How much of the run each mode actually read. A judge that stopped
                # partway leaves cells missing rather than a file missing, and this
                # comparison averages an arm over the cells it has — so the count
                # has to be printed beside the mean or two arms read over different
                # case sets rank against each other with nothing saying so.
                "judge_coverage": {
                    mode: run.judges[mode].coverage if mode in run.judges else None
                    for mode in modes
                },
                **run.arm,
            }
            for index, run in enumerate(runs)
        ],
        "cases": [compare_case(runs, case_id, axes) for case_id in case_order(runs)],
    }


def cell_scores(rows, axis, label, key):
    """One arm's scores on one axis over the rows it may be compared on: a cell
    nobody may compare, and a case this arm was not asked, are not numbers that
    belong in an average."""
    return [
        row[axis][label][key]
        for row in rows
        if row["comparable"]
        and row["answered"][label]
        and row[axis][label]
        and key in row[axis][label]
    ]


def cell_mean(rows, axis, label, key):
    values = cell_scores(rows, axis, label, key)
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
                DETERMINISTIC: {
                    arm["label"]: {
                        "word_score": cell_mean(rows, DETERMINISTIC, arm["label"], "word_score"),
                        "punctuation_score": cell_mean(
                            rows, DETERMINISTIC, arm["label"], "punctuation_score"
                        ),
                    }
                    for arm in comparison["arms"]
                },
                **{
                    judge_axis(mode): {
                        arm["label"]: cell_mean(rows, judge_axis(mode), arm["label"], "overall")
                        for arm in comparison["arms"]
                    }
                    for mode in comparison["judge_modes"]
                },
                "answered": {
                    arm["label"]: sum(
                        1 for row in comparable if row["answered"][arm["label"]]
                    )
                    for arm in comparison["arms"]
                },
            }
        )
    return categories


def headline(comparison, axis):
    """Wins, ties and exact matches over the cases the arms actually share."""
    comparable = [case for case in comparison["cases"] if case["comparable"]]
    # A row only one arm answered compares nothing, whatever else is true of it.
    compared = [case for case in comparable if sum(case["answered"].values()) > 1]
    wins = {arm["label"]: 0 for arm in comparison["arms"]}
    ties = 0
    for case in comparable:
        champion = case["winner"][axis]
        if champion == TIE:
            ties += 1
        elif champion is not None:
            wins[champion] += 1
    return {
        "compared": len(compared),
        "not_comparable": len(comparison["cases"]) - len(compared),
        "answered": {
            arm["label"]: sum(1 for case in comparable if case["answered"][arm["label"]])
            for arm in comparison["arms"]
        },
        "wins": wins,
        "ties": ties,
        "exact": {
            arm["label"]: sum(
                1
                for case in comparable
                if case["answered"][arm["label"]]
                and (case[DETERMINISTIC][arm["label"]] or {}).get("verdict") == "EXACT"
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


def mean_text(value, answered, compared):
    """A category mean, annotated where the arm answered fewer cases than the
    category compares — two arms' means are only one number each, and this is what
    says whether they are means over the same cases.

    A measured 0.0 reads as 0.0; only an absent mean reads as unscored.
    """
    if not answered:
        return NOT_COMPARABLE
    if value is None:
        return UNSCORED
    return f"{value}" if answered == compared else f"{value} ({answered}/{compared})"


def score_text(case, axis, label, key):
    """One cell of a score table: the number, n/c where this arm has no comparable
    answer for the case, or the unscored sentinel where it answered and this axis
    holds no score for it."""
    if not case["comparable"] or not case["answered"][label]:
        return NOT_COMPARABLE
    cell = case[axis][label]
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


def deterministic_section(comparison, fitted_note=None):
    labels = [arm["label"] for arm in comparison["arms"]]
    header = ["case", "category"]
    for label in labels:
        header += [f"{label} word", f"{label} punct"]
    header.append("winner")

    rows = []
    for case in comparison["cases"]:
        row = [case["id"], case["category"]]
        for label in labels:
            row += [
                score_text(case, DETERMINISTIC, label, "word_score"),
                score_text(case, DETERMINISTIC, label, "punctuation_score"),
            ]
        row.append(winner_text(case, DETERMINISTIC))
        rows.append(row)

    category_header = ["category", "cases", "n/c"] + [f"{label} word" for label in labels]
    category_rows = [
        [
            category["category"],
            category["compared"],
            category["not_comparable"],
            *(
                mean_text(
                    category[DETERMINISTIC][label]["word_score"],
                    category["answered"][label],
                    category["compared"],
                )
                for label in labels
            ),
        ]
        for category in by_category(comparison)
    ]

    counts = headline(comparison, DETERMINISTIC)
    metrics = {
        arm["label"]: run_metric(comparison, arm["label"]) for arm in comparison["arms"]
    }
    return [
        f"DETERMINISTIC AXIS — {' | '.join(f'{label}: {metric}' for label, metric in metrics.items())}",
        *([fitted_note] if fitted_note else []),
        "",
        *table(header, rows),
        "",
        *table(category_header, category_rows),
        "",
        f"{counts['compared']} cases compared, {counts['not_comparable']} not comparable | "
        + " | ".join(
            f"{label} answered {counts['answered'][label]}, "
            f"exact {counts['exact'][label]}, wins {counts['wins'][label]}"
            for label in labels
        )
        + f" | ties {counts['ties']}",
    ]


def run_metric(comparison, label):
    """The metric a run's deterministic scores were computed under. Two runs scored
    under different metrics are not two readings of the same thing."""
    arm = next(arm for arm in comparison["arms"] if arm["label"] == label)
    return arm.get("metric") or "not scored"


def partial_coverage(arm, mode):
    """The cases one mode read of this arm, where that is not all of them."""
    coverage = arm.get("judge_coverage", {}).get(mode)
    if not coverage or coverage["scored"] == coverage["of"]:
        return None
    return coverage


def judge_identity(arm, mode):
    """Who took this arm's reading in this mode, and through what: a Judge Score
    holds within one judge model and one transport, so the pair is the identity
    and neither half of it stands alone."""
    return arm["judged_by"][mode], arm.get("judged_via", {}).get(mode)


def judged_by_text(arm, mode, name_transport=False):
    """Which judge read this arm in this mode, through what where the arms differ
    on it, and how much of the arm that judge got through.

    All three belong in the header, because it is where a reader meets the column
    before any number in it: a mean over part of an arm is not the arm's score,
    and a mean taken through another transport is not the same measurement.
    """
    judge, transport = judge_identity(arm, mode)
    if not judge:
        return f"not judged {mode}"
    text = f"judged by {judge}"
    if name_transport and transport:
        text += f" via {transport}"
    coverage = partial_coverage(arm, mode)
    return f"{text} ({coverage['scored']}/{coverage['of']} cases)" if coverage else text


def judge_section(comparison, mode, fitted_note=None):
    """One judge mode's table. An arm read in another mode is not scored here and
    wins nothing here: a blind reading and an anchored one measure different things,
    and putting them in one column would rank one against the other."""
    axis = judge_axis(mode)
    labels = [arm["label"] for arm in comparison["arms"]]
    identities = {judge_identity(arm, mode) for arm in comparison["arms"]}
    mixed = len(identities) > 1
    judges = {
        arm["label"]: judged_by_text(arm, mode, name_transport=mixed)
        for arm in comparison["arms"]
    }
    lines = [
        f"JUDGE AXIS ({mode}) — "
        + " | ".join(f"{label}: {judge}" for label, judge in judges.items())
    ]
    if mixed:
        lines.append(
            "These arms were judged by different judges or through different transports, "
            f"or one was not judged {mode}: a Judge Score holds only within one judge "
            "model, one transport and one mode, so these columns do not compare."
        )
    if any(partial_coverage(arm, mode) for arm in comparison["arms"]):
        lines.append(
            f"An arm above is marked with a case count: the {mode} judge read that many "
            "of the cases it answered and not the rest, so its means below are over a "
            "smaller case set than the arms beside it and do not rank against them."
        )
    if fitted_note:
        lines.append(fitted_note)

    header = ["case", "category", *(f"{label} overall" for label in labels), "winner"]
    rows = [
        [
            case["id"],
            case["category"],
            *(score_text(case, axis, label, "overall") for label in labels),
            winner_text(case, axis),
        ]
        for case in comparison["cases"]
    ]

    category_header = ["category", "cases", *(f"{label} overall" for label in labels)]
    category_rows = [
        [
            category["category"],
            category["compared"],
            *(
                mean_text(
                    category[axis][label],
                    category["answered"][label],
                    category["compared"],
                )
                for label in labels
            ),
        ]
        for category in by_category(comparison)
    ]

    counts = headline(comparison, axis)
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
    """Every cell that reads n/c, and why — grouped by reason, since a subset run
    gives one reason for every case it was not asked."""
    grouped = {}
    for case in comparison["cases"]:
        if case["note"]:
            grouped.setdefault((case["comparable"], case["note"]), []).append(case["id"])
    if not grouped:
        return []
    lines = ["NOT COMPARABLE — where a cell reads n/c", ""]
    for (comparable, note), case_ids in grouped.items():
        scope = (
            "the arms that answered them are compared"
            if comparable
            else "compared by nobody: these are not one case"
        )
        lines += [f"  {note} — {scope}", f"    {', '.join(case_ids)}"]
    return lines


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
        answered = next(
            (run.fingerprint(case["id"]) for run in runs if run.fingerprint(case["id"])),
            None,
        )
        if case["comparable"] and current and case_fingerprint(current) == answered:
            kept[case["id"]] = current["expected_output"]
    return kept


def detail_section(comparison, runs):
    """The differing outputs themselves — the part of a comparison a human reads."""
    reference = references(comparison, runs)
    lines = ["DETAIL — cases where the arms' outputs differ"]
    for case in comparison["cases"]:
        if not case["comparable"]:
            continue
        outputs = {
            arm_label(index): run.output(case["id"])
            for index, run in enumerate(runs)
            if run.fingerprint(case["id"])
        }
        if len(outputs) < 2 or len(set(outputs.values())) == 1:
            continue
        scores = " ".join(
            f"{label}={score_text(case, DETERMINISTIC, label, 'word_score')}"
            for label in outputs
        )
        lines += [
            "",
            f"--- {case['id']}  [{case['category']}]  word {scores}  "
            f"winner={case['winner'][DETERMINISTIC]} ---",
            f"{'EXPECTED':<9}: {reference.get(case['id'], REFERENCE_CHANGED)}",
            *(f"{label:<9}: {text}" for label, text in outputs.items()),
        ]
    return lines


def reference_provenance(comparison):
    """Where each compared case's reference came from, as the eval set on disk records it.

    Read the same way the references themselves are — from the set beside this
    module, tolerating its absence — so a comparison stays a read of the scores.
    A case nobody may compare is not in the reading: its reference is not what
    anything here was ranked on.
    """
    try:
        document = eval_set_document(comparison["eval_set"])
    except FileNotFoundError:
        return None
    on_disk = {case["id"]: case for case in document["evals"]}
    return {
        case["id"]: case_provenance(on_disk.get(case["id"], {}), document)
        for case in comparison["cases"]
        if case["comparable"]
    }


def fitted_reading(comparison, provenance):
    """How many of the compared references each arm's own prompt was fitted toward.

    An arm ranked against a key authored alongside the prompt it runs is measured
    on that key's specification as much as on model quality. That is a property of
    the comparison, so it is counted here and printed with the numbers rather than
    left to a document nobody opens.
    """
    if provenance is None:
        return None
    return {
        "compared": len(provenance),
        "unknown": sum(
            1 for record in provenance.values() if record["origin"] == "unknown"
        ),
        "arms": [
            {
                "label": arm["label"],
                "prompt_name": arm["prompt_name"],
                "fitted": sum(
                    1
                    for record in provenance.values()
                    if arm["prompt_name"] in record["fitted_toward"]
                ),
            }
            for arm in comparison["arms"]
        ],
        "bases": list(
            dict.fromkeys(
                record["basis"]
                for record in provenance.values()
                if set(record["fitted_toward"])
                & {arm["prompt_name"] for arm in comparison["arms"]}
            )
        ),
    }


def fitted_arms(reading):
    return [arm for arm in reading["arms"] if arm["fitted"]] if reading else []


def fitted_axis_note(reading):
    """The line that sits beside the numbers, naming every arm whose own prompt the
    references were fitted toward. None where no arm here is in that position."""
    named = [
        f"{arm['label']} ({arm['prompt_name']}, "
        f"{arm['fitted']}/{reading['compared']} references)"
        for arm in fitted_arms(reading)
    ]
    if not named:
        return None
    return (
        "Fitted references: "
        + ", ".join(named)
        + " — ranked against a key authored with their own prompt, so these columns "
        "are not a neutral reading of model quality."
    )


def fitted_reference_section(reading):
    """Where the answer key came from, stated before any number is read."""
    if reading is None:
        return [PROVENANCE_UNREADABLE]
    lines = ["FITTED REFERENCES — where the key these arms are ranked against came from", ""]
    for arm in reading["arms"]:
        plural = "reference was" if arm["fitted"] == 1 else "references were"
        fitted = (
            f"{arm['fitted']} of {reading['compared']} compared {plural} fitted "
            "toward this prompt"
            if arm["fitted"]
            else "no compared reference was fitted toward this prompt"
        )
        lines.append(f"  {arm['label']}  {arm['prompt_name']} — {fitted}.")
    if reading["unknown"]:
        lines.append(
            f"  {reading['unknown']} of {reading['compared']} compared references record "
            "no provenance: unknown, not assumed neutral."
        )
    for basis in reading["bases"]:
        lines += ["", textwrap.fill(basis, width=88, initial_indent="  ", subsequent_indent="  ")]
    return lines


def report(comparison, runs):
    reading = fitted_reading(comparison, reference_provenance(comparison))
    fitted = {arm["label"] for arm in fitted_arms(reading)}
    arms = [
        f"  {arm['label']}  {arm['run_id']}\n"
        f"     {arm['model']} @ {arm['endpoint']} | {arm['runtime']} | prompt {arm['prompt_name']} "
        f"({arm['prompt_sha256'][:12]})"
        + (" | references fitted toward this prompt" if arm["label"] in fitted else "")
        for arm in comparison["arms"]
    ]
    preamble = [f"COMPARISON — eval set {comparison['eval_set']}", "", *arms, "", AXIS_SEPARATION]
    if len(comparison["judge_modes"]) > 1:
        preamble += ["", MODE_SEPARATION]
    note = fitted_axis_note(reading) if reading else None
    sections = [
        preamble,
        fitted_reference_section(reading),
        deterministic_section(comparison, note),
        *(
            [
                # A blind reading never saw the reference, so a key fitted toward an
                # arm's prompt cannot have reached it; the note belongs only where
                # the reference was in front of the scorer.
                judge_section(comparison, mode, note if mode == "anchored" else None)
                for mode in comparison["judge_modes"]
            ]
            or [["JUDGE AXIS — none of these arms has been judged."]]
        ),
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
