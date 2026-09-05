#!/usr/bin/env python3
"""Show that the on-device arm asks Apple's model what the app asks it.

The model itself is the one thing here that cannot be exercised offline — it
needs Apple Intelligence switched on — so it is the only thing stood in for.
What these cases drive is the arm around it: the message it sends, the version
it records, and its refusal to spend a run on a model the device says is not
there.

Run: ./test_record_run.py
"""

import json
import subprocess
import sys
from contextlib import contextmanager

import record_run
from record_run import AFM_SHIM_SOURCE, AppleAFMArm, built_afm_shim, dictation_message
from test_runner import run_tests


class FakeShimCall:
    """The shim, answering from a script instead of from the device."""

    def __init__(self, availability="available", reply=None):
        self.availability = availability
        self.reply = reply if reply is not None else {"text": "Cleaned."}
        self.sent = None

    def __call__(self, argv, **keywords):
        if "--probe" in argv:
            stdout = json.dumps({"availability": self.availability})
        else:
            self.sent = json.loads(keywords["input"])
            stdout = json.dumps(self.reply)
        return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr="")


@contextmanager
def shimmed(shim):
    """The arm's one way out to the device, answered from the script instead."""
    replaced = record_run.subprocess.run
    record_run.subprocess.run = shim
    try:
        yield
    finally:
        record_run.subprocess.run = replaced


def arm_with(shim, model=AppleAFMArm.MODEL):
    with shimmed(shim):
        return AppleAFMArm(model, "/nonexistent/afm-shim")


def test_the_on_device_arm_sends_the_message_the_app_sends():
    """This arm exists to measure the provider the app falls back to. If it sent
    a bare transcript where the app sends a dictation message, its score would
    read as the model's when it was the harness'."""
    shim = FakeShimCall()
    arm = arm_with(shim)
    with shimmed(shim):
        answer = arm.complete("the prompt", arm.user_message("ship it tomorrow"))
    assert answer == "Cleaned.", answer
    assert shim.sent["user"] == dictation_message("ship it tomorrow"), shim.sent
    assert shim.sent["system"] == "the prompt", shim.sent


def test_the_on_device_arm_records_the_os_build_as_its_version():
    """Apple ships no id for this model, so two runs a system update apart would
    otherwise be indistinguishable in the ledger."""
    runtime = arm_with(FakeShimCall()).runtime()
    assert runtime.startswith("apple-foundation-models on macOS "), runtime
    assert "(" in runtime, runtime  # the build, not the marketing version alone


def test_a_switched_off_apple_intelligence_stops_the_run_before_it_starts():
    """Every case would fail with the same error, and a ledger run of identical
    failures is a worse report than refusing to record one."""
    try:
        arm_with(FakeShimCall(availability="unavailable: appleIntelligenceNotEnabled"))
    except SystemExit as refusal:
        assert "Apple Intelligence" in str(refusal), refusal
    else:
        raise AssertionError("a run was allowed against a model the device does not have")


def test_the_on_device_model_is_named_by_one_id_only():
    """The ledger compares arms by model name, so a second spelling of this one
    would read as a second model."""
    try:
        arm_with(FakeShimCall(), model="apple-intelligence")
    except SystemExit as refusal:
        assert AppleAFMArm.MODEL in str(refusal), refusal
    else:
        raise AssertionError("an invented model id was accepted")


def test_the_shim_the_arm_runs_is_built_from_the_source_in_the_tree():
    """A stale binary would answer the cases while the manifest named the commit
    of a source it was not built from."""
    binary = built_afm_shim()
    assert binary.exists(), binary
    assert binary.stat().st_mtime >= AFM_SHIM_SOURCE.stat().st_mtime, binary


if __name__ == "__main__":
    sys.exit(1 if run_tests(globals()) else 0)
