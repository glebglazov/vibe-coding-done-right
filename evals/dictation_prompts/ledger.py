#!/usr/bin/env python3
"""The Run Ledger — where an Eval Run is archived, and where it is read back from.

A run is scored long after the arm that produced it is gone, so everything needed
to judge one is read from here: the manifest, the eval set it was recorded
against, and the raw output of every case. A comparison comes back later still
and reads the scores themselves, without the eval set or the arm.
"""

import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
LEDGER = HERE / "ledger"


def read_json(path):
    return json.loads(Path(path).read_text())


def sha256_hex(*parts):
    digest = hashlib.sha256()
    for part in parts:
        chunk = part.encode("utf-8")
        # Length-prefix each part so no pair of fields can be re-split ambiguously.
        digest.update(f"{len(chunk)}:".encode("ascii"))
        digest.update(chunk)
    return digest.hexdigest()


def case_fingerprint(case):
    """A case's meaning: its input together with the reference output it is judged against."""
    return sha256_hex(case["input"], case["expected_output"])


def eval_set_fingerprint(cases):
    return sha256_hex(*(case_fingerprint(case) for case in cases))


def subset_cases(cases, subset):
    """The cases an arm was asked to answer: the whole set, or a named subset of it.

    An arm that cannot answer part of a set — an English-only model against the
    one multilingual case — records the subset rather than a fork of the set, so
    every case it did answer stays comparable with every arm recorded over all
    of them.
    """
    if subset is None:
        return cases
    admitted = set(subset["case_ids"])
    return [case for case in cases if case["id"] in admitted]


def eval_set_cases(name):
    """The cases of the eval set a run names, as they stand on disk now.

    A run names its set by filename, read from beside this module; an absolute
    path is honoured as given, which is how a test's scratch copy of a set is read.
    """
    return read_json(HERE / name)["evals"]


class ArchivedRun:
    """One recorded run, reopened for scoring.

    Loading verifies that every case the run answered still fingerprints to what
    it answered — a reference output edited since then would silently change every
    score computed from it. The check is per case rather than over the whole set,
    for the same reason a comparison's is: a set that has grown since the run was
    recorded still holds every case the run answered, and asking a run about cases
    it was never asked is a question nobody put to it.
    """

    def __init__(self, directory):
        self.directory = Path(directory).resolve()
        self.manifest = read_json(self.directory / "manifest.json")
        self.eval_set = self.manifest["eval_set"]

        answered = {entry["id"]: entry["case_fingerprint"] for entry in self.manifest["cases"]}
        on_disk = {case["id"]: case for case in eval_set_cases(self.eval_set["name"])}
        changed = [
            case_id
            for case_id, fingerprint in answered.items()
            if case_id not in on_disk or case_fingerprint(on_disk[case_id]) != fingerprint
        ]
        if changed:
            raise SystemExit(
                f"{self.eval_set['name']} has changed since {self.run_id} was recorded "
                f"({', '.join(changed)}): the run's outputs no longer answer these cases."
            )
        self.cases = [on_disk[case_id] for case_id in answered]

    @property
    def run_id(self):
        return self.manifest["run_id"]

    def outputs(self):
        """Each case with what the arm produced for it, or None where the call failed."""
        by_id = {case["id"]: case for case in self.cases}
        for entry in self.manifest["cases"]:
            output = None
            if "output_file" in entry:
                output = (self.directory / entry["output_file"]).read_text()
            yield by_id[entry["id"]], output


# The two readings the judge axis holds, and the file each lands in. A blind
# reading and an anchored one are different measurements of different things, so
# neither overwrites the other and neither is read out of the other's file.
JUDGE_FILES = {"blind": "judge_blind.json", "anchored": "judge.json"}
DEFAULT_JUDGE_MODE = "anchored"


class AxisScores:
    """One axis' score file: its run-level reading, and its reading per case."""

    def __init__(self, scores):
        self.summary = scores
        self.cases = {case["id"]: case for case in scores["cases"]}


class ScoredRun:
    """One recorded run as a comparison reads it: what produced it, and the scores
    already computed over it on each axis.

    Nothing is re-derived here, so no eval set is needed and no model is called.
    The whole-set fingerprint is deliberately not checked either: a comparison
    admits a case on its own Case Fingerprint, which is what lets the eval set
    grow without invalidating the runs recorded before it.
    """

    def __init__(self, directory):
        self.directory = Path(directory).resolve()
        self.manifest = read_json(self.directory / "manifest.json")
        self.recorded = {entry["id"]: entry for entry in self.manifest["cases"]}
        self.deterministic = self.axis("deterministic.json")
        self.judges = self.judge_readings()

    def axis(self, filename):
        """One axis' scores, or None where this run has not been scored on it."""
        path = self.directory / filename
        return AxisScores(read_json(path)) if path.exists() else None

    def judge_readings(self):
        """Every judge reading this run carries, keyed by the mode that produced it.

        A file judged before the modes were told apart names no mode, and is the
        anchored reading — that is what the judge saw. A file whose recorded mode
        disagrees with the file it sits in is refused rather than filed under
        either, since which one it is decides who it may be compared with.
        """
        readings = {}
        for mode, filename in JUDGE_FILES.items():
            scores = self.axis(filename)
            if scores is None:
                continue
            recorded = scores.summary["judge"].get("mode", DEFAULT_JUDGE_MODE)
            if recorded != mode:
                raise SystemExit(
                    f"{self.directory / filename} records judge mode {recorded!r}, "
                    f"which belongs in {JUDGE_FILES.get(recorded, 'no known file')}."
                )
            readings[mode] = scores
        return readings

    @property
    def run_id(self):
        return self.manifest["run_id"]

    @property
    def arm(self):
        return self.manifest["arm"]

    @property
    def eval_set(self):
        return self.manifest["eval_set"]

    def case_ids(self):
        return list(self.recorded)

    def fingerprint(self, case_id):
        """The identity of the case as this run answered it, or None if it did not."""
        entry = self.recorded.get(case_id)
        return entry["case_fingerprint"] if entry else None

    def category(self, case_id):
        entry = self.recorded.get(case_id)
        return entry["category"] if entry else None

    def output(self, case_id):
        """What the arm produced for the case, or None where its call failed."""
        entry = self.recorded.get(case_id, {})
        if "output_file" not in entry:
            return None
        return (self.directory / entry["output_file"]).read_text()
