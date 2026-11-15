---
fragment: F4F9F9AF
generation: 0018
branch: master
---

+ Conversation Status
  Where a Conversation is in its life: normal, or discarded. Every Conversation written before the status existed is normal. The status syncs with the Conversation, and processing a Discarded Conversation with AI makes it normal.
  avoid: state, flag, isDiscarded
  under: History

+ Discarded Conversation
  A Conversation made from a run the user discarded. It holds the verbatim on-device transcript (no Substitutions, no filler removal, no AI) and any captures, and no output. It stays in History, on every device, until the user deletes it or processes it with AI. Processing keeps its capture time and its place in the list.
  avoid: draft, trash, deleted entry, cancelled recording, pending entry
  under: History

+ Recorded Output Choice
  The output choices that were set when a run was discarded: the platform, the mode, the style, and the label to show. It is the default for a later "Process with AI". A device that cannot read a choice written by the other platform uses its own current choices.
  avoid: saved settings, mode snapshot, override
  under: History
