#!/usr/bin/env python3
"""Score an archived Eval Run on the judge axis.

Usage:
  export ANTHROPIC_API_KEY=$(op-cache read "op://Private/Anthropic/api_key")
  ./judge_run.py ledger/20260904T101031Z__evals__claude-haiku-4-5-20251001__prompt_lean

A Judge Score measures what no Deterministic Score reaches: whether the
speaker's voice survived, and whether the model over-edited. It reads each
archived output against the project's rubric in agents/assessor.md, so the
dimensions and weights live in that document rather than here.

The judge reads in one of two modes, and which one it was is the whole meaning of
the number:

  --mode blind      the dictation and the output, and no reference at all. A
                    second opinion: it can disagree with the reference, because
                    it has never seen it.
  --mode anchored   the dictation, the output and the case's expected output,
                    scored as deductions away from that reference. It measures
                    agreement with the reference, so it is not evidence
                    independent of the deterministic axis, which is a pure
                    function of that same reference.

The two modes land in two files, are never averaged, and are never ranked in one
column. A Judge Score is reproducible only within one judge model and one mode,
so every case carries both. Judging reads the ledger only: a run is judged, and
re-judged, without being re-run.
"""

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from ledger import HERE, JUDGE_FILES, ArchivedRun, sha256_hex
from record_run import ANTHROPIC_ENDPOINT, AnthropicArm

# The standing judge, per ADR 0001: pinned independently of the arms so a model
# under measurement never grades its own run. Haiku is a contestant in the matrix
# this ledger exists to run, so it cannot sit here.
DEFAULT_JUDGE_MODEL = "claude-opus-5"

RUBRIC = HERE / "agents" / "assessor.md"

SCORE_DIGITS = 3

REPLY_FORMAT = """
Score only the dimensions punctuation, voice, captures, content and format, each
from 0.00 to 1.00, applying the rubric's deduction tables. Do not compute the
weighted average; that is done for you from your dimension scores.

Reply with one JSON object and nothing else:

{"punctuation": 0.0, "voice": 0.0, "captures": 0.0, "content": 0.0,
 "format": 0.0, "notes": "one short sentence naming what cost the output"}
""".strip()

ANCHORED_INSTRUCTIONS = f"""
You are scoring one dictation-cleanup output against the rubric above. You are
shown the expected output; score how far the output departs from it.

{REPLY_FORMAT}
""".strip()

BLIND_INSTRUCTIONS = f"""
You are scoring one dictation-cleanup output against the rubric above.

You are not shown a reference answer, and there is not one. Score what the output
did to what the speaker said: whether the speaker's voice survived, whether it was
edited past what cleanup needs, whether the meaning changed, whether the format is
clean. Do not guess at how someone else would have written it — a wording you
would not have chosen is not a deduction unless the rubric names it as one.

{REPLY_FORMAT}
""".strip()

ANCHORED_CASE = """
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

# No expected output, and no "what it exercises" either: the eval set writes that
# line as the transformation it wants, which is the reference in prose.
BLIND_CASE = """
Eval case: {id} (category: {category})

<dictation>
{input}
</dictation>

<actual_output>
{actual}
</actual_output>
""".strip()


class Mode:
    """One way of reading a case: which half of the rubric applies, what the judge
    is shown, and where the scores land."""

    def __init__(self, name, guidelines, instructions, case_template):
        self.name = name
        # The rubric proper. The assessor document's other sections describe the
        # pre-ledger workflow — read the eval set yourself, append to
        # results/scores.csv — which this supersedes.
        self.sections = ("Scoring dimensions", guidelines)
        self.instructions = instructions
        self.case_template = case_template
        self.filename = JUDGE_FILES[name]


MODES = {
    mode.name: mode
    for mode in (
        Mode("blind", "Blind scoring guidelines", BLIND_INSTRUCTIONS, BLIND_CASE),
        Mode("anchored", "Scoring guidelines", ANCHORED_INSTRUCTIONS, ANCHORED_CASE),
    )
}
DEFAULT_MODE = "blind"

# What a blind prompt must not contain. The rubric is a document a human edits, so
# a deduction rewritten against the reference would otherwise turn the blind mode
# back into the anchored one without anything saying so.
REFERENCE_MENTION = re.compile(r"expected output|reference (output|answer)", re.IGNORECASE)

CAPTURE_TAG = re.compile(r"<capture\b")
WEIGHT_LINE = re.compile(r"^\s*-\s+\*\*overall\*\*.*?:(.*)$", re.MULTILINE | re.IGNORECASE)
WEIGHT = re.compile(r"([a-z]+)\s+(\d*\.?\d+)")
JSON_OBJECT = re.compile(r"\{.*\}", re.DOTALL)


def rubric_text(mode):
    """The half of the assessor document this mode scores against, which is the
    rubric it applies: the shared dimensions, and that mode's deduction tables."""
    sections = {
        title.strip(): body
        for title, body in re.findall(r"^## ([^\n]+)$(.*?)(?=^## |\Z)", RUBRIC.read_text(), re.MULTILINE | re.DOTALL)
    }
    missing = [name for name in mode.sections if name not in sections]
    if missing:
        raise SystemExit(f"{RUBRIC.name} no longer holds {' and '.join(missing)}; cannot judge.")
    rubric = "\n\n".join(f"## {name}{sections[name].rstrip()}" for name in mode.sections)
    if mode.name == "blind" and REFERENCE_MENTION.search(rubric):
        raise SystemExit(
            f"{RUBRIC.name}'s {' and '.join(mode.sections)} now name a reference output; "
            "a blind reading that scores against one is an anchored reading."
        )
    return rubric


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

    def __init__(self, backend, mode=MODES[DEFAULT_MODE]):
        self.backend = backend
        self.model = backend.model
        self.mode = mode
        self.rubric = rubric_text(mode)
        self.weights = rubric_weights(self.rubric)
        self.system_prompt = f"{self.rubric}\n\n{mode.instructions}"

    def prompt_for(self, case, actual):
        """What the judge is shown for one case — the whole of it, so a test can
        read it and see for itself what the mode did or did not include."""
        return self.mode.case_template.format(actual=actual, **case)

    def identity(self):
        return {
            "model": self.model,
            "mode": self.mode.name,
            "endpoint": self.backend.endpoint,
            "runtime": self.backend.runtime(),
            "rubric": str(RUBRIC.relative_to(HERE)),
            "rubric_sha256": sha256_hex(self.rubric),
            "sampling": self.backend.sampling,
        }

    def score(self, case, actual):
        reply = self.backend.complete(self.system_prompt, self.prompt_for(case, actual))
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
    print(f"{run.run_id}\njudge: {judge.model} ({judge.mode.name}) | rubric: {RUBRIC.name}\n---")

    scores = []
    for case, output in run.outputs():
        print(f"  {case['id']:<40}", end="", flush=True)
        score = {
            "id": case["id"],
            "category": case["category"],
            # On the case, not only in the header: a Judge Score read apart from
            # the judge and the mode that produced it means nothing, and these rows
            # get copied around.
            "judge_model": judge.model,
            "judge_mode": judge.mode.name,
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
        f"judge: {scores['judge']['model']} ({scores['judge']['mode']}) | "
        f"rubric: {scores['judge']['rubric']} "
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
    parser.add_argument(
        "--mode",
        choices=sorted(MODES),
        default=DEFAULT_MODE,
        help=(
            "blind: the dictation and the output, no reference. anchored: the "
            f"reference too, scored as deductions from it (default: {DEFAULT_MODE})"
        ),
    )
    parser.add_argument("--endpoint", default=ANTHROPIC_ENDPOINT, help="judge endpoint URL")
    arguments = parser.parse_args()

    run = ArchivedRun(arguments.run)
    if arguments.judge_model == run.manifest["arm"]["model"]:
        raise SystemExit(
            f"{arguments.judge_model} is the arm this run was recorded with; "
            "a model must not grade its own arm. Pass --judge-model."
        )

    judge = Judge(AnthropicArm(arguments.judge_model, arguments.endpoint), MODES[arguments.mode])
    scores = judge_run(run, judge)
    # One file per mode: a blind reading never overwrites the anchored record of
    # what that mode read, and neither is ever read as the other.
    destination = run.directory / judge.mode.filename
    destination.write_text(json.dumps(scores, indent=2, ensure_ascii=False) + "\n")
    print(f"---\n{report(scores)}\n\nJudged: {destination}")
    return sum(1 for score in scores["cases"] if "error" in score)


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
