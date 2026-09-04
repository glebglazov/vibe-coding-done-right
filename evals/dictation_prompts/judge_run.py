#!/usr/bin/env python3
"""Score an archived Eval Run on the judge axis.

Usage:
  export ANTHROPIC_API_KEY=$(op-cache read "op://Private/Anthropic/api_key")
  ./judge_run.py ledger/20260904T101031Z__evals__claude-haiku-4-5-20251001__prompt_lean

A Judge Score measures what no Deterministic Score reaches: whether the
speaker's voice survived, and whether the model over-edited. It reads each
archived output against the project's rubric in agents/assessor.md, so the
dimensions and weights live in that document rather than here.

A Judge Score is reproducible only within one judge model, so every case carries
the id of the judge that produced it, the scores land in judge.json beside — not
inside — deterministic.json, and nothing here ever averages the two axes
together. Judging reads the ledger only: a run is judged, and re-judged, without
being re-run.
"""

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from ledger import HERE, ArchivedRun, sha256_hex
from record_run import ANTHROPIC_ENDPOINT, AnthropicArm

# The standing judge, per ADR 0001: pinned independently of the arms so a model
# under measurement never grades its own run. Haiku is a contestant in the matrix
# this ledger exists to run, so it cannot sit here.
DEFAULT_JUDGE_MODEL = "claude-opus-5"

RUBRIC = HERE / "agents" / "assessor.md"
# The rubric proper. Its other sections describe the pre-ledger workflow — read
# the eval set yourself, append to results/scores.csv — which this supersedes.
RUBRIC_SECTIONS = ("Scoring dimensions", "Scoring guidelines")

SCORE_DIGITS = 3

JUDGE_INSTRUCTIONS = """
You are scoring one dictation-cleanup output against the rubric above.

Score only the dimensions punctuation, voice, captures, content and format, each
from 0.00 to 1.00, applying the rubric's deduction tables. Do not compute the
weighted average; that is done for you from your dimension scores.

Reply with one JSON object and nothing else:

{"punctuation": 0.0, "voice": 0.0, "captures": 0.0, "content": 0.0,
 "format": 0.0, "notes": "one short sentence naming the differences that cost"}
""".strip()

CASE = """
Eval case: {id} (category: {category})
What it exercises: {exercises}

<dictation>
{input}
</dictation>

<expected_output>
{expected_output}
</expected_output>

<actual_output>
{actual}
</actual_output>
""".strip()

CAPTURE_TAG = re.compile(r"<capture\b")
WEIGHT_LINE = re.compile(r"^\s*-\s+\*\*overall\*\*.*?:(.*)$", re.MULTILINE | re.IGNORECASE)
WEIGHT = re.compile(r"([a-z]+)\s+(\d*\.?\d+)")
JSON_OBJECT = re.compile(r"\{.*\}", re.DOTALL)


def rubric_text():
    """Only the scoring half of the assessor document, which is the rubric itself."""
    sections = {
        title.strip(): body
        for title, body in re.findall(r"^## ([^\n]+)$(.*?)(?=^## |\Z)", RUBRIC.read_text(), re.MULTILINE | re.DOTALL)
    }
    missing = [name for name in RUBRIC_SECTIONS if name not in sections]
    if missing:
        raise SystemExit(f"{RUBRIC.name} no longer holds {' and '.join(missing)}; cannot judge.")
    return "\n\n".join(f"## {name}{sections[name].rstrip()}" for name in RUBRIC_SECTIONS)


def rubric_weights(rubric):
    """The rubric's documented weights, read out of the rubric so the two cannot drift.

    The overall dimension is the weighted average of the other five, and the
    rubric states those weights on its own line; parsing it means this file never
    holds a second, quietly stale copy of them.
    """
    line = WEIGHT_LINE.search(rubric)
    if not line:
        raise SystemExit(f"{RUBRIC.name} no longer states the overall weights; cannot judge.")
    weights = {name: float(weight) for name, weight in WEIGHT.findall(line.group(1))}
    if round(sum(weights.values()), 6) != 1.0:
        raise SystemExit(f"{RUBRIC.name} weights do not sum to 1: {weights}")
    return weights


class Judge:
    """The pinned judge, reading outputs against the rubric.

    It reaches the Anthropic API through the same backend an arm uses, because
    that is the transport; it is deliberately not an arm — nothing here is being
    measured, and the judge is chosen so that it is not.
    """

    def __init__(self, backend):
        self.backend = backend
        self.model = backend.model
        self.rubric = rubric_text()
        self.weights = rubric_weights(self.rubric)
        self.system_prompt = f"{self.rubric}\n\n{JUDGE_INSTRUCTIONS}"

    def identity(self):
        return {
            "model": self.model,
            "endpoint": self.backend.endpoint,
            "runtime": self.backend.runtime(),
            "rubric": str(RUBRIC.relative_to(HERE)),
            "rubric_sha256": sha256_hex(self.rubric),
            "sampling": self.backend.sampling,
        }

    def score(self, case, actual):
        reply = self.backend.complete(self.system_prompt, CASE.format(actual=actual, **case))
        return self.read(reply, case)

    def read(self, reply, case):
        """The judge's dimensions, with the rubric's non-judgement calls applied here.

        Two parts of the rubric are not opinions and are not left to the model: a
        case with no capture tag scores 1.00 by definition, and a case with one
        scores the tag's preservation 0 or 1 with nothing in between.
        """
        match = JSON_OBJECT.search(reply)
        if not match:
            raise ValueError(f"judge did not return JSON: {reply[:200]!r}")
        verdict = json.loads(match.group(0))

        dimensions = {name: float(verdict[name]) for name in self.weights}
        if CAPTURE_TAG.search(case["input"]):
            dimensions["captures"] = 1.0 if dimensions["captures"] >= 1.0 else 0.0
        else:
            dimensions["captures"] = 1.0
        return dimensions, str(verdict.get("notes", "")).strip()

    def overall(self, dimensions):
        return round(sum(dimensions[name] * weight for name, weight in self.weights.items()), SCORE_DIGITS)


def judge_run(run, judge):
    """Every case of an archived run scored by one judge, and nothing else in the file.

    Deterministic scores are not read here and not written here: the two axes are
    reproducible under different conditions, so they are reported side by side and
    never folded into one number.
    """
    print(f"{run.run_id}\njudge: {judge.model} | rubric: {RUBRIC.name}\n---")

    scores = []
    for case, output in run.outputs():
        print(f"  {case['id']:<40}", end="", flush=True)
        score = {
            "id": case["id"],
            "category": case["category"],
            # On the case, not only in the header: a Judge Score read apart from
            # its judge means nothing, and these rows get copied around.
            "judge_model": judge.model,
        }
        if output is None:
            score["error"] = "no output recorded for this case"
            print("SKIP no output")
        else:
            try:
                dimensions, notes = judge.score(case, output)
            except (OSError, ValueError, KeyError) as failure:
                score["error"] = f"{type(failure).__name__}: {failure}"
                print(f"FAIL {score['error']}")
            else:
                score["overall"] = judge.overall(dimensions)
                score["dimensions"] = {
                    name: round(value, SCORE_DIGITS) for name, value in dimensions.items()
                }
                score["notes"] = notes
                print(f"{score['overall']:.3f}  {notes[:60]}")
        scores.append(score)

    judged = [score for score in scores if "dimensions" in score]
    return {
        "run_id": run.run_id,
        "judged_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "judge": judge.identity(),
        "weights": judge.weights,
        "eval_set": {
            "name": run.eval_set["name"],
            "fingerprint": run.eval_set["fingerprint"],
        },
        "overall_mean": mean_of(judged, lambda score: score["overall"]),
        "dimension_means": {
            name: mean_of(judged, lambda score, name=name: score["dimensions"][name])
            for name in judge.weights
        },
        "cases": scores,
    }


def mean_of(scores, value):
    """None, not zero, when nothing was judged: an unjudged run has no mean."""
    if not scores:
        return None
    return round(sum(value(score) for score in scores) / len(scores), SCORE_DIGITS)


ROW = "{id:<36} {overall:>7} {content:>7} {punctuation:>11} {voice:>6} {captures:>8} {format:>6}"


def report(scores):
    header = ROW.format(
        id="case",
        overall="overall",
        content="content",
        punctuation="punctuation",
        voice="voice",
        captures="captures",
        format="format",
    )
    lines = [
        scores["run_id"],
        f"judge: {scores['judge']['model']} | rubric: {scores['judge']['rubric']} "
        f"({scores['judge']['rubric_sha256'][:12]})",
        "",
        header,
        "-" * len(header),
    ]
    for score in scores["cases"]:
        dimensions = score.get("dimensions", {})
        lines.append(
            ROW.format(
                id=score["id"],
                overall=score.get("overall", "-"),
                **{name: dimensions.get(name, "-") for name in ("content", "punctuation", "voice", "captures", "format")},
            )
        )
    means = " | ".join(
        f"{name} {value}" for name, value in scores["dimension_means"].items()
    )
    lines += ["", f"overall {scores['overall_mean']} | {means}"]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", help="ledger directory of the run to judge")
    parser.add_argument(
        "--judge-model",
        default=DEFAULT_JUDGE_MODEL,
        help=f"model that grades the run (default: {DEFAULT_JUDGE_MODEL})",
    )
    parser.add_argument("--endpoint", default=ANTHROPIC_ENDPOINT, help="judge endpoint URL")
    arguments = parser.parse_args()

    run = ArchivedRun(arguments.run)
    if arguments.judge_model == run.manifest["arm"]["model"]:
        raise SystemExit(
            f"{arguments.judge_model} is the arm this run was recorded with; "
            "a model must not grade its own arm. Pass --judge-model."
        )

    judge = Judge(AnthropicArm(arguments.judge_model, arguments.endpoint))
    scores = judge_run(run, judge)
    destination = run.directory / "judge.json"
    destination.write_text(json.dumps(scores, indent=2, ensure_ascii=False) + "\n")
    print(f"---\n{report(scores)}\n\nJudged: {destination}")
    return sum(1 for score in scores["cases"] if "error" in score)


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
