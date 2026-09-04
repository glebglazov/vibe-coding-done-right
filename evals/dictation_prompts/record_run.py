#!/usr/bin/env python3
"""Record one Eval Run — one Eval Arm over one Eval Set — into the Run Ledger.

Usage:
  export ANTHROPIC_API_KEY=$(op-cache read "op://Private/Anthropic/api_key")
  ./record_run.py --model claude-haiku-4-5-20251001 --prompt prompts/prompt_lean.txt
  ./record_run.py --provider openai-chat --model gemma4:e4b --prompt prompts/prompt_lean.txt

Every run lands in ledger/<run-id>/ as a manifest plus one file per case holding
the model's output byte-for-byte, so the run can be rescored forever without
spending on models again.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from ledger import HERE, LEDGER, case_fingerprint, eval_set_fingerprint, sha256_hex

ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages"
OPENAI_CHAT_ENDPOINT = "http://127.0.0.1:11434/v1/chat/completions"

MAX_TOKENS = 2048
# A local runtime defaults to temperature 1, so a reproducible run has to pin
# sampling rather than inherit it.
TEMPERATURE = 0
SEED = 0

REQUEST_TIMEOUT_S = 300

# A cloud endpoint sheds load mid-run, and one such refusal would otherwise leave
# a permanent hole in an archived run that costs a whole re-run to fill.
TRANSIENT_STATUSES = (429, 500, 502, 503, 529)
RETRIES = 4
RETRY_BACKOFF_S = 5


def post_json(url, headers, body):
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"content-type": "application/json", **headers},
        method="POST",
    )
    for attempt in range(RETRIES):
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_S) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as refusal:
            if refusal.code not in TRANSIENT_STATUSES or attempt == RETRIES - 1:
                raise
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            if attempt == RETRIES - 1:
                raise
        time.sleep(RETRY_BACKOFF_S * 2**attempt)


def get_json(url, timeout_s=5):
    with urllib.request.urlopen(url, timeout=timeout_s) as response:
        return json.loads(response.read().decode("utf-8"))


class AnthropicArm:
    """The cloud backend: the Anthropic messages API, called as the app calls it."""

    def __init__(self, model, endpoint):
        self.model = model
        self.endpoint = endpoint
        self.sampling = {"temperature": TEMPERATURE, "max_tokens": MAX_TOKENS}
        self.api_key = os.environ.get("ANTHROPIC_API_KEY", "")
        if not self.api_key:
            raise SystemExit(
                'ANTHROPIC_API_KEY not set. Run: export ANTHROPIC_API_KEY=$(op-cache read "op://Private/Anthropic/api_key")'
            )

    def runtime(self):
        return "anthropic-messages-api 2023-06-01"

    def complete(self, system_prompt, user_message):
        try:
            payload = self.messages(system_prompt, user_message)
        except urllib.error.HTTPError as refusal:
            if not self.drop_deprecated_temperature(refusal):
                raise
            payload = self.messages(system_prompt, user_message)
        # A reasoning model answers with thinking blocks ahead of its text, so the
        # reply is the text blocks rather than whatever block came first.
        return "".join(
            block["text"] for block in payload["content"] if block["type"] == "text"
        )

    def messages(self, system_prompt, user_message):
        return post_json(
            self.endpoint,
            {"x-api-key": self.api_key, "anthropic-version": "2023-06-01"},
            {
                "model": self.model,
                "system": system_prompt,
                "messages": [{"role": "user", "content": user_message}],
                **self.sampling,
            },
        )

    def drop_deprecated_temperature(self, refusal):
        """Newer models reject `temperature` outright, so pinning it is impossible.

        Sampling is pinned wherever the model still accepts it; where the API
        refuses, the manifest records what was actually sent rather than a
        temperature the run never had.
        """
        if refusal.code != 400 or "temperature" not in self.sampling:
            return False
        if "`temperature` is deprecated" not in refusal.read().decode("utf-8", "replace"):
            return False
        del self.sampling["temperature"]
        return True


class OpenAIChatArm:
    """The local backend: an OpenAI-compatible chat-completions endpoint."""

    def __init__(self, model, endpoint):
        self.model = model
        self.endpoint = endpoint
        self.sampling = {
            "temperature": TEMPERATURE,
            "seed": SEED,
            "max_tokens": MAX_TOKENS,
        }

    def runtime(self):
        """Ask the server what it is, so the manifest names what actually served the run."""
        origin = self.endpoint.split("/v1/")[0]
        try:
            return f"ollama {get_json(f'{origin}/api/version')['version']}"
        except (urllib.error.URLError, KeyError, ValueError, OSError):
            return f"openai-compatible endpoint at {origin}"

    def complete(self, system_prompt, user_message):
        payload = post_json(
            self.endpoint,
            {},
            {
                "model": self.model,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_message},
                ],
                "stream": False,
                **self.sampling,
                # Ollama reads sampling from `options`; the top-level keys above are
                # what every other OpenAI-compatible server reads. Pin it in both.
                "options": self.sampling,
            },
        )
        return payload["choices"][0]["message"]["content"]


ARMS = {"anthropic": AnthropicArm, "openai-chat": OpenAIChatArm}
DEFAULT_ENDPOINTS = {
    "anthropic": ANTHROPIC_ENDPOINT,
    "openai-chat": OPENAI_CHAT_ENDPOINT,
}


def user_message(case_input):
    """The shape the app sends, so an arm measures what ships."""
    return f"<dictation>{case_input}</dictation>"


def repo_commit():
    return subprocess.run(
        ["git", "-C", str(HERE), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


def run_id(eval_set_name, model, prompt_name, recorded_at):
    stamp = recorded_at.strftime("%Y%m%dT%H%M%SZ")
    slug = model.replace("/", "-").replace(":", "-")
    return f"{stamp}__{Path(eval_set_name).stem}__{slug}__{prompt_name}"


def record(arm, prompt_path, eval_set_path):
    # A manifest names its set by filename, so a set living anywhere else would
    # archive a run nothing could rescore from a fresh checkout.
    if eval_set_path.parent != HERE:
        sys.exit(
            f"eval set must sit beside the ledger commands ({HERE}): {eval_set_path}"
        )
    cases = json.loads(eval_set_path.read_text())["evals"]
    system_prompt = prompt_path.read_text()
    recorded_at = datetime.now(timezone.utc)

    directory = LEDGER / run_id(
        eval_set_path.name, arm.model, prompt_path.stem, recorded_at
    )
    outputs = directory / "outputs"
    outputs.mkdir(parents=True, exist_ok=True)

    print(
        f"{len(cases)} cases | model: {arm.model} | prompt: {prompt_path.stem} "
        f"| set: {eval_set_path.name}\n---"
    )

    recorded_cases = []
    failures = 0
    for index, case in enumerate(cases, start=1):
        print(f"  [{index:2d}/{len(cases)}] {case['id']:<40}", end="", flush=True)
        started = time.monotonic()
        try:
            output = arm.complete(system_prompt, user_message(case["input"]))
            error = None
        except (urllib.error.URLError, OSError, KeyError, ValueError) as failure:
            output, error = None, f"{type(failure).__name__}: {failure}"
        latency_ms = round((time.monotonic() - started) * 1000)

        entry = {
            "id": case["id"],
            "category": case["category"],
            "case_fingerprint": case_fingerprint(case),
            "latency_ms": latency_ms,
        }
        if error is None:
            (outputs / f"{case['id']}.txt").write_text(output)
            entry["output_file"] = f"outputs/{case['id']}.txt"
            print(f"OK   {latency_ms / 1000:5.1f}s")
        else:
            entry["error"] = error
            failures += 1
            print(f"FAIL {error}")
        recorded_cases.append(entry)

    manifest = {
        "run_id": directory.name,
        "recorded_at": recorded_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repo_commit": repo_commit(),
        "arm": {
            "model": arm.model,
            "endpoint": arm.endpoint,
            "runtime": arm.runtime(),
            "prompt_name": prompt_path.stem,
            "prompt_sha256": sha256_hex(system_prompt),
            "sampling": arm.sampling,
        },
        "eval_set": {
            "name": eval_set_path.name,
            "fingerprint": eval_set_fingerprint(cases),
            "case_count": len(cases),
        },
        "cases": recorded_cases,
    }
    (directory / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    )

    print(f"---\nRecorded: {directory}")
    if failures:
        print(f"{failures} of {len(cases)} cases failed", file=sys.stderr)
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help="model id the arm runs")
    parser.add_argument(
        "--prompt", required=True, help="system prompt file the arm runs"
    )
    parser.add_argument(
        "--eval-set",
        default=str(HERE / "evals.json"),
        help="eval set JSON to run over (default: evals.json)",
    )
    parser.add_argument(
        "--provider",
        choices=sorted(ARMS),
        default="anthropic",
        help="backend serving the arm (default: anthropic)",
    )
    parser.add_argument(
        "--endpoint", help="override the provider's default endpoint URL"
    )
    arguments = parser.parse_args()

    arm = ARMS[arguments.provider](
        arguments.model,
        arguments.endpoint or DEFAULT_ENDPOINTS[arguments.provider],
    )
    return record(
        arm,
        Path(arguments.prompt).resolve(),
        Path(arguments.eval_set).resolve(),
    )


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
