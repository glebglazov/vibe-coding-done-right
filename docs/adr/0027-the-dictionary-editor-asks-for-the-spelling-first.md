# The Dictionary editor asks for the Spelling first

Accepted. Amends [ADR-0014](0014-a-substitution-is-named-by-its-replacement-and-read-triggers-first.md).

ADR-0014 put the Trigger Phrases first in the editor, and added a blank Trigger Phrase row with the caret in it on every open. That order assumed that every entry had a Trigger Phrase. [ADR-0025](0025-the-dictionary-holds-spelling-hints-beside-substitutions.md) made Trigger Phrases optional, so every entry is a Spelling Hint first. An editor that leads with Triggers hides this. A user who wants the app to spell their own name cannot see that a spelling and a Note are enough.

Thus the editor on both platforms now asks in this order:

1. The Spelling. This is the Replacement field. The screen calls it "Spelling".
2. The Note.
3. The Trigger Phrases, which are optional. The "Add Trigger" button stays. A footer tells when to add a Trigger, how Triggers match, and which Transcription Models ignore Spelling Hints. With such a model, a mode that does not use AI can change a word only through a Trigger.
4. The Enabled toggle.

The editor does not add a blank Trigger Phrase row when it opens. When the Replacement is empty, which is true for a new entry, the caret goes to the Spelling field. In all other cases the editor sets no focus.

Naming does not change. The Replacement still names the entry, and the list row still reads Trigger Phrases, an arrow, then the Replacement. Only the editor order changes.

## Considered options

- **A stored mode picker, "Trigger" or "Hint".** Rejected. The modes are not exclusive: every entry is a Spelling Hint, and Trigger Phrases add an exact swap on top. A stored mode can also contradict the Trigger Phrase list, for example a "Hint" entry that has Trigger Phrases. And Substitution Convergence would have to merge one more field. The editor gets the mode from the live Trigger Phrases instead.
- **Keep the Triggers first and only add a footer.** Rejected. The first field still says that an entry starts with a Trigger, and the blank row still asks for one on every open.

## Consequences

- To file a new mishearing on an existing entry, the user now clicks "Add Trigger" first. ADR-0014 made that row appear without a click.
- The blank row guard from ADR-0014 stays. "Add Trigger" still adds a blank row, and a blank row must not reach the store.
- The iOS list no longer shows the matching rules as its footer. They are now in the Triggers footer of the editor, on both platforms. Before this, macOS did not show them at all.
- The footer gets the names of the models that ignore Spelling Hints from each model family's declared Capabilities. When Parakeet declares the Capability, its name goes out of the footer with no change to the copy.
