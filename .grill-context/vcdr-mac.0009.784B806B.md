---
fragment: 784B806B
generation: 0009
branch: master
---

+ Discard
  The user's intent, given with ⇧⎋ while a Capture Session records, to end it without output. The Capture Session goes idle at once, so the next one can start immediately. When the recording has speech, its verbatim transcript goes to History as a Discarded Conversation. ⇧⎋ during preparation keeps nothing. ⇧⎋ after recording ends (transcription, preview, execution) is a cancel, not a Discard.
  avoid: cancel, abort, throw away
  under: Capture Lifecycle

~ Conversation
  A history record for a Capture Session that reaches preview or execution, or for a discarded one that had speech. It stores input segments, optional externally processed output, and the Mode label. A Discarded Conversation has no output until the user processes it with AI.
  avoid: transcription record, capture log, history item
  was: A history record for a Capture Session that reaches preview or execution. It stores input segments, optional externally processed output, and the Mode label.
  under: History
