---
fragment: C4FCBCBA
generation: 0001
branch: master
---

+ Diagnostics Surface
  A view that renders material the app has already recorded — the log buffer, launch telemetry — and changes nothing about how the app behaves. Being read-only is what makes a Diagnostics Surface safe to compile into a Release build; anything that alters behavior is a Debug tool and stays compiled out.
  avoid: debug view, debug menu, developer mode
  under: Diagnostics

+ Diagnostics Unlock
  The per-device, persistent state in which the Diagnostics Surfaces are visible. It is entered by a deliberate repeated tap on the Version Row, is never entered by accident, and stays entered until the user locks it again, so reaching the logs later costs no gesture. A Debug build is always unlocked.
  avoid: debug flag, developer mode, unlock code
  under: Diagnostics

+ Version Row
  The row in each app that names the running build — marketing version and build number — and doubles as the affordance that performs the Diagnostics Unlock. It exists so a log can be read against the build that wrote it.
  avoid: about box, build stamp, easter egg
  under: Diagnostics

+ Debug vs Diagnostics
  "Debug" means compiled out of Release: `#if DEBUG` tools that change how the app behaves, such as test-audio injection and the test runner. "Diagnostics" means present in every build and merely hidden: read-only surfaces revealed by the Diagnostics Unlock. A capability that ships to TestFlight is never called Debug.
  under: Flagged Ambiguities
