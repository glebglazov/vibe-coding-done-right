# iCloud-backed store construction never runs on the main actor

Constructing an iCloud-backed store — resolving the container, scanning it,
decoding the first page, reading the account token — is blocking, network-backed
work. All of it runs off the main actor behind an async factory that returns a
`Sendable` snapshot; the `@MainActor` store object is then built from that
snapshot cheaply. A store's `init` may not perform the scan.

## Context

`bootstrapHistory()` already moved the *resolve* off-main via `withBlockingTask`
and carried a comment stating the intent: "Resolve exactly once and reuse the
root for both reconcile and store construction so `make` never blocks the main
actor a second time." The code did not do that. Only the resolve moved;
`HistoryStoreFactory.make` still ran on the main actor, and it reaches
`UbiquityHistoryStore.init?`, a `@MainActor` init that synchronously performs:

- `FileHistoryStore.init` → `ensureDirectoryExists()`,
  `migrateLegacyFileIfNeeded()`, `rebuildIndex()` (a full directory scan of the
  ubiquity container, where each attribute read can force materialization), and
  `loadNextPage()` (JSON decode).
- `startWatchingContainer()` — `NSMetadataQuery` start.
- `refreshAccountState()` → `FileManager.default.ubiquityIdentityToken`, a
  blocking iCloud call.

Device logs for 2026-08-19 caught the cost. A keyboard Deep-Link Fallback
launched the app at 22:02:39.132; `bootstrapHistory` logged "after
resolve+reconcile" at 22:02:39.348 and "exit" at **22:02:55.803** — 16.3 seconds
inside `make`, on the main actor. The scene did not become active, the record
intent was not serviced, and model init could not start until it returned.
Launch telemetry recorded `msToReady=17468` with `encoderMs=382`.

That last pair is the point: **the transcription model was not the bottleneck.**
Every launch in the sampled 24 hours reported `verdict=WARM`, with encoder loads
of 359–2013ms. ADR-0001's cold-specialization isolation was guarding a path that
costs well under a second, while an iCloud directory scan held the mic, the
model and the App Shell for sixteen.

An earlier run the same day (15:00:14) shows the worst form: the app launched,
set Arming, and then produced no model load, no `Audio engine started`, and no
audio buffer at all. The user stopped it fourteen seconds later. The run
terminated without a transcript and without a reported reason.

## Decision

1. **Off-main construction, snapshot-in.** `UbiquityHistoryStore` and
   `UbiquitySubstitutionStore` gain async factories that perform the scan,
   decode and account-token read on `withBlockingTask`, returning a `Sendable`
   snapshot. The `@MainActor @Observable` object is constructed from the
   snapshot and does no filesystem work in `init`. `startWatchingContainer()`
   stays on the main actor — `NSMetadataQuery` needs a run loop — because
   starting the query is cheap; the scan and the token read are not.

2. **Both stores, one change.** `bootstrapSubstitutions()` carries the identical
   defect ("mirroring `bootstrapHistory`") and is fixed in the same change.

3. **History is off the record path.** Recording depends on the audio engine and
   the model, never on history readiness.
   `HistoryRecordingRunCompletionAdapter` already buffers completed runs and
   flushes them when `setHistory` lands, with tests covering the pending-flush
   and no-duplicate cases, so this is the removal of an accidental coupling
   rather than new machinery.

4. **An Arming Deadline makes a stalled run honest.** A Recording Run that has
   not produced its first audio buffer within 5 seconds of Arming terminates as
   a Processing Failure carrying a reason. The deadline is keyed on the first
   audio buffer, not on `engine.start()` returning, because the 15:00 run never
   got `startCapture` to return at all. Five seconds sits clearly above the
   worst healthy cold path observed (~2.4s tap-to-buffer) without being
   trigger-happy.

## Considered options

- **Lazy properties instead of an async factory** — keep the synchronous `init`
  and defer the expensive work to first access. Rejected: it scatters the
  blocking calls across whichever main-actor property access touches them
  first, which is the exact failure mode this ADR exists to end. The blocking
  work should be visible at one seam, not hidden behind an accessor.
- **Fix history only, leave substitutions.** Rejected: the same bug written
  twice. `bootstrapSubstitutions` has not surfaced in logs yet only because its
  container is smaller.
- **Prewarm the transcription model at download time** (as VivaDicta does for
  WhisperKit, folding `prewarmModels()` into its download progress UI).
  Deferred, not rejected: it is a sound shape, but device telemetry shows no
  Cold Specialize to prevent, so it buys nothing today.

## Consequences

- **ADR-0001's framing is narrowed, not revoked.** Its serial-encoder-last
  isolation and prewarm barrier stay. But its premise — that cold ANE
  specialization is the launch bottleneck — is not what the device is doing now;
  sampled launches are uniformly WARM. Read ADR-0001 as the answer to a Cold
  Specialize launch, not as the explanation for a slow one.
- **`msToReady` conflates two costs and should be read carefully.** It spans
  bootstrap and model load together, which is why it reported 17468ms on a
  launch whose model was ready in 803ms. Anyone diagnosing a slow launch should
  compare `msToReady` against `encoderMs`/`maxAneMs` before blaming the model.
- **The background model warm task keeps earning its keep as repair, not as the
  primary path.** It correctly no-ops every 30 minutes; leave it alone.
- **A store built from a snapshot can be stale by the time it is installed.**
  The `NSMetadataQuery` watcher already exists to reconcile remote changes, so
  the window is bounded — but the snapshot must not be treated as authoritative
  after installation.
- **Do not move construction back into `init` for tidiness.** An `init` that
  does I/O reads as the obvious shape and is how this cost arrived; the async
  factory is deliberate.
