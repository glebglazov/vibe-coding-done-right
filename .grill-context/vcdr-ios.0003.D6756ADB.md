---
fragment: D6756ADB
generation: 0003
branch: master
---

+ Arming Deadline
  The limit on how long Arming may last before the Recording Run is declared a Processing Failure — five seconds, measured to the first audio buffer rather than to the audio engine reporting that it started. It exists because a run that never captures anything must say so instead of presenting a live-looking recording surface over a dead microphone.
  avoid: arming timeout, startup watchdog, capture deadline
  under: Recording And Delivery

~ Processing Failure
  The Recording Run terminal state where the run ended without a transcript because something went wrong — the mic could not be seized, Arming passed the Arming Deadline without a first audio buffer, the transcription model failed to load, or finalization threw. A Processing Failure always carries a reason, and that reason is the user's to see: the keyboard surfaces a distinct failed state and the main app shows the full text. It is never collapsed into Empty Result.
  was: The Recording Run terminal state where the run ended without a transcript because something went wrong — the mic could not be seized, the transcription model failed to load, or finalization threw. A Processing Failure always carries a reason, and that reason is the user's to see: the keyboard surfaces a distinct failed state and the main app shows the full text. It is never collapsed into Empty Result.
  avoid: error state, no speech, failed transcription
  under: Recording And Delivery
