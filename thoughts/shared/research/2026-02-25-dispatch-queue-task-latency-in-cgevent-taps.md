---
date: 2026-02-25T23:24:10+0100
researcher: Claude
git_commit: 730ac7ea714758974e13c9fd966456c84cd46f73
branch: main
repository: vibe-coding-done-right
topic: "Why DispatchQueue.main.async and Task { @MainActor } add latency when called from CGEvent tap callbacks"
tags: [research, codebase, cfrunloop, gcd, swift-concurrency, cgevent-tap, mainactor, threading]
status: complete
last_updated: 2026-02-25
last_updated_by: Claude
---

# Research: Why DispatchQueue.main.async and Task Scheduling Cause Latency from CGEvent Taps

**Date**: 2026-02-25T23:24:10+0100
**Researcher**: Claude
**Git Commit**: `730ac7ea714758974e13c9fd966456c84cd46f73`
**Branch**: main
**Repository**: vibe-coding-done-right

## Research Question

Why do `DispatchQueue.main.async` and `Task { @MainActor in }` add latency when called from CGEvent tap callbacks? Explain in deep detail using the toggle recording hotkey race condition fix as a concrete example.

## Summary

The macOS main thread has **three layered scheduling systems** sharing one physical thread. They do NOT execute work in a unified queue — they fire during different phases of a single CFRunLoop iteration. A CGEvent tap callback runs as a **Source1 (kernel-driven mach port)** at the very bottom of the run loop stack. When it dispatches work via `DispatchQueue.main.async`, that work is enqueued on a *different* mach port and cannot execute until the next run loop iteration. Wrapping that in `Task { @MainActor in }` adds yet another iteration. The result: **minimum 2 full run loop iterations** of latency between the key event and the actual Swift code executing — and under load, potentially much more.

## The Three Layers

### Layer 1: CFRunLoop (lowest level)

The main thread's heartbeat. Analogous to a browser's event loop. The thread sleeps in `mach_msg()` when idle and is woken by kernel mach port messages.

**One CFRunLoop iteration (canonical order from CFRunLoop.c source):**

```
 1.  Observer: kCFRunLoopBeforeTimers
 2.  Observer: kCFRunLoopBeforeSources
 3.  __CFRunLoopDoBlocks()              ← CFRunLoopPerformBlock blocks
 4.  __CFRunLoopDoSources0()            ← Source0: manually-signaled sources
 5.  __CFRunLoopDoBlocks()              ← blocks again if Source0 fired
 6.  __CFRunLoopServiceMachPort(nowait) ← PEEK at Source1 ports — non-blocking
     (if a Source1 port was already ready, jump to step 10)
 7.  Observer: kCFRunLoopBeforeWaiting  ← SwiftUI/CoreAnimation render commit HERE
 8.  mach_msg_trap()                    ← SLEEP: wait for timer / GCD port / Source1
 9.  Observer: kCFRunLoopAfterWaiting
10.  Determine what woke us:
     a. Timer port fired     → __CFRunLoopDoTimers()
     b. GCD main queue port  → __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__()
     c. Other mach port      → __CFRunLoopDoSource1()    ← CGEvent tap fires HERE
11.  __CFRunLoopDoBlocks()
12.  Check exit conditions → loop back to 2
```

**Key insight:** Each wakeup from `mach_msg_trap()` services **one cause**. If a Source1 mach port (CGEvent tap) woke the thread, only step 10c runs. The GCD main queue port (10b) is not serviced in the same pass.

### Layer 2: GCD DispatchQueue.main

GCD hooks into CFRunLoop via a dedicated mach port (`dispatchPort`). When you call `DispatchQueue.main.async { ... }`, libdispatch sends a mach message to this port. The block executes at step 10b of a *future* run loop iteration — when the GCD port wins the `mach_msg_trap()` wakeup.

`DispatchQueue.main.async` is semantically equivalent to `setTimeout(fn, 0)` in JavaScript — it runs "soon" but never in the current execution context.

### Layer 3: Swift Concurrency @MainActor

The `MainActor` executor is implemented **on top of** `DispatchQueue.main`. When you write `Task { @MainActor in ... }`:

1. A new `Job` object is created for the task's initial continuation.
2. `_enqueueOnMain(job)` is called in the Swift runtime's C++ layer.
3. This calls `dispatch_async_swift_job(dispatch_get_main_queue(), job)` — a private libdispatch entry point.
4. The job lands in the GCD main queue's internal structures.
5. It drains at step 10b when the GCD port wakes the run loop.

**MainActor and DispatchQueue.main share the same underlying GCD serial queue.** They use different submission APIs (`dispatch_async_swift_job` vs `dispatch_async_f`) but drain from the same queue.

**Critical rule:** `Task.init` is always an enqueue, never an inline call. Even from code already on the main thread, the task body executes on a *future* run loop iteration. The "hop_to_executor" optimization (skipping suspension when already on the correct executor) only applies to `await` of an `@MainActor` async function from within an already-MainActor async context. It does not apply to `Task { }` creation.

## The Bug: Concrete Execution Trace

### Before the fix (the broken pattern)

The toggle recording hotkey's `onKeyDown` was dispatched via `DispatchQueue.main.async` (in `GlobalHotkeyManager.handleEvent`), then the closure created `Task { @MainActor in self?.toggleRecording() }`:

```
CGEvent tap callback fires (Source1, step 10c of run loop)
  ├─ handleEvent() runs synchronously
  ├─ DispatchQueue.main.async { onKeyDown?() } ← enqueues on GCD port
  └─ returns to run loop

─── RUN LOOP ITERATION N+1 ───
Step 10b: GCD port fires → __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__
  ├─ onKeyDown() closure runs
  ├─ Task { @MainActor in toggleRecording() } ← enqueues ANOTHER job on GCD port
  └─ returns

─── RUN LOOP ITERATION N+2 ───
Step 10b: GCD port fires again
  ├─ toggleRecording() finally runs
  ├─ state is .idle → Task { await onHotkeyDown() } ← ANOTHER enqueue
  └─ returns

─── RUN LOOP ITERATION N+3 ───
Step 10b: GCD port fires
  ├─ onHotkeyDown() starts
  ├─ await transcriptionProvider.isReady ← suspends, hops to ParakeetProvider actor
  └─ MainActor freed

─── RUN LOOP ITERATION N+4 (or later) ───
  ├─ onHotkeyDown() resumes
  ├─ await audioRecorder.startRecording() ← suspends again
  └─ MainActor freed

─── RUN LOOP ITERATION N+5 (or later) ───
  ├─ state = .recording                  ← FINALLY set here
  └─ ...
```

**The problem:** From keyDown to `state = .recording`, there are minimum 5 run loop iterations plus 2 actor-crossing suspensions. During iterations N+1 through N+4, the state remains `.idle`.

Now the user presses the key again to stop. The same chain fires:

```
CGEvent tap callback fires (Source1)
  └─ DispatchQueue.main.async { onKeyDown?() }

─── NEXT ITERATION ───
  └─ Task { @MainActor in toggleRecording() }

─── NEXT ITERATION ───
  └─ toggleRecording() runs, checks state...
     state is STILL .idle (onHotkeyDown hasn't finished yet!)
     → goes into .idle case → starts ANOTHER recording attempt
```

Every rapid press of the toggle key sees `.idle` and tries to start, because the async chain from the first press hasn't completed. None of the presses ever sees `.recording` state and calls `stopRecordingAndTranscribe()`.

### Why PTT (push-to-talk) didn't have this problem

PTT's `onKeyUp` was already synchronous:

```swift
// Called directly from CGEvent tap callback — zero hops
hotkeyManager.onKeyUp = { [weak self] in
    self?.stopRecordingAndTranscribe()
}
```

```
CGEvent tap callback fires (Source1, step 10c)
  └─ self.onKeyUp?()
       └─ stopRecordingAndTranscribe() runs INLINE
            └─ state = .transcribing immediately
            └─ audioRecorder.stop() immediately
  └─ returns to run loop
```

Zero dispatch hops. The state change and audio stop happen during the same Source1 service call. This was specifically fixed in commit `7997b00` after observing 2-10+ second delays when onKeyUp went through `DispatchQueue.main.async`.

### After the fix (the current pattern)

Two changes eliminate the dispatch hops:

**1. `GlobalHotkeyManager.handleEvent` now calls `onKeyDown` synchronously:**

```swift
// BEFORE (broken):
DispatchQueue.main.async { self.onKeyDown?() }

// AFTER (fixed):
self.onKeyDown?()
```

The CGEvent tap callback already runs on the main thread (it's a Source1 on the main run loop). `DispatchQueue.main.async` was unnecessary — it just added a full run loop iteration of latency for no benefit.

**2. Toggle recording hotkey calls `toggleRecording()` directly:**

```swift
// BEFORE (broken):
toggleRecordingHotkeyManager.onKeyDown = { [weak self] in
    Task { @MainActor in self?.toggleRecording() }
}

// AFTER (fixed):
toggleRecordingHotkeyManager.onKeyDown = { [weak self] in
    self?.toggleRecording()
}
```

Now the execution trace for "press to stop" is:

```
CGEvent tap callback fires (Source1, step 10c)
  └─ onKeyDown?() called synchronously
       └─ toggleRecording() called synchronously
            └─ state == .recording → stopRecordingAndTranscribe()
                 └─ state = .transcribing immediately
                 └─ audioRecorder.stop() immediately
  └─ returns to run loop
```

Zero hops. Identical latency profile to PTT's onKeyUp.

### The `isPreparingToRecord` guard

Even with synchronous dispatch, the *start* path is inherently async (`onHotkeyDown` must `await` transcription provider readiness and audio recorder start). So `toggleRecording()` still creates a Task for the start case:

```swift
case .idle, .error:
    isToggleMode = true
    Task { await onHotkeyDown() }
```

This Task goes through the GCD main queue (1 hop minimum). During the async gap between `state == .idle` and `state = .recording`, rapid presses could create multiple concurrent `onHotkeyDown()` Tasks — all of which see `.idle` and race.

The `isPreparingToRecord` flag is set synchronously at the top of `onHotkeyDown()` (before any `await`) and cleared via `defer`. Because it's set on the MainActor before the first suspension point, no other MainActor task can read it between the set and the first await — Swift's cooperative executor guarantees no interleaving within a single synchronous section.

## Why Can the MainActor Executor Stall for Seconds?

The main thread must return to the run loop for GCD main queue draining. Anything holding the main thread prevents all queued `DispatchQueue.main.async` blocks and all pending MainActor task continuations from executing:

- **SwiftUI view body evaluation** at `kCFRunLoopBeforeWaiting` (step 7) — complex view hierarchies take time
- **`@Observable` tracking overhead** — the 20Hz audio level timer (`AudioRecorder.swift:153`) fires `Timer.scheduledTimer(withTimeInterval: 0.05)`, each fire mutates `audioLevel`, invalidating SwiftUI views
- **CoreAnimation commit** at `kCFRunLoopBeforeWaiting` — GPU work is async but setup is main-thread
- **Any synchronous AppKit/Cocoa callback** — delegate methods, notification handlers

Note: CoreML inference in this codebase does NOT stall the MainActor. `ParakeetProvider` is an `actor` (not `@MainActor`), so its `transcribe()` method runs on a background cooperative thread. The `RecordingCoordinator` suspends and releases the MainActor at `await transcriptionProvider.transcribe(...)`.

## Component Threading Summary

| Component | Isolation | Runs On | Key Property |
|---|---|---|---|
| CGEvent tap callback | None (Source1) | Main run loop directly | Fires even when MainActor stalled |
| `DispatchQueue.main.async` | GCD main queue | Step 10b of run loop | Deferred ≥1 iteration |
| `Task { @MainActor in }` | MainActor executor | Step 10b via GCD port | Deferred ≥1 iteration from creation |
| `AudioRecorder.stopRecording()` | None | Caller's thread | Fully synchronous |
| `AudioRecorder.startRecording()` | None (async) | Caller's actor | Suspends at mic permission |
| `ParakeetProvider` | `actor` (own executor) | Background cooperative pool | Never holds MainActor |
| SwiftUI rendering | BeforeWaiting observer | Main thread, step 7 | Blocks GCD drain while running |

## Code References

- `vcdr/Hotkeys/GlobalHotkeyManager.swift:57-58` — CGEvent tap CFMachPort registered on main run loop with `.commonModes`
- `vcdr/Hotkeys/GlobalHotkeyManager.swift:94-101` — keyDown handler: synchronous `self.onKeyDown?()` call
- `vcdr/Hotkeys/GlobalHotkeyManager.swift:110-117` — keyUp handler: synchronous `self.onKeyUp?()` call
- `vcdr/Orchestration/RecordingCoordinator.swift:68-73` — PTT onKeyDown: `Task { @MainActor in }` (async start, acceptable)
- `vcdr/Orchestration/RecordingCoordinator.swift:78-79` — PTT onKeyUp: synchronous `stopRecordingAndTranscribe()`
- `vcdr/Orchestration/RecordingCoordinator.swift:292-293` — Toggle onKeyDown: direct `self?.toggleRecording()` (synchronous stop)
- `vcdr/Orchestration/RecordingCoordinator.swift:109` — `isPreparingToRecord` guard in `onHotkeyDown`
- `vcdr/Orchestration/RecordingCoordinator.swift:117-118` — flag set + defer reset
- `vcdr/Transcription/ParakeetProvider.swift:5` — `actor` declaration (not `@MainActor`)
- `vcdr/Audio/AudioRecorder.swift:50` — `startRecording` is `async`, no actor annotation
- `vcdr/Audio/AudioRecorder.swift:95` — `stopRecording` is fully synchronous

## Historical Context (from thoughts/)

- `thoughts/shared/research/2026-02-21-macos-run-loops-and-threading-model.md` — Comprehensive documentation of CFRunLoop phases, Source0 vs Source1 types, GCD integration, and why `onKeyUp` was made synchronous. Established that MainActor stalls of 2-10+ seconds were observed but root cause not definitively identified.
- `thoughts/shared/handoffs/2026-02-21_12-30-44_fix-ptt-keyup-race-condition.md` — Documents the original PTT keyUp fix where `DispatchQueue.main.async { self.onKeyUp?() }` was changed to `self.onKeyUp?()`. Three fix iterations were needed before the real cause was found. Debug logging with timestamps revealed the true 10-second gap between `continuation.resume()` and Task execution.

## Key Takeaways

1. **CFRunLoop Source1 callbacks are the only guaranteed-prompt execution context** on the main thread. Everything else (`DispatchQueue.main.async`, `Task { @MainActor }`, `CFRunLoopPerformBlock`) is deferred to a future run loop iteration.

2. **`DispatchQueue.main.async { Task { @MainActor in } }` is a double-hop** through the GCD main queue — minimum 2 full run loop iterations of latency.

3. **The CGEvent tap callback runs on the main thread** (it's a Source1 on the main run loop). Dispatching synchronous work via GCD from within it adds latency for zero benefit.

4. **Swift `Task.init` is always an enqueue, never inline.** Even from the main thread. The "already on correct executor" optimization only applies to `await` of actor-isolated async functions, not to `Task { }` creation.

5. **State checks across async boundaries race.** When `toggleRecording()` checks `state == .idle` and then creates `Task { await onHotkeyDown() }`, the state isn't updated until deep inside the async chain. Multiple callers can pass the `.idle` check before any of them sets `.recording`.

## Open Questions

- **Root cause of MainActor executor stalls** reaching 2-10+ seconds is still undiagnosed. Instruments profiling would be needed to determine whether it's SwiftUI view evaluation, `@Observable` tracking from the 20Hz audio timer, CoreAnimation commits, or something else entirely.
