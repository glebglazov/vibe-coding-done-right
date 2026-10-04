#!/usr/bin/env python3
"""Write one system prompt file per mode and arm, and refuse an eval set whose
cases cannot measure what they claim.

A misheard case whose input already holds the Dictionary spelling would score a
hit with no correction at all, and a sounds_alike case whose input holds one
would score an insertion the model did not make.
"""

import sys

from dictionary import ARMS, MODES, TRAPS, cases, contains, prompt_path, spellings, system_prompt


def broken_cases():
    for mode in MODES:
        for case in cases(mode):
            present = [s for s in spellings() if contains(case["input"], s)]
            if present:
                yield f"{mode}/{case['id']}: input already holds {present}"
            if case["category"] == "misheard" and case["expected_output"] not in spellings():
                yield f"{mode}/{case['id']}: {case['expected_output']!r} is not a Dictionary spelling"
            if case["category"] == "sounds_alike" and case.get("trap") not in TRAPS:
                yield f"{mode}/{case['id']}: trap {case.get('trap')!r} is not one of {TRAPS}"


def main():
    problems = list(broken_cases())
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    for mode in MODES:
        for arm in ARMS:
            path = prompt_path(mode, arm)
            path.write_text(system_prompt(mode, arm))
            print(f"wrote {path.relative_to(path.parent.parent)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
