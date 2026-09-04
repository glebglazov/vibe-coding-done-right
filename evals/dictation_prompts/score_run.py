#!/usr/bin/env python3
"""Score an archived Eval Run on the deterministic axis.

Usage:
  ./score_run.py ledger/20260904T101031Z__evals__claude-haiku-4-5-20251001__prompt_lean

Every number here is a pure function of the eval case and the output stored in
the ledger, so no model is called and the arm that produced the run need not
still exist. Rescoring an archived run yields the same numbers forever.

What the metric measures is what the eval set tests. Word order and repetition
are load-bearing — the set exercises reordering (R15) and false-start
consolidation (R5) — so the primary number is an order-sensitive edit distance
over the two word sequences. Punctuation (R2) is a requirement in its own right
and is scored as its own sequence rather than riding along attached to words.
Content preservation (R17) shows up as two asymmetric counts: words the speaker
said and the reference kept that the output dropped, and words the output
introduced that neither the speaker nor the reference used.

Both eval sets score on this one axis. A role-boundary case where the model
obeyed the dictated instruction instead of transcribing it produces text sharing
almost no order with the reference transcript, and lands at FAIL.
"""

import argparse
import json
import re
import sys
from collections import Counter
from statistics import mean

from ledger import ArchivedRun

# Bump when the numbers change meaning: a score is readable only under the metric
# that produced it, and archived score files outlive any one version of this file.
METRIC = "token-edit-distance/1"

# Style the harness classes as harmless, folded away before anything is measured.
STYLE_FOLDS = {"—": "-", "–": "-", "’": "'", "‘": "'", "“": '"', "”": '"'}

# A word is letters and digits, with an apostrophe kept inside it so a
# contraction stays one word. Everything else is punctuation, scored separately.
WORD = re.compile(r"[^\W_]+(?:'[^\W_]+)*")

CLOSE_SCORE = 0.9
DIFF_SCORE = 0.75
SCORE_DIGITS = 3

VERDICT_ORDER = ["EXACT", "NORM", "CLOSE", "DIFF", "FAIL", "ERROR"]


def normalize(text):
    """The one normalizer both eval sets are measured through: dash style, quote
    style, case and whitespace are not differences anyone here cares about."""
    for mark, folded in STYLE_FOLDS.items():
        text = text.replace(mark, folded)
    return " ".join(text.lower().split())


def word_sequence(normalized):
    return WORD.findall(normalized)


def punctuation_sequence(normalized):
    """Every punctuation mark in the order it appears, with the marks inside words
    (a contraction's apostrophe) left where they belong — in the words."""
    marks = []
    end_of_previous_word = 0
    for word in WORD.finditer(normalized):
        marks.extend(normalized[end_of_previous_word : word.start()].replace(" ", ""))
        end_of_previous_word = word.end()
    marks.extend(normalized[end_of_previous_word:].replace(" ", ""))
    return marks


def edit_distance(reference, actual):
    """Levenshtein over two token sequences: how many single-token insertions,
    deletions and substitutions turn one into the other. Order counts, which is
    the whole reason this replaces set overlap."""
    row = list(range(len(actual) + 1))
    for index, reference_token in enumerate(reference, start=1):
        next_row = [index]
        for position, actual_token in enumerate(actual, start=1):
            next_row.append(
                min(
                    row[position] + 1,
                    next_row[position - 1] + 1,
                    row[position - 1] + (reference_token != actual_token),
                )
            )
        row = next_row
    return row[-1]


def sequence_score(reference, actual):
    """Edit distance read as a similarity in [0, 1], with the distance itself kept:
    four edits is four edits whether the case is a sentence or a paragraph."""
    if not reference and not actual:
        return 1.0, 0
    distance = edit_distance(reference, actual)
    similarity = 1 - distance / max(len(reference), len(actual))
    return round(similarity, SCORE_DIGITS), distance


def content_loss(spoken, reference, actual):
    """Words the speaker said and the reference kept, missing from the output.

    Counted against the input rather than the reference alone, and only over what
    the reference retained — a filler the reference drops too is the prompt doing
    its job, not content loss.
    """
    retained = Counter(spoken) & Counter(reference)
    return sum((retained - Counter(actual)).values())


def invention(spoken, reference, actual):
    """Words in the output that appear in neither the input nor the reference."""
    return sum((Counter(actual) - (Counter(spoken) | Counter(reference))).values())


def verdict(expected, actual, word_score):
    if actual == expected:
        return "EXACT"
    if normalize(actual) == normalize(expected):
        return "NORM"
    if word_score > CLOSE_SCORE:
        return "CLOSE"
    if word_score > DIFF_SCORE:
        return "DIFF"
    return "FAIL"


def score_case(spoken_input, expected, actual):
    """Every deterministic number for one case, from its three texts and nothing else."""
    expected_normal, actual_normal = normalize(expected), normalize(actual)
    reference_words = word_sequence(expected_normal)
    actual_words = word_sequence(actual_normal)
    spoken_words = word_sequence(normalize(spoken_input))

    word_score, word_edits = sequence_score(reference_words, actual_words)
    punctuation_score, punctuation_edits = sequence_score(
        punctuation_sequence(expected_normal), punctuation_sequence(actual_normal)
    )
    return {
        "verdict": verdict(expected, actual, word_score),
        "word_score": word_score,
        "word_edits": word_edits,
        "punctuation_score": punctuation_score,
        "punctuation_edits": punctuation_edits,
        "content_loss": content_loss(spoken_words, reference_words, actual_words),
        "invented": invention(spoken_words, reference_words, actual_words),
    }


def mean_score(scores, key):
    """None, not zero, when nothing scored: a run whose every case errored has no mean."""
    if not scores:
        return None
    return round(mean(score[key] for score in scores), SCORE_DIGITS)


def score_run(run):
    scores = []
    for case, output in run.outputs():
        score = {"id": case["id"], "category": case["category"]}
        if output is None:
            score["verdict"] = "ERROR"
        else:
            score.update(score_case(case["input"], case["expected_output"], output))
        scores.append(score)

    scored = [score for score in scores if "word_score" in score]
    verdicts = Counter(score["verdict"] for score in scores)
    return {
        "run_id": run.run_id,
        "metric": METRIC,
        "eval_set": {
            "name": run.eval_set["name"],
            "fingerprint": run.eval_set["fingerprint"],
        },
        "verdicts": {
            name: verdicts[name] for name in VERDICT_ORDER if verdicts[name]
        },
        "word_score_mean": mean_score(scored, "word_score"),
        "punctuation_score_mean": mean_score(scored, "punctuation_score"),
        "content_loss": sum(score["content_loss"] for score in scored),
        "invented": sum(score["invented"] for score in scored),
        "cases": scores,
    }


ROW = "{id:<36} {category:<22} {verdict:<8} {word:>6} {punct:>6} {loss:>5} {invented:>4}"


def report(scores):
    lines = [
        scores["run_id"],
        f"metric: {scores['metric']} | set: {scores['eval_set']['name']} "
        f"({scores['eval_set']['fingerprint'][:12]})",
        "",
        ROW.format(
            id="case",
            category="category",
            verdict="verdict",
            word="word",
            punct="punct",
            loss="loss",
            invented="inv",
        ),
        "-" * 86,
    ]
    for score in scores["cases"]:
        lines.append(
            ROW.format(
                id=score["id"],
                category=score["category"],
                verdict=score["verdict"],
                word=score.get("word_score", "-"),
                punct=score.get("punctuation_score", "-"),
                loss=score.get("content_loss", "-"),
                invented=score.get("invented", "-"),
            )
        )
    verdicts = " ".join(f"{name}={count}" for name, count in scores["verdicts"].items())
    lines += [
        "",
        verdicts,
        f"word {scores['word_score_mean']} | punctuation {scores['punctuation_score_mean']} "
        f"| content loss {scores['content_loss']} words | invented {scores['invented']} words",
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", help="ledger directory of the run to score")
    arguments = parser.parse_args()

    run = ArchivedRun(arguments.run)
    scores = score_run(run)
    destination = run.directory / "deterministic.json"
    destination.write_text(json.dumps(scores, indent=2, ensure_ascii=False) + "\n")
    print(report(scores))
    print(f"\nScored: {destination}")


if __name__ == "__main__":
    sys.exit(main())
