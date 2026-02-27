---
date: 2026-02-21T12:38:19+0100
researcher: claude
git_commit: 7997b00460d40e924eae7bc58c4095d42f5fc509
branch: main
repository: vibe-coding-done-right
topic: "macOS Run Loops, GCD, Swift Concurrency, and How They Interact"
tags: [research, codebase, run-loop, CFRunLoop, GCD, MainActor, CGEventTap, SwiftUI, concurrency]
status: complete
last_updated: 2026-02-21
last_updated_by: claude
---

# Research: macOS Run Loops, GCD, Swift Concurrency, and How They Interact

**Date**: 2026-02-21T12:38:19+0100
**Researcher**: claude
**Git Commit**: 7997b00460d40e924eae7bc58c4095d42f5fc509
**Branch**: main
**Repository**: vibe-coding-done-right

## Research Question

Explain macOS application run loops and how they interact with each other — CFRunLoop, GCD (DispatchQueue.main), Swift Concurrency (@MainActor), CGEvent taps, and SwiftUI rendering — in the context of the PTT hotkey race condition fix. Explain for someone coming from a React/JavaScript background.

## Summary

The macOS main thread has **three layered scheduling systems** stacked on top of each other, all sharing the same physical thread:

1. **CFRunLoop** — the lowest level, analogous to the browser's event loop
2. **GCD (DispatchQueue.main)** — a dispatch system that hooks into CFRunLoop via a Mach port
3. **Swift Concurrency (@MainActor)** — built on top of GCD's main queue

A CGEvent tap callback fires at layer 1 (CFRunLoop), bypassing layers 2 and 3 entirely. This is why the PTT fix works: calling `onKeyUp` synchronously from the CGEvent tap ensures it runs immediately, even when GCD and @MainActor are stalled.

## Detailed Findings

### 1. CFRunLoop — The Foundation (Think: Browser Event Loop)

CFRunLoop is macOS's equivalent of the browser's event loop. Just as JavaScript's event loop keeps a tab alive by waiting for events and dispatching them, CFRunLoop keeps the main thread alive and responsive.

**When idle**, the main thread is literally asleep inside a `mach_msg()` system call at the kernel level. This is not a busy-wait — the CPU is doing nothing. When something happens (keypress, timer, network packet), the kernel sends a Mach message to the thread's port, waking it.

#### Run Loop Sources

There are three kinds of event sources:

**Source0 ("manual" input sources)** — Application-level events that cannot wake the run loop directly. You must manually signal them with `CFRunLoopSourceSignal()` and then wake the loop with `CFRunLoopWakeUp()`. Think of these like `queueMicrotask()` in JS — they only run when the loop is already awake.

**Source1 ("kernel-driven" Mach port sources)** — Port-based sources managed jointly by the run loop and the OS kernel. Each has a dedicated Mach port. When the kernel has a message (e.g., a keypress from the HID driver), it signals the port directly, waking the sleeping `mach_msg()` call immediately. **CGEventTap is a Source1.** Think of these like OS-level I/O readiness in Node.js's `epoll`.

**Timers** — Fire at scheduled times. The macOS `Timer.scheduledTimer()` creates one of these.

**Observers** — Passive watchers that fire at specific lifecycle points of the run loop:
- `kCFRunLoopBeforeWaiting` — just before the thread goes to sleep (this is where SwiftUI rendering happens)
- `kCFRunLoopAfterWaiting` — just after the thread wakes up
- Others: `Entry`, `BeforeTimers`, `BeforeSources`, `Exit`

#### One Run Loop Iteration (Step by Step)

```
1.  Observer notification: entering the loop
2.  Observer notification: about to process timers
3.  Observer notification: about to process Source0s
4.  Fire any pending Source0 sources
5.  [If a Source1 is already ready, skip to step 9]
6.  Observer notification: about to sleep (kCFRunLoopBeforeWaiting)
       ← CoreAnimation + SwiftUI commit pending renders HERE
7.  Thread sleeps in mach_msg(), waiting for:
       - Source1 Mach port message (e.g., CGEventTap keypress)
       - GCD main queue's dispatchPort message
       - Timer firing
       - Explicit CFRunLoopWakeUp() call
8.  Observer notification: just woke up
9.  Process whatever woke us:
       - Timer? → fire timer callback
       - Source1? → fire Source1 callback (CGEventTap!)
       - GCD dispatchPort? → drain DispatchQueue.main blocks
10. Loop back to step 2 (or exit)
```

#### Run Loop Modes (Think: Priority Lanes)

A run loop "mode" is a named filter. At any moment, the run loop is running in exactly one mode, and only sources registered for that mode are serviced.

| Mode | When Active | JS Analogy |
|---|---|---|
| Default | Normal idle processing | Normal task queue |
| Event Tracking | User dragging scrollbar, resizing window | — |
| Modal Panel | During modal dialogs | — |
| Common (pseudo-group) | All of the above | — |

Registering a source with `.commonModes` means it fires in **all** common modes. This is why `CGEventTap` is added to `.commonModes` — hotkeys should work even during scrolling.

### 2. GCD (DispatchQueue.main) — Hooked Into CFRunLoop

GCD and CFRunLoop are separate systems, but they are deliberately integrated on the main thread. GCD registers a dedicated Mach port — the `dispatchPort` — with the main run loop.

The chain:
```
DispatchQueue.main.async { someWork() }
  → libdispatch enqueues the block
    → Sends Mach message to its dispatchPort
      → mach_msg() wakes up
        → CFRunLoop sees it came from dispatchPort
          → Calls __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__()
            → Your block runs
```

**Key insight:** `DispatchQueue.main` blocks only drain when the run loop is actively cycling in a compatible mode. During UI tracking mode, GCD blocks can queue up and wait.

**JS analogy:** `DispatchQueue.main.async` is like `setTimeout(fn, 0)` — it defers work to the next task queue entry, not the current microtask.

### 3. Swift Concurrency (@MainActor) — Built on GCD

`@MainActor` is implemented using `DispatchQueue.main`. When the Swift runtime needs to resume a MainActor-isolated task, it enqueues it on `DispatchQueue.main`:

```
@MainActor task resumes
  → Swift runtime calls _enqueueOnMain()
    → libdispatch enqueues on DispatchQueue.main
      → Mach message to dispatchPort
        → CFRunLoop wakes
          → GCD drain
            → Your async function body resumes
```

So the full stack is: **@MainActor → DispatchQueue.main → dispatchPort → CFRunLoop**.

**JS analogy:** `await someMainActorFunction()` is like `await Promise.resolve()` — it re-enters the main queue.

### 4. CGEventTap — Source1 (Kernel-Driven, Lowest Latency)

A `CGEventTap` is a Source1 run loop source. When you set it up:

```swift
let tap = CGEvent.tapCreate(...)                              // returns CFMachPort
let source = CFMachPortCreateRunLoopSource(nil, tap, 0)       // wraps it as Source1
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)  // add to main run loop
```

When a key is pressed:
1. HID driver delivers event to window server
2. Window server sends Mach message to tap's Mach port
3. `mach_msg()` wakes immediately (kernel-level, interrupt priority)
4. Run loop calls `__CFRunLoopDoSource1()` → your callback fires

The callback does NOT wait for the next "pass" of the loop or for a GCD drain cycle. It fires in the same run loop iteration that woke the thread, **before** the thread reaches Source0 processing, GCD drain, or the `beforeWaiting` phase.

### 5. Why CGEventTap Fires Promptly While DispatchQueue.main.async Is Delayed

This is the core insight behind the PTT race condition fix. Three reasons:

**Reason 1: Source1 vs GCD drain order.** Source1 (CGEventTap) fires immediately when the thread wakes. GCD blocks only fire when the wakeup came from the `dispatchPort`. Each wakeup services one thing — a Source1 event waking the thread does not trigger a GCD drain in the same pass.

**Reason 2: Mode filtering.** During UI tracking (scrolling, menus), macOS enters `NSEventTrackingRunLoopMode`. GCD blocks may not drain in this mode. Source1 sources registered with `.commonModes` fire in all common modes.

**Reason 3: Synchronous vs deferred.** The CGEventTap callback fires synchronously in the Quartz event delivery pipeline, while the run loop is in the middle of processing. `DispatchQueue.main.async` by design defers to the *next available drain opportunity*, which may be the next run loop cycle.

### 6. SwiftUI Rendering — kCFRunLoopBeforeWaiting Observer

SwiftUI rendering is driven by `kCFRunLoopBeforeWaiting` observers:

```
State change (@State, @Observable property)
  → SwiftUI marks view as invalidated (does NOT re-evaluate body yet)
    → kCFRunLoopBeforeWaiting observer fires at end of run loop cycle
      → SwiftUI evaluates all invalidated view bodies (diff)
        → CALayer hierarchy updated
          → CoreAnimation commits transaction
            → Render server composites on GPU
```

**Why this matters:** Multiple state mutations in one event handler produce only one body re-evaluation and one frame — they are batched. You never see intermediate states. This is structurally identical to React's batching model — `setState` doesn't immediately re-render; it schedules a re-render for the next flush. The `kCFRunLoopBeforeWaiting` observer is macOS's equivalent of React's scheduler flush.

## How This All Maps to the Codebase

### GlobalHotkeyManager — CGEvent Tap Setup

`vcdr/Hotkeys/GlobalHotkeyManager.swift:35-55`:
- Creates CGEvent tap at `.cgSessionEventTap` (line 36)
- Creates run loop source via `CFMachPortCreateRunLoopSource` (line 53)
- Adds to main run loop with `.commonModes` (line 54)

### Key-Down Flow (Two Hops: GCD → MainActor)

```
CGEventTap callback (Source1, run loop)
  → isHotkeyActive = true (synchronous, line 90)
  → DispatchQueue.main.async { onKeyDown?() } (line 92)     ← Hop 1: GCD
    → Task { @MainActor in onHotkeyDown(fromHotkey: true) }  ← Hop 2: MainActor
      → await transcriptionProvider.isReady
      → await audioRecorder.startRecording()
```

### Key-Up Flow (Zero Hops — Direct)

```
CGEventTap callback (Source1, run loop)
  → isHotkeyActive = false (synchronous, line 100)
  → onKeyUp?() called SYNCHRONOUSLY (line 106)               ← No hops!
    → stopRecordingAndTranscribe() (synchronous method)
      → audioRecorder.stopRecording()
      → state = .transcribing
      → Task { @MainActor in processTranscription() }         ← Only async for transcription
```

### Why Key-Down Uses Hops but Key-Up Doesn't

Key-down triggers `onHotkeyDown()`, which is `async` because it must `await` mic permission and recording start. It **must** go through the async machinery.

Key-up triggers `stopRecordingAndTranscribe()`, which is synchronous — it just stops recording and changes state. The transcription itself is async (spawned as a Task), but the critical state change (`.recording` → `.transcribing`) happens synchronously.

The bug occurred when key-up also went through GCD/MainActor — a 2-10 second delay meant the app stayed in `.recording` state even though the user had released the key.

### Audio Level Timer

`vcdr/Audio/AudioRecorder.swift:85`: `Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true)` fires on the **main run loop** (because `startRecording()` is called from @MainActor context). This 20Hz timer updates `audioLevel`, which triggers SwiftUI view invalidation → re-render at `kCFRunLoopBeforeWaiting`.

### Threading Summary

| Component | Isolation | Runs On |
|---|---|---|
| CGEventTap callback | None (Source1) | Main run loop directly |
| `AudioRecorder` | None (@Observable) | Main actor (caller's context) |
| `ParakeetProvider` | `actor` (cooperative pool) | Background thread pool |
| `RecordingCoordinator` | None (@Observable) | Main actor (explicit Tasks) |
| Audio level timer | Timer (main run loop) | Main thread |
| SwiftUI rendering | BeforeWaiting observer | Main thread |

## Mental Model: React/JavaScript Analogy Table

| macOS / CFRunLoop | Browser / JavaScript |
|---|---|
| `CFRunLoop` sleeping in `mach_msg()` | Event loop `poll()` waiting for I/O |
| Source1 (Mach port, CGEventTap) | OS-level I/O readiness → microtask |
| Source0 (manually signaled) | `queueMicrotask()` manually triggered |
| `DispatchQueue.main.async` block | `setTimeout(fn, 0)` — next task queue entry |
| `Task { @MainActor in }` | `await Promise.resolve()` — re-enters main queue |
| `kCFRunLoopBeforeWaiting` observer | React's `useEffect` flush / end-of-frame commit |
| `CATransaction` commit | React reconciliation + commit phase |
| Run loop mode (Event Tracking vs Default) | `requestIdleCallback` vs normal task queue |
| `@Observable` property change | React `setState()` — batched, deferred render |
| SwiftUI `body` re-evaluation | React component re-render |

## Code References

- `vcdr/Hotkeys/GlobalHotkeyManager.swift:35-55` — CGEvent tap creation and run loop registration
- `vcdr/Hotkeys/GlobalHotkeyManager.swift:84-94` — Key-down handler (GCD dispatch)
- `vcdr/Hotkeys/GlobalHotkeyManager.swift:95-108` — Key-up handler (synchronous call)
- `vcdr/Orchestration/RecordingCoordinator.swift:45-49` — onKeyDown callback wiring (Task @MainActor)
- `vcdr/Orchestration/RecordingCoordinator.swift:54-56` — onKeyUp callback wiring (synchronous)
- `vcdr/Orchestration/RecordingCoordinator.swift:131-150` — stopRecordingAndTranscribe (sync + async Task)
- `vcdr/Audio/AudioRecorder.swift:85` — Audio level timer (main run loop)
- `vcdr/Transcription/ParakeetProvider.swift:5` — Actor declaration (background thread pool)
- `vcdr/App/AppDependencies.swift:71` — coordinator.setupHotkey() called after model ready

## External References

- [Apple Threading Programming Guide — Run Loops](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html)
- [Run, RunLoop, Run! — bou.io](https://bou.io/RunRunLoopRun.html) — Explains `__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__`
- [macOS CFRunLoop Internals — Meld Studio](https://meldstudio.co/blog/macos-cfrunloop-internals-scheduling-high-precision-timers-and-recurring-tasks/)
- [RunLoop in details — kyryl horbushko](https://khorbushko.github.io/article/2020/11/29/runloop-in-depth.html) — Source0 vs Source1 deep dive
- [Dive into CFRunLoop — RY's Blog](https://suelan.github.io/2021/02/13/20210213-dive-into-runloop-ios/)
- [Dispatch Queues and Run Loop Modes — Jeff Johnson](https://lapcatsoftware.com/articles/dispatch-queues-and-run-loop-modes.html)
- [How the Swift Compiler Knows DispatchQueue.main Implies @MainActor — Ole Begemann](https://oleb.net/2024/dispatchqueue-mainactor/)
- [MainActor usage in Swift — Antoine van der Lee](https://www.avanderlee.com/swift/mainactor-dispatch-main-thread/)
- [How Actors Work Internally in Swift — swiftrocks.com](https://swiftrocks.com/how-actors-work-internally-in-swift)
- [The SwiftUI Render Loop — Rens Breur](https://rensbr.eu/blog/swiftui-render-loop/)
- [Behind the Scenes of UI: Part 2 SwiftUI — vbat.dev](https://vbat.dev/behind-the-scenes-of-ui-part-2-swiftui)
- [Apple Kernel Programming Guide — Mach Overview](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/KernelProgramming/Mach/Mach.html)

## Historical Context (from thoughts/)

- `thoughts/shared/handoffs/2026-02-21_12-30-44_fix-ptt-keyup-race-condition.md` — Documents the bug fix that motivated this research: MainActor executor stalling for 2-10+ seconds while CFRunLoop CGEvent tap callbacks continued firing promptly
- `thoughts/shared/plans/2026-02-21-fix-ptt-keyup-race-condition.md` — Original plan (earlier approaches superseded by final synchronous-callback fix)

## Open Questions

- **Why does the MainActor executor stall for seconds?** The handoff document notes possible causes (CoreML main-thread work, @Observable tracking overhead from 20Hz audio level updates, SwiftUI view contention) but no definitive root cause was identified. Instruments profiling would help.
- **Could the key-down path also benefit from synchronous dispatch?** Currently key-down goes through GCD → MainActor and could theoretically be delayed. It hasn't been reported as a problem (delayed start is less noticeable than stuck recording), but the same stalling could affect it.
