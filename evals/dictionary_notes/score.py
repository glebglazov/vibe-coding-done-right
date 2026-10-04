#!/usr/bin/env python3
"""Score every Eval Run in one Run Ledger and print the per-arm table.

Each run gets `spelling.json` beside its manifest. Per case:
- `hit` (misheard only): the expected Dictionary spelling is in the output.
- `insertions`: Dictionary spellings in the output that are neither in the
  input nor the case's expected spelling. On a sounds_alike case any one of
  them is a false insertion; on a misheard case it is the wrong entry.
- `note_leaks`: Dictionary notes in the output that neither the input nor any
  output of an arm without notes (any model, any repeat, same case) holds. A
  model that writes "container orchestration tool" about Docker Swarm with no
  notes in its prompt says it in its own words, so that phrase is not a leak
  there in any arm; only a notes arm can leak.

Only cases whose Case Fingerprint matches the eval set on disk are scored, so a
run recorded before a case was corrected never mixes into today's numbers.

  ./score.py                      # table over every run in ./ledger
  ./score.py --ledger ledger-v2   # the same over another ledger
  ./score.py --flips              # also list cases whose count differs between arms,
                                  # with the spellings inserted on sounds_alike cases,
                                  # and sum each PAIRS comparison

Below the table, false insertions are split by each sounds_alike case's `trap`,
and every inserted spelling is counted, so one entry's Note (a "my own name"
sign-off) shows apart from the rest.
"""

import argparse
import json
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

from dictionary import ARMS, HERE, HINT_ARMS, MODES, TRAPS, cases, contains, entries

sys.path.insert(0, str(HERE.parent / "dictation_prompts"))
from ledger import case_fingerprint  # noqa: E402

# (before, after) arm pairs that --flips sums per case: the guarded intro against
# the notes arm it changes and against the spellings-only arm it must match on insertions.
PAIRS = (("spellings_notes", "spellings_notes_guarded"), ("spellings", "spellings_notes_guarded"))


def score_case(case, output):
    expected = case["expected_output"]
    inserted = [
        e["spelling"] for e in entries()
        if e["spelling"] != expected
        and contains(output, e["spelling"]) and not contains(case["input"], e["spelling"])
    ]
    leaks = [
        e["note"] for e in entries()
        if e["note"].lower() in output.lower() and e["note"].lower() not in case["input"].lower()
    ]
    scored = {"id": case["id"], "category": case["category"], "insertions": inserted, "note_leaks": leaks}
    if case["category"] == "misheard":
        scored["hit"] = contains(output, expected)
    return scored


def score_run(run_dir):
    """Score one run in memory; `main` drops unprompted note text and writes spelling.json."""
    manifest = json.loads((run_dir / "manifest.json").read_text())
    current = {case["id"]: case for case in cases(mode_of(manifest))}
    scored = []
    for entry in manifest["cases"]:
        case = current.get(entry["id"])
        if case is None or case_fingerprint(case) != entry["case_fingerprint"] or "output_file" not in entry:
            continue
        scored.append(score_case(case, (run_dir / entry["output_file"]).read_text()))
    return manifest, scored


def drop_unprompted_notes(scored_runs):
    """Keep a note leak only where no arm without notes in its prompt wrote the same text."""
    unprompted = defaultdict(set)
    for manifest, scored in scored_runs:
        if not shows_notes(arm_of(manifest)):
            for s in scored:
                unprompted[(mode_of(manifest), s["id"])].update(s["note_leaks"])
    for manifest, scored in scored_runs:
        for s in scored:
            s["note_leaks"] = [n for n in s["note_leaks"] if n not in unprompted[(mode_of(manifest), s["id"])]]


def shows_notes(arm):
    return arm in HINT_ARMS and HINT_ARMS[arm][1]


def mode_of(manifest):
    return next(mode for mode, name in MODES.items() if name == manifest["eval_set"]["name"])


def arm_of(manifest):
    return manifest["arm"]["prompt_name"].split("_", 1)[1]


def rates(scored):
    positives = [s for s in scored if s["category"] == "misheard"]
    negatives = [s for s in scored if s["category"] == "sounds_alike"]
    return {
        "hit": sum(s["hit"] for s in positives) / len(positives),
        "false_insertion": sum(bool(s["insertions"]) for s in negatives) / len(negatives),
        "wrong_entry": sum(bool(s["insertions"]) for s in positives) / len(positives),
        "note_leak": sum(bool(s["note_leaks"]) for s in scored) / len(scored),
        "n_pos": len(positives),
        "n_neg": len(negatives),
    }


def spread(values):
    mean = statistics.mean(values)
    return f"{mean:.1%} ({min(values):.0%}–{max(values):.0%})"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flips", action="store_true")
    parser.add_argument("--ledger", default="ledger", help="Run Ledger directory under this one")
    arguments = parser.parse_args()
    ledger = HERE / arguments.ledger

    run_dirs = sorted(p for p in ledger.iterdir() if (p / "manifest.json").exists())
    scored_runs = [score_run(run_dir) for run_dir in run_dirs]
    drop_unprompted_notes(scored_runs)
    runs = defaultdict(list)
    for run_dir, (manifest, scored) in zip(run_dirs, scored_runs):
        (run_dir / "spelling.json").write_text(json.dumps(scored, indent=1, ensure_ascii=False) + "\n")
        runs[(manifest["arm"]["model"], mode_of(manifest), arm_of(manifest))].append(scored)

    print("| model | mode | arm | runs | hit rate (misheard) | false insertion (sounds_alike) | wrong entry (misheard) | note leak |")
    print("|---|---|---|---|---|---|---|---|")
    for (model, mode, arm), scored_runs in sorted(runs.items(), key=lambda kv: (kv[0][0], kv[0][1], ARMS.index(kv[0][2]))):
        per_run = [rates(s) for s in scored_runs]
        n = per_run[0]
        print(
            f"| {model} | {mode} (n={n['n_pos']}+{n['n_neg']}) | {arm} | {len(per_run)} "
            f"| {spread([r['hit'] for r in per_run])} "
            f"| {spread([r['false_insertion'] for r in per_run])} "
            f"| {spread([r['wrong_entry'] for r in per_run])} "
            f"| {spread([r['note_leak'] for r in per_run])} |"
        )

    print_traps(runs)
    print_inserted_spellings(runs)
    if arguments.flips:
        print_flips(runs)


def ordered_cells(runs):
    return sorted(runs.items(), key=lambda kv: (kv[0][0], kv[0][1], ARMS.index(kv[0][2])))


def print_traps(runs):
    """False insertions per trap, summed over every repeat of a cell: k of n case answers."""
    print("\n## False insertion by trap (k/n over all repeats)\n")
    print("| model | mode | arm | " + " | ".join(TRAPS) + " |")
    print("|---|---|---|" + "---|" * len(TRAPS))
    for (model, mode, arm), scored_runs in ordered_cells(runs):
        trap_of = {c["id"]: c.get("trap") for c in cases(mode)}
        inserted, total = Counter(), Counter()
        for scored in scored_runs:
            for s in scored:
                if s["category"] == "sounds_alike":
                    total[trap_of[s["id"]]] += 1
                    inserted[trap_of[s["id"]]] += bool(s["insertions"])
        cells = [
            f"{inserted[t] / total[t]:.0%} ({inserted[t]}/{total[t]})" if total[t] else "–"
            for t in TRAPS
        ]
        print(f"| {model} | {mode} | {arm} | " + " | ".join(cells) + " |")


def print_inserted_spellings(runs):
    """Which spellings the model added, summed over every repeat, split by case category."""
    print("\n## Inserted spellings (count over all repeats)\n")
    print("| model | mode | arm | on sounds_alike | on misheard (wrong entry) |")
    print("|---|---|---|---|---|")
    for (model, mode, arm), scored_runs in ordered_cells(runs):
        counts = {"sounds_alike": Counter(), "misheard": Counter()}
        for scored in scored_runs:
            for s in scored:
                counts[s["category"]].update(s["insertions"])
        cells = [", ".join(f"{k}×{n}" for k, n in counts[c].most_common()) or "–" for c in counts]
        print(f"| {model} | {mode} | {arm} | " + " | ".join(cells) + " |")


def print_flips(runs):
    """Per case, hits (misheard) or insertions (sounds_alike) summed over repeats, per arm.

    A sounds_alike row also names what each arm inserted, and its trap.
    """
    for model, mode in sorted({(m, d) for m, d, _ in runs}):
        print(f"\n## {model} / {mode}")
        tallies = {}
        for arm in ARMS:
            tally = defaultdict(int)
            inserted = defaultdict(Counter)
            for scored in runs.get((model, mode, arm), []):
                for s in scored:
                    tally[s["id"]] += s["hit"] if s["category"] == "misheard" else bool(s["insertions"])
                    inserted[s["id"]].update(s["insertions"])
            tallies[arm] = (tally, inserted)
        reps = {arm: len(runs.get((model, mode, arm), [])) for arm in ARMS}
        print("case | " + " | ".join(f"{arm} (/{reps[arm]})" for arm in ARMS))
        for case in cases(mode):
            counts = [tallies[arm][0][case["id"]] for arm in ARMS]
            if len(set(counts)) <= 1:
                continue
            if case["category"] == "misheard":
                print(f"mish {case['id']} | " + " | ".join(map(str, counts)))
                continue
            inserted = [
                ", ".join(f"{k}×{n}" for k, n in tallies[arm][1][case["id"]].items())
                for arm in ARMS
            ]
            print(
                f"neg[{case['trap']}] {case['id']} | "
                + " | ".join(f"{n} {i}".strip() for n, i in zip(counts, inserted))
            )
        for before, after in PAIRS:
            print_pair(mode, before, after, {arm: tallies[arm][0] for arm in ARMS})


def print_pair(mode, before, after, tallies):
    """Cases that moved from `before` to `after`, as summed per-case count changes."""
    moved = {"misheard": ([], []), "sounds_alike": ([], [])}
    for case in cases(mode):
        delta = tallies[after][case["id"]] - tallies[before][case["id"]]
        if delta:
            moved[case["category"]][delta > 0].append(f"{case['id']} {delta:+d}")
    lost_hits, gained_hits = moved["misheard"]
    fewer_insertions, more_insertions = moved["sounds_alike"]
    print(f"\n{before} -> {after}")
    print(f"  misheard, hits lost: {', '.join(lost_hits) or '-'}")
    print(f"  misheard, hits gained: {', '.join(gained_hits) or '-'}")
    print(f"  sounds_alike, insertions gone: {', '.join(fewer_insertions) or '-'}")
    print(f"  sounds_alike, insertions added: {', '.join(more_insertions) or '-'}")


if __name__ == "__main__":
    main()
