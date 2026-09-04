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


def eval_set_cases(name):
    """The cases of the eval set a run names, as they stand on disk now.

    A run names its set by filename, read from beside this module; an absolute
    path is honoured as given, which is how a scratch copy of a set is read.
    """
    return read_json(HERE / name)["evals"]


class ArchivedRun:
    """One recorded run, reopened for scoring.

    Loading verifies the eval set still fingerprints to what the run was recorded
    against — a reference output edited since then would silently change every
    score computed from it.
    """

    def __init__(self, directory):
        self.directory = Path(directory).resolve()
        self.manifest = read_json(self.directory / "manifest.json")
        self.eval_set = self.manifest["eval_set"]

        eval_set_path = HERE / self.eval_set["name"]
        self.cases = eval_set_cases(self.eval_set["name"])
        fingerprint = eval_set_fingerprint(self.cases)
        if fingerprint != self.eval_set["fingerprint"]:
            raise SystemExit(
                f"{eval_set_path.name} has changed since {self.run_id} was recorded "
                f"({fingerprint[:12]} != {self.eval_set['fingerprint'][:12]}): "
                "the run's outputs no longer answer these cases."
            )

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
        self.judge = self.axis("judge.json")

    def axis(self, filename):
        """One axis' scores, or None where this run has not been scored on it."""
        path = self.directory / filename
        return AxisScores(read_json(path)) if path.exists() else None

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
