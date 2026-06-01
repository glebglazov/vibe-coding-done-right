# Shared Context

Language that means the same thing on macOS and iOS. Platform glossaries own Capture Session, Recording Run, Mode, and AI Prompt Mode; this context owns the cross-platform AI invocation seam and other genuinely shared concepts.

## Language

### AI Invocation

**LLM Adapter**:
A concrete backend wrapper that performs one non-streaming text-in/text-out enhancement call. Cloud HTTP providers (Anthropic, OpenAI, Gemini) live here; platform-specific backends such as Apple AFM stay outside.
_Avoid_: AI client, provider implementation, HTTP adapter

**LLM Adapter Seam**:
The shared module boundary for LLM Adapters and their resilience composition. It does not know about Mode, AI Prompt Mode, session settings, or which backend a platform chose for a given run.
_Avoid_: AI module, shared AI factory, provider selection

**Provider Cascade**:
The retry-within-budget, then optional fallback-once composition around a primary LLM Adapter. A Provider Cascade receives its primary, fallback, attempt limit, and timeout from platform code; it does not read settings itself.
_Avoid_: fallback logic, retry policy, AI coordinator

**AI Provider Selection**:
Platform-owned policy that picks the primary LLM Adapter, resolves API keys, and decides whether an on-device fallback applies. macOS derives this from Mode and Variables; iOS derives it from AI Prompt Mode and AI Processing Settings.
_Avoid_: provider factory, LLM routing, adapter wiring

**Model Catalog**:
The proposed model choices for a given AI backend. Shared owns the base cloud catalog; each platform may append its own entries at composition time without forking the shared list.
_Avoid_: model enum, hardcoded default, provider config

**Model Catalog Extension**:
Platform-specific model entries appended to the shared base catalog — for example macOS local-agent CLI model names or a platform-only cloud model preview. Extensions are supplied by AI Provider Selection, not edited into Shared source.
_Avoid_: platform override file, forked catalog, duplicate adapter list

**Model Catalog Merge**:
Base entries come first, then platform extensions. When `(backend, modelId)` duplicates, the platform extension wins — allowing label overrides and deprecated shared entries to be superseded without forking the base list.
_Avoid_: append-only duplicates, shared-wins override, global registry mutation

**Cloud AI Backend**:
The shared backend identity for HTTP cloud providers: Anthropic, OpenAI, and Gemini. Shared adapters, Model Catalog entries, and cloud-side errors use this — not platform-only backends.
_Avoid_: AIProvider, full backend list, selectable provider enum

**Platform Backend Registration**:
Each platform publishes which backends appear in settings and mode pickers. iOS may register Apple when AFM is available; macOS registers local-agent backends separately. Registration is explicit — never derived from `CaseIterable.allCases` on a shared enum.
_Avoid_: allCases picker, shared Apple case, automatic backend discovery

## Initialization

**Shell-first Initialization**:
The guarantee that the platform's visible shell renders before any backend dependency is initialized. Backend work — transcription models, history stores, iCloud container resolution, hardware enumeration — is deferred to post-shell tasks, and readiness is surfaced asynchronously via state changes.
_Avoid_: lazy loading, deferred init, responsive launch

**Backend Rejection**:
When the user attempts an action that requires a backend that is not yet ready, the shell must reject the action with immediate visual feedback rather than accepting the action and blocking later.
_Avoid_: queueing, pending state, silent hang

**Shell-Critical Init**:
The minimal synchronous work required for the shell to render its first frame correctly. On macOS this includes `AppSettings`, `SessionOverrides`, and `StyleRegistry`; on iOS this includes the `RecordingFlowCoordinator` shell. Everything else is backend init and must be deferred.
_Avoid_: early init, pre-render setup, blocking startup

**Backend Init**:
All initialization that can be deferred until after the shell has rendered. Includes transcription model download/compile, iCloud container resolution, history store construction, audio device enumeration, and hotkey registration.
_Avoid_: startup sequence, launch bootstrap, app ready

## Flagged Ambiguities

**Processing Type vs AI Prompt Mode vs LLM Adapter Seam**:
Processing Type and AI Prompt Mode decide whether and how dictated text enters AI processing on each platform. The LLM Adapter Seam sits below that — one backend call once platform code has already decided to invoke AI.

## Example Dialogue

Dev: "Should `AIProviderFactory` move into Shared?"

Domain expert: "No. That is AI Provider Selection — Mode and Variables on macOS, AI Prompt Mode and AFM settings on iOS. Shared owns the LLM Adapter Seam and Provider Cascade only."

Dev: "Where does Apple AFM belong?"

Domain expert: "Outside Shared. It is a platform LLM Adapter wired in by iOS AI Provider Selection, the same way macOS might add a local agent adapter later without moving selection policy into Shared."

Dev: "What moves into Shared for the first extraction?"

Domain expert: "The LLM Adapter protocol, the three cloud adapters, Provider Cascade, shared adapter errors, and the test fake. Platform factories stay thin and only map their settings into a Provider Cascade."

Dev: "Can macOS or iOS add their own proposed models without duplicating the shared list?"

Domain expert: "Yes. Shared publishes the base Model Catalog; each platform passes Model Catalog Extensions at composition time. The merged list drives pickers and defaults — Shared never needs to know about local-agent CLI models or unreleased platform previews."

Dev: "Should Apple be a case in the shared backend enum?"

Domain expert: "No. Cloud AI Backend covers the three HTTP providers in Shared. iOS registers Apple through Platform Backend Registration when AFM is available — the same way macOS never shows Apple in its provider picker today."

Dev: "Where do FallbackProvider tests live after extraction?"

Domain expert: "In a Shared test target with FakeLLMProvider. Platform targets only test AI Provider Selection wiring — which primary, fallback, and budget each platform passes into the Provider Cascade."

Dev: "What ships in the first extraction PR?"

Domain expert: "The LLM Adapter Seam only — shared protocol, cascade, cloud adapters, cloud-backend errors, SharedTests, and platform factory rewiring. Model Catalog and model-id selection wait for PR 2."

Dev: "How do SharedTests run in a two-xcodeproj repo?"

Domain expert: "One SharedTests source tree compiled into both vcdr-macTests and vcdr-iosTests. Each platform scheme runs the shared cascade and adapter tests plus its own factory wiring tests."
