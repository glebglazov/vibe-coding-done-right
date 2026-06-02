# Blocking work stays off the cooperative thread pool

VCDR follows a responsiveness-first tenet (`docs/architecture/rules.md`, Rule 11): the foreground stays free and every heavy thing runs in the background. Deferring heavy *initialization* past the first frame is one instance of it (ADR-0002). This ADR records a second, subtler instance: **blocking synchronous syscalls must run on a GCD global queue, never on Swift's cooperative thread pool via `Task.detached`.**

## Context

Physical-device cold-launch traces showed the App Shell freezing ~15s during CoreML encoder ANE specialization and ~20s during `AVAudioEngine` input-node init — the main-actor init poll stalled and gestures timed out (`System gesture gate timed out`). Root cause: the blocking synchronous calls (`MLModel(contentsOf:)`, `inputNode.outputFormat(forBus:)`, `AVAudioSession.setActive`, `engine.start()`) were wrapped in `Task.detached`, which schedules onto the global *cooperative* executor (width ≈ core count). The runtime assumes tasks only *suspend* there; a call that *blocks* for seconds holds one of those scarce threads for its whole duration. Hold enough and no thread is left to service waiting actors — starving the main actor even though the work was nominally "off-main."

## Decision

Bridge blocking synchronous syscalls to a GCD global queue via `withBlockingTask` / `withThrowingBlockingTask` (`vcdr-ios/vcdr-ios/Concurrency/BlockingWork.swift`). GCD grows its pool for blocking work, so the cooperative pool and the main actor stay free. QoS is mapped from the caller's `TaskPriority` (automatic launch = `.utility`, a Recording Run = `.userInitiated`). First applied on iOS in commit `b3f9217`; macOS adopts the same pattern when it gains equivalent blocking calls. Rule 6 in `rules.md` is amended to carve this out from its "prefer Task over DispatchQueue" guidance.

## Considered options

- **`Task.detached`** (idiomatic Swift concurrency, what we had). Rejected: it runs on the cooperative pool; blocking it for seconds starves the runtime — the exact freeze observed.
- **Raising/lowering the detached task's priority.** Rejected: priority doesn't change *which* pool the work runs on. A blocked cooperative thread is blocked at any QoS.
- **A dedicated `DispatchQueue`/`Thread` per call site.** Rejected: more bookkeeping than needed. A global concurrent queue already spawns threads for blocking work; one small bridge helper covers every site.

## Consequences

- GCD in a Swift-concurrency-first codebase looks non-idiomatic and reads like a Rule 6 violation. Without this ADR and the Rule 6 carve-out, a reviewer or agent could "clean up" `withBlockingTask` back to `Task.detached` and silently reintroduce the freeze. Don't.
- The helper and the offenders are iOS-only today; the rule lives in the shared `rules.md` and applies to macOS the moment it has equivalent blocking calls.
- Non-`Sendable` config (e.g. `MLModelConfiguration`) must be rebuilt *inside* the `@Sendable` closure; pass value types (e.g. `MLComputeUnits`) across the boundary.
