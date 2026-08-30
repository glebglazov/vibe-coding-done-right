---
fragment: 5B1E4A73
generation: 0004
branch: master
---

+ In-Place Reachability
  The condition that a keyboard-driven start right now would record in place instead of bouncing the user into the app through the Deep-Link Fallback. It is what the Heartbeat's freshness predicate decides, and it is the single subject that every readiness surface renders — Mic Presence on the lock screen and the keyboard's own readiness indication must read the same predicate, so they can never disagree about whether the next tap will redirect.
  avoid: app liveness, warm mic, heartbeat freshness
  under: Keyboard And App Reachability

~ Heartbeat
  The app-alive signal written by the main app while the Hot Mic Session is alive. It asserts that the app process is reachable, not that the audio engine is currently warm — an interrupted engine is rebuilt on demand and still records in place. The keyboard uses the heartbeat to choose whether to attempt an in-place command; command acknowledgement is still required to prove the path is working right now.
  was: The app-alive signal written by the main app while the Hot Mic Session is alive and reachable. The keyboard uses the heartbeat to choose whether to attempt an in-place command; command acknowledgement is still required to prove the path is working right now.
  avoid: engine-warmth signal, liveness ping
  under: Keyboard And App Reachability

~ Mic Presence
  The user-visible indication that VCDR is responsible for the active microphone while the Hot Mic Session is warm and reachable for keyboard-driven recording. If Mic Presence says VCDR is ready, a keyboard start should be expected to record in place rather than require Deep-Link Fallback. Mic Presence is the lock-screen rendering of In-Place Reachability. It must never carry a readiness claim it cannot honor: when reachability lapses it renders as plainly not ready rather than persisting a readiness claim the app is no longer able to withdraw. It is not shown while the app is in the foreground, where the app itself is the answer. For a finite Hot-Session Timeout, Mic Presence should stop advertising readiness around the timeout deadline.
  was: The user-visible indication that VCDR is responsible for the active microphone while the Hot Mic Session is warm and reachable for keyboard-driven recording. If Mic Presence says VCDR is ready, a keyboard start should be expected to record in place rather than require Deep-Link Fallback. For a finite Hot-Session Timeout, Mic Presence should end around the timeout deadline rather than remain visible as a stale readiness signal.
  avoid: live activity implementation, orange-dot label, mic badge
  under: Keyboard And App Reachability
