#!/usr/bin/env python3
"""Record Eval Runs of every arm over one mode's eval set into this directory's
Run Ledger, through the dictation harness's own `record()`.

Usage (from this directory):
  ANTHROPIC_API_KEY=op://Private/Anthropic/api_key \\
  GEMINI_API_KEY="op://Private/Gemini API Key/password" \\
    op-cache run -- ./record.py --mode dictation --provider anthropic \\
      --model claude-haiku-4-5-20251001 --repeats 3

Sampling is what the app sends, not the harness's pinned temperature 0: the
adapters send only an output-token cap, so the provider's default temperature
applies and repeats of one arm differ. That run-to-run spread is part of what
this eval reports.
"""

import argparse
import sys
from pathlib import Path

from dictionary import ARMS, HERE, MODES, prompt_path

sys.path.insert(0, str(HERE.parent / "dictation_prompts"))
import record_run  # noqa: E402

# The ledger and the eval sets of this question live here, apart from the
# dictation cleanup ledger whose rescoring tools expect its own sets.
record_run.HERE = HERE

# `defaultMaxTokens` in Shared/AI/AnthropicAdapter.swift and GeminiAdapter.swift.
APP_MAX_TOKENS = 1024
APP_SAMPLING = {
    "anthropic": {"max_tokens": APP_MAX_TOKENS},
    "gemini": {"maxOutputTokens": APP_MAX_TOKENS},
}


def app_arm(provider, model):
    arm = record_run.ARMS[provider](model, record_run.DEFAULT_ENDPOINTS[provider])
    arm.sampling = dict(APP_SAMPLING[provider])
    return arm


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=sorted(MODES), required=True)
    parser.add_argument("--provider", choices=sorted(APP_SAMPLING), required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--arm", choices=ARMS, action="append", help="default: every arm")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--ledger", default="ledger", help="Run Ledger directory under this one")
    arguments = parser.parse_args()
    record_run.LEDGER = HERE / arguments.ledger

    failures = 0
    for _ in range(arguments.repeats):
        for arm_name in arguments.arm or ARMS:
            failures += record_run.record(
                app_arm(arguments.provider, arguments.model),
                prompt_path(arguments.mode, arm_name),
                HERE / MODES[arguments.mode],
            )
    return failures


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
