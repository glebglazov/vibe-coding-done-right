"""The Dictionary every arm shares, and the system prompt each arm sends.

An arm is a mode's system prompt plus one way of rendering the Dictionary after
it. `spellings` is the `<spelling_hints>` block `SpellingHints.appended(to:)`
builds today, byte for byte. `spellings_notes` is the same block with each
entry's note in parentheses after its spelling, the shape under consideration.
`spellings_notes_guarded` keeps those lines and swaps the intro for one that
says a note only picks between entries, so a note cannot make the model write,
sign with or address an entry the speaker did not say.
"""

import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
# The prompts the server hands every client; a client falls back to its bundled
# copy only when it has never reached the server.
SERVED_PROMPTS = REPO / "vcdr-server" / "prompts.go"

MODES = {"dictation": "dictation.json", "assistant": "assistant.json"}
# Why a sounds_alike case might tempt the model, so false insertions can be read per cause.
TRAPS = ("other_person", "self_name", "note_topic", "common_word", "topic_other_thing")

HINTS_PREAMBLE = (
    "The speaker often says these names, words and values. When the dictation "
    "contains something that sounds like one of them, write it with exactly this "
    "spelling. Never add one that the speaker did not say."
)
GUARDED_PREAMBLE = (
    "The speaker often says these names, words and values. When the dictation "
    "contains something that sounds like one of them, write it with exactly this "
    "spelling. Text in parentheses says what an entry is. Use it only to decide "
    "which entry the speaker meant, never as a reason to write an entry, sign a "
    "message or address someone. Never add one that the speaker did not say."
)
# Arm name -> (block intro, whether each line carries its note). `no_hints` sends no block.
HINT_ARMS = {
    "spellings": (HINTS_PREAMBLE, False),
    "spellings_notes": (HINTS_PREAMBLE, True),
    "spellings_notes_guarded": (GUARDED_PREAMBLE, True),
}
ARMS = ("no_hints", *HINT_ARMS)


def entries():
    return json.loads((HERE / "dictionary.json").read_text())["entries"]


def spellings():
    return [entry["spelling"] for entry in entries()]


def served_prompt(mode):
    source = SERVED_PROMPTS.read_text()
    return re.search(rf'"{mode}": `(.*?)`', source, re.S).group(1)


def hint_line(entry, with_notes):
    if with_notes and entry.get("note"):
        return f"- {entry['spelling']} ({entry['note']})"
    return f"- {entry['spelling']}"


def system_prompt(mode, arm):
    prompt = served_prompt(mode)
    if arm == "no_hints":
        return prompt
    preamble, with_notes = HINT_ARMS[arm]
    lines = "\n".join(hint_line(entry, with_notes) for entry in entries())
    section = f"<spelling_hints>\n{preamble}\n{lines}\n</spelling_hints>"
    return prompt + "\n\n" + section


def prompt_path(mode, arm):
    return HERE / "prompts" / f"{mode}_{arm}.txt"


def contains(text, spelling):
    """Exact spelling as a whole word: case, accents and joins all count."""
    return re.search(rf"(?<!\w){re.escape(spelling)}(?!\w)", text) is not None


def cases(mode):
    return json.loads((HERE / MODES[mode]).read_text())["evals"]
