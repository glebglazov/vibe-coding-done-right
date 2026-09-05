#!/usr/bin/env python3
"""Show that a Judge Score follows the rubric and stays on its own axis.

The judge model itself is the one boundary here that cannot be exercised
offline, so it is the only thing stood in for: these cases drive the rubric's
weights, the two parts of it that are arithmetic rather than judgement, and the
refusal to let a model grade its own arm.

Run: ./test_judge_run.py
"""

import json
import os
import sys
from pathlib import Path

import judge_run
from judge_run import MODES, ClaudeCliBackend, Judge, judge_run as judge_archived_run
from ledger import LEDGER, ArchivedRun
from test_runner import run_tests

HERE = Path(__file__).resolve().parent

def haiku_run():
    """The most recent Haiku run in the ledger that still answers the eval set as
    it stands.

    A run recorded before the set grew cannot be reopened for scoring — that is
    the ledger's own guard, and picking around it here keeps these cases about the
    judge rather than about which run happens to be oldest.
    """
    for directory in sorted(LEDGER.glob("*__claude-haiku-4-5-20251001__*"), reverse=True):
        try:
            return ArchivedRun(directory)
        except SystemExit:
            continue
    raise AssertionError("no Haiku run in the ledger answers the eval set as it stands")


RUN = haiku_run()

PERFECT = {
    "punctuation": 1,
    "voice": 1,
    "captures": 1,
    "content": 1,
    "format": 1,
    "notes": "matches",
}


class StubBackend:
    """The judge model, stood in for: the same reply to every case."""

    def __init__(self, reply, model="claude-opus-5"):
        self.model = model
        self.endpoint = "stub://messages"
        self.sampling = {"temperature": 0}
        self.reply = reply
        self.calls = 0

    def runtime(self):
        return "stub"

    def complete(self, system_prompt, user_message):
        self.calls += 1
        return self.reply


def judge_with(mode="anchored", **dimensions):
    return Judge(StubBackend(json.dumps({**PERFECT, **dimensions})), MODES[mode])


def case(case_id):
    return {
        case["id"]: case
        for case in json.loads((HERE / "evals.json").read_text())["evals"]
    }[case_id]


def test_overall_uses_the_rubrics_documented_weights():
    judge = judge_with()
    assert judge.weights == {
        "content": 0.30,
        "punctuation": 0.20,
        "voice": 0.20,
        "captures": 0.15,
        "format": 0.15,
    }, judge.weights
    dimensions, _ = judge.score(case("casual_voice_preserved"), "anything")
    assert judge.overall(dimensions) == 1.0, dimensions

    halved_voice = judge_with(voice=0.5)
    dimensions, _ = halved_voice.score(case("casual_voice_preserved"), "anything")
    assert halved_voice.overall(dimensions) == 0.9, dimensions


def test_a_blind_reading_shows_the_judge_no_reference():
    """The point of the blind mode: what the judge sees is the dictation and the
    output. A reference anywhere in it — the expected output, or the eval set's
    prose description of the transformation it wants — would make this a second
    look at the answer key rather than a second opinion."""
    subject = case("spoken_order_quantity")
    prompt = judge_with("blind").prompt_for(subject, "anything")
    assert subject["input"] in prompt and "anything" in prompt, prompt
    assert subject["expected_output"] not in prompt, prompt
    assert subject["exercises"] not in prompt, prompt
    assert "expected" not in prompt.lower(), prompt

    # And the rubric it applies scores against no reference either, so a deduction
    # cannot smuggle one back in.
    rubric = judge_with("blind").rubric
    assert not judge_run.REFERENCE_MENTION.search(rubric), rubric

    anchored = judge_with("anchored").prompt_for(subject, "anything")
    assert subject["expected_output"] in anchored, anchored


def test_a_judge_file_says_which_mode_read_it():
    """Two readings, two files, and each row saying which one it is: a blind score
    and an anchored score are different measurements, and one is never read as
    the other."""
    blind = judge_with("blind")
    scores = judge_archived_run(RUN, blind)
    assert scores["judge"]["mode"] == "blind", scores["judge"]
    assert all(score["judge_mode"] == "blind" for score in scores["cases"]), scores["cases"][0]
    assert blind.mode.filename != MODES["anchored"].filename, blind.mode.filename


def test_capture_tag_preservation_is_scored_binary():
    judge = judge_with(captures=0.8)
    dimensions, _ = judge.score(case("capture_with_code"), "anything")
    assert dimensions["captures"] == 0.0, dimensions


def test_a_case_without_capture_tags_scores_captures_by_definition():
    judge = judge_with(captures=0.4)
    dimensions, _ = judge.score(case("casual_voice_preserved"), "anything")
    assert dimensions["captures"] == 1.0, dimensions


def test_every_judged_case_carries_the_judge_that_produced_it():
    scores = judge_archived_run(RUN, judge_with())
    assert scores["judge"]["model"] == "claude-opus-5", scores["judge"]
    assert all(score["judge_model"] == "claude-opus-5" for score in scores["cases"])
    # The judge axis reports only itself: no deterministic number is read in, and
    # nothing here blends the two.
    assert "word_score_mean" not in scores and "metric" not in scores, sorted(scores)


def test_the_cli_judge_is_given_no_tool_that_could_reach_the_eval_set():
    """The CLI judge is an agent, and an agent that can open evals.json has seen
    the reference — which would make a blind reading an anchored one without
    anything in the file saying so. The ban belongs in the command, not in the
    caller who remembers to pass it."""
    backend = ClaudeCliBackend("claude-opus-5")
    argv = backend.argv("the rubric")
    assert argv[argv.index("--tools") + 1] == "", argv
    # And nothing of this project's own configuration reaches the judge either:
    # the rubric is the whole of what it was told.
    assert "--safe-mode" in argv and "--strict-mcp-config" in argv, argv
    assert argv[argv.index("--system-prompt") + 1] == "the rubric", argv
    # The rubric replaces the CLI's own prompt rather than riding on top of it.
    assert "--append-system-prompt" not in argv, argv


def test_the_cli_judge_does_not_carry_the_api_key_into_the_subscription():
    """Judging through the CLI is a decision to spend the subscription. The eval
    commands export a key into the shell for the arms, and the CLI would spend it
    where it found one, so it does not travel into the judge."""
    key = os.environ.get("ANTHROPIC_API_KEY")
    os.environ["ANTHROPIC_API_KEY"] = "sk-should-not-travel"
    try:
        environment = ClaudeCliBackend("claude-opus-5").environment()
    finally:
        os.environ.pop("ANTHROPIC_API_KEY", None)
        if key is not None:
            os.environ["ANTHROPIC_API_KEY"] = key
    assert "ANTHROPIC_API_KEY" not in environment, sorted(environment)
    assert "ANTHROPIC_AUTH_TOKEN" not in environment, sorted(environment)
    # The rest of the environment is left alone: PATH is how the CLI is found.
    assert environment.get("PATH") == os.environ.get("PATH"), environment.get("PATH")


def test_a_cli_reading_says_which_transport_took_it():
    """Only the API transport can pin sampling, so the same judge model read
    through the two is two measurements. The runtime is what tells them apart in
    the record, and no temperature is claimed that was never set."""
    backend = ClaudeCliBackend("claude-opus-5")
    assert backend.runtime().startswith("claude-code-cli "), backend.runtime()
    assert backend.sampling == {"temperature": None}, backend.sampling
    assert Judge(backend).identity()["runtime"] == backend.runtime()


def test_the_cli_judge_refuses_a_reply_from_a_model_it_did_not_ask_for():
    """A pinned judge that silently resolved elsewhere would break both things the
    pinning buys: that no model grades its own arm, and that two runs' scores mean
    the same thing."""
    backend = ClaudeCliBackend("claude-opus-5")
    answered = json.dumps({
        "subtype": "success",
        "is_error": False,
        "result": "{}",
        # A turn may touch a model of its own beside the one that answered.
        "modelUsage": {"claude-opus-5": {}, "claude-haiku-4-5-20251001": {}},
    })
    assert backend.reply(answered) == "{}", answered

    elsewhere = json.dumps({
        "subtype": "success", "is_error": False, "result": "{}",
        "modelUsage": {"claude-sonnet-5": {}},
    })
    try:
        backend.reply(elsewhere)
    except OSError as refusal:
        assert "claude-opus-5" in str(refusal), refusal
    else:
        raise AssertionError("a reply from an unasked model was accepted")


def test_a_model_may_not_grade_its_own_arm():
    argv = sys.argv
    sys.argv = [
        "judge_run.py", str(RUN.directory), "--judge-model", "claude-haiku-4-5-20251001"
    ]
    try:
        judge_run.main()
    except SystemExit as refusal:
        assert "must not grade its own arm" in str(refusal), refusal
    else:
        raise AssertionError("judging an arm with its own model was allowed")
    finally:
        sys.argv = argv


if __name__ == "__main__":
    sys.exit(1 if run_tests(globals()) else 0)
