#!/usr/bin/env python3
"""Run one test file's own test functions.

Each test file here is an executable script of its own — `./test_score_run.py` —
and what they share is this: every `test_` function in the file, in name order,
with a failed assertion reported and counted rather than stopping the file.
"""


def run_tests(namespace):
    """Every test function in a test file's namespace, and how many failed."""
    failures = 0
    for name, test in sorted(namespace.items()):
        if not name.startswith("test_"):
            continue
        try:
            test()
            print(f"PASS {name}")
        except AssertionError as failure:
            failures += 1
            print(f"FAIL {name}: {failure}")
    return failures
