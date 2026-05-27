## Problem Statement

VCDR iOS currently concentrates too much per-recording behavior in the UI-facing recording coordinator. A single coordinator owns observable UI state, app lifecycle entry points, deep links, audio start/stop ordering, transcription and streaming setup, AI processing, retry/status handling, Keyboard Channel publication, background task cleanup, history recording, and terminal state recovery.

From the user's perspective, this makes recording behavior harder to evolve safely. A change to one part of a recording lifecycle can affect keyboard delivery, Capture handling, AI processing, or cleanup because those concerns are interleaved. The app needs a deeper Recording Run module so one user-initiated recording can be reasoned about, tested, and completed through a small interface.

## Solution

Introduce a Recording Run module that owns the lifecycle of one user-initiated recording from start through terminal completion. The Recording Run owns recording/transcription/AI/finalization ordering, produces a terminal completion state, and passes that state to injected completion adapters.

The UI-facing recording coordinator remains the app adapter. It keeps observable UI state, app lifecycle and deep-link entry points, Recording Run creation/start, user command forwarding, and high-level status/error presentation. It should not own per-run ordering once a Recording Run has started.

The completion seam receives every terminal state, not just successful transcripts. Terminal states include success, empty result, cancellation, and processing failure. Keyboard-facing failure delivery is not required in the first implementation, but failure must remain represented in the terminal state model so a later Keyboard Channel message can be added without changing the Recording Run interface.

Hot Mic Session policy remains outside the Recording Run. The Recording Run may own a per-run background task needed to complete an active recording, but it does not own app-wide warm audio lifecycle, heartbeat presence, Live Activity presence, or inactivity timeout policy.

## User Stories

1. As a dictation user, I want recording to start and stop reliably, so that each recording produces the expected result or clean terminal state.
2. As a keyboard user, I want a successful keyboard-started recording to publish a Bundled Result, so that dictated text can be inserted into the host app.
3. As a keyboard user, I want an empty recording to return the app to idle behavior, so that the keyboard does not wait forever for text that does not exist.
4. As a keyboard user, I want a failed recording to return the app to idle behavior, so that the keyboard does not remain stuck in a recording or waiting state.
5. As a keyboard user, I want current failure behavior preserved initially, so that the refactor does not introduce new visible keyboard error UI before it is designed.
6. As a future keyboard user, I want processing failures to be represented structurally, so that a later version can show a keyboard-facing failure message.
7. As an app user, I want assistant-mode processing to be part of the recording lifecycle, so that a run is not considered complete before AI output is finalized.
8. As an app user, I want plain dictation and assistant-mode dictation to terminate through the same lifecycle, so that success, empty, cancellation, and failure behave consistently.
9. As an app user, I want Captures included when a recording mode needs them, so that assistant context remains correct after the extraction.
10. As an app user, I want cancellation to clean up recording state, so that a cancelled run does not leak audio, background task, Keyboard Channel, or UI state.
11. As an app user, I want recording failures to clean up recording state, so that later recordings can start normally.
12. As an app user, I want history recording to happen after terminal completion where appropriate, so that successful recordings remain visible in history.
13. As a maintainer, I want the recording coordinator to stop owning per-run ordering, so that UI lifecycle code is not coupled to transcription, AI, delivery, and persistence details.
14. As a maintainer, I want one module to own the state machine for a recording, so that the code has locality around recording lifecycle bugs.
15. As a maintainer, I want completion adapters to handle external effects, so that Keyboard Channel delivery and history recording can be changed independently.
16. As a maintainer, I want the Recording Run interface to remain small, so that tests target behavior instead of internal coordinator steps.
17. As a maintainer, I want terminal states to flow through one completion seam, so that failure and cancellation do not create hidden lifecycle paths.
18. As a maintainer, I want AI provider creation and configuration injected into the run, so that the run owns ordering without becoming responsible for global dependency construction.
19. As a maintainer, I want Hot Mic Session policy outside the Recording Run, so that warm-audio reachability is not mixed with one recording's lifecycle.
20. As a maintainer, I want per-run background task cleanup owned by the run, so that finishing, failure, and cancellation all release the task predictably.
21. As a maintainer, I want Keyboard Channel failure delivery left as an extension point, so that the initial extraction stays small while preserving future leverage.
22. As a maintainer, I want existing Keyboard Channel success behavior preserved, so that keyboard insertion remains stable during the architecture change.
23. As a maintainer, I want existing history behavior preserved for successful runs, so that users do not lose recording records.
24. As a maintainer, I want tests for Recording Run terminal behavior, so that success, empty, cancellation, and processing failure are covered without launching UIKit.
25. As a maintainer, I want tests to verify observable external effects rather than private helper calls, so that the module can be refactored without rewriting brittle tests.

## Implementation Decisions

- Build or extract a Recording Run module named after the domain concept in the iOS context.
- Keep the UI-facing recording coordinator as the adapter for observable UI state, app lifecycle entry points, deep links, run creation/start, command forwarding, and high-level status/error presentation.
- Move per-run ordering out of the coordinator and into Recording Run: audio start/stop ordering, transcription, streaming/finalization, AI processing, terminal state production, and per-run cleanup.
- Include AI processing inside the Recording Run lifecycle. From the user's perspective, a run is not complete until assistant/plain-text processing has reached a terminal state.
- Use a completion seam that receives terminal completion states, not only successful outcomes.
- Model terminal states at least as success, empty result, cancellation, and processing failure.
- Preserve structured processing failure information even though the first Keyboard Channel adapter may map failure to existing idle/no-result behavior.
- Defer keyboard-visible failure messages. The first implementation should create the opportunity for that addition without doing the product/UI work now.
- Represent Keyboard Channel delivery and history recording as completion adapters rather than concrete behavior hard-wired into the Recording Run.
- The completion adapters may publish a Bundled Result, publish idle/no-result behavior, record history, or perform other external effects appropriate to a terminal state.
- Hot Mic Session policy remains outside the Recording Run. This includes warm audio lifecycle, heartbeat presence, Live Activity presence, and inactivity timeout policy.
- The Recording Run may own any background task needed to complete one active recording after it starts, including cleanup on success, empty result, cancellation, and failure.
- Avoid creating a new god object. The Recording Run should be deep, but concrete external mechanisms should remain behind injected adapters.
- Keep dependency creation outside the Recording Run. The run receives the adapters and providers it needs through construction.
- Do not introduce singletons. All new collaborators should be injected through existing dependency construction patterns.
- Do not rely on magic timing literals during extraction. Any required timing should remain named and documented according to the architecture rules.
- Avoid adding new user-visible behavior as part of the extraction unless required to preserve existing behavior.

## Testing Decisions

- Tests should focus on the Recording Run interface and externally observable behavior: terminal state, completion adapter calls, cleanup, and preserved delivery semantics.
- Tests should not assert private helper ordering unless that ordering is visible through the run's public behavior.
- Add Recording Run tests for successful plain dictation completion.
- Add Recording Run tests for assistant-mode completion, including AI processing inside the run lifecycle.
- Add Recording Run tests for empty result completion.
- Add Recording Run tests for cancellation completion.
- Add Recording Run tests for processing failure completion.
- Add tests proving failure reaches the completion seam even if the initial Keyboard Channel adapter maps it to idle/no-result behavior.
- Add tests proving per-run background task cleanup happens for all terminal states if that ownership is implemented in the run.
- Use existing `KeyboardChannelTests` as prior art for channel-facing behavior and adapter expectations.
- Use existing `HotMicSessionTests` as prior art for keeping Hot Mic Session policy separate from per-run lifecycle behavior.
- Do not use iOS simulators for verification. If iOS device verification is needed, ask the maintainer to run on a physical device.
- Plain compile-only checks with `xcodebuild build` are acceptable if needed, but this PRD does not require implementation yet.

## Out of Scope

- Designing or implementing keyboard-visible failure messages.
- Deepening the Keyboard Channel module itself beyond the completion adapter needed by this extraction.
- Extracting Keyboard Recording Interaction from the keyboard controller.
- Unifying Session Settings.
- Splitting Audio Route Policy from Audio Capture.
- Reworking Hot Mic Session policy, heartbeat behavior, Live Activity presence, or inactivity timeout rules.
- Changing transcription providers, AI provider behavior, model loading, or user-facing processing options.
- Changing the app's visual UI or keyboard layout.
- Rewriting history storage beyond preserving the existing successful-run behavior through an adapter.

## Further Notes

The key architectural goal is locality. Once a Recording Run has started, terminal ordering should live in one module. Success, empty result, cancellation, and processing failure should all terminate through the same completion seam so the coordinator does not regain hidden lifecycle responsibilities.

The first implementation should be conservative. Preserve existing behavior, especially for Keyboard Channel failure handling, while changing the structure enough that later failure messaging is an adapter-level addition rather than a coordinator-level refactor.
