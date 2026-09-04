#!/usr/bin/env python3
"""The Run Ledger — where an Eval Run is archived, and where it is read back from.

A run is scored long after the arm that produced it is gone, so everything needed
to judge one is read from here: the manifest, the eval set it was recorded
against, and the raw output of every case.
"""

import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
LEDGER = HERE / "ledger"


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


class ArchivedRun:
    """One recorded run, reopened for scoring.

    Loading verifies the eval set still fingerprints to what the run was recorded
    against — a reference output edited since then would silently change every
    score computed from it.
    """

    def __init__(self, directory):
        self.directory = Path(directory).resolve()
        self.manifest = json.loads((self.directory / "manifest.json").read_text())
        self.eval_set = self.manifest["eval_set"]

        eval_set_path = HERE / self.eval_set["name"]
        self.cases = json.loads(eval_set_path.read_text())["evals"]
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
