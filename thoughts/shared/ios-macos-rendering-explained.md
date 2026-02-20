# iOS/macOS App Rendering & Runtime Concepts

## 1. How Rendering Works

A SwiftUI app is **not** a game engine redrawing 60fps. It's **reactive** — the UI only redraws when data changes.

The chain looks like this:

```
@Observable object's property changes
        ↓
SwiftUI's observation system detects the change
        ↓
SwiftUI marks affected views as "dirty" (needs redraw)
        ↓
On the next RunLoop pass, SwiftUI diffs the view tree
        ↓
Only the changed parts are sent to Core Animation
        ↓
Core Animation composites layers on the GPU
        ↓
Display shows the frame
```

When you write `state = .transcribing` in a coordinator, here's what happens mechanically:

1. The `@Observable` macro synthesized a `willSet`/`didSet` wrapper around `state`. On mutation, it calls `ObservationRegistrar.withMutation(of: self, keyPath: \.state)`.
2. This notifies every view whose `body` previously **read** `state` (SwiftUI tracked this during the last `body` evaluation).
3. Those views are scheduled for re-evaluation — but not immediately. They're enqueued for the next **transaction**, which is committed when the RunLoop gets a chance to process it.

This is why synchronous vs async matters: if you change `state` synchronously inside a button action, SwiftUI batches it into the **current transaction** and commits at the end of the event. If you change it in a `Task { }`, it happens in a **future transaction** on a later RunLoop pass.

## 2. What is the RunLoop?

Every macOS/iOS app has a **main thread** with an event loop called the `RunLoop`. It's an infinite loop that looks roughly like this:

```
while app is running {
    1. Wait for an event (mouse click, keyboard, timer, Task, etc.)
    2. Dispatch the event to the appropriate handler
    3. Let SwiftUI commit any pending view updates
    4. Let Core Animation render the frame
    5. Go back to waiting
}
```

One full iteration of this loop is a **"run loop cycle"** or **"run loop pass"**. A cycle typically takes a few milliseconds if there's work, or blocks indefinitely if idle.

When you write `Task { await someFunction() }`, you're creating a job that gets enqueued into the MainActor's executor, which is backed by the RunLoop. It doesn't run immediately — it runs when the RunLoop picks it up, which is **after the current cycle completes**:

```
Cycle N:  Button tap → toggleRecording() → Task created → SwiftUI commit → render
                                             ↑ task is just a job in a queue here

Cycle N+1: Task executes → onHotkeyUp() → state changes → SwiftUI commit → render
```

That gap between cycle N and N+1 is what causes delay. It's usually <16ms (one frame), but if the RunLoop is busy (timers firing, animations, other tasks), it can be longer.

The fix was to make the stop path **synchronous within the same cycle**:

```
Cycle N:  Button tap → toggleRecording() → stopRecordingAndTranscribe()
          → state = .transcribing → SwiftUI commit → render  ← all in one pass
```

## 3. Why Task.sleep? Is it common?

There are two categories of `Task.sleep` usage:

### a) Workaround for system API timing

```swift
// Brief delay for the target app to gain focus before simulating Cmd+V
previousApp.activate()
try await Task.sleep(for: .milliseconds(100))
try await action.execute(text: text)  // simulates Cmd+V
```

This is a **workaround**, not a design pattern. `NSRunningApplication.activate()` tells macOS "bring this app to the front", but it's **asynchronous at the system level** — the window server needs time to actually swap the frontmost app. If you simulate Cmd+V immediately, the keystroke might go to the wrong app (or nowhere). There's no callback or delegate that tells you "activation is complete", so you poll or sleep.

This is unfortunately common in macOS automation. Apple's Accessibility and CGEvent APIs were designed for assistive technology, not programmatic automation, so they lack proper completion handlers. You'll see this pattern in every macOS app that does clipboard + paste automation (Alfred, Raycast, TextExpander, etc.).

### b) Deliberate UX delay

```swift
try? await Task.sleep(for: Self.errorDisplayDuration)  // 3 seconds
if case .error = state { state = .idle }
```

This is a **deliberate UX delay** — show the error for 3 seconds so the user can read it, then auto-dismiss. This is a legitimate pattern. The alternatives would be:
- A timer (`Timer.scheduledTimer`) — older pattern, same effect
- An animation with delay — more complex for the same result
- Requiring user dismissal — worse UX for transient errors

`Task.sleep` is preferred over `DispatchQueue.main.asyncAfter` in modern Swift because it's cancellable (if the Task is cancelled, the sleep throws `CancellationError`) and uses structured concurrency.

### When Task.sleep is a code smell

When it's used to "wait for something to be ready" without checking if it actually is:

```swift
// Bad: hope 500ms is enough
try await Task.sleep(for: .milliseconds(500))
useTheFile()

// Better: poll until ready or timeout
for _ in 0..<50 {
    if FileManager.default.fileExists(atPath: path) { break }
    try await Task.sleep(for: .milliseconds(10))
}
```
