---
fragment: A41C7E92
generation: 0001
branch: master
---

+ Processing Failure
  The Recording Run terminal state where the run ended without a transcript because something went wrong — the mic could not be seized, the transcription model failed to load, or finalization threw. A Processing Failure always carries a reason, and that reason is the user's to see: the keyboard surfaces a distinct failed state and the main app shows the full text. It is never collapsed into Empty Result.
  avoid: error state, no speech, failed transcription
  under: Recording And Delivery

~ Empty Result
  A completed recording that produced no usable speech, and nothing else. Empty Result means the pipeline ran to completion and the speech simply was not there; it is never a stand-in for cancellation or Processing Failure. The keyboard may surface it as a short no-speech state.
  was: A completed recording that produced no usable speech. Empty Result is distinct from cancellation and processing failure because the keyboard can surface it as a short no-speech state rather than a delivered transcript.
