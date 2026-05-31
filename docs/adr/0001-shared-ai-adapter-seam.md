# Shared AI adapter seam

VCDR runs cloud LLM adapters on both macOS and iOS, but the HTTP providers and retry/fallback cascade were duplicated per platform. We extract a **Shared AI adapter seam**: `LLMProvider`, the three cloud HTTP adapters, `FallbackProvider`, and cloud-backend `AIClientError` live in `Shared/AI/`. **AI Provider Selection** — which backend, API keys, AFM fallback, retry budget — stays in each platform's factory.

Apple Foundation Models is iOS-only today and is **not** part of the shared backend identity. Shared defines `CloudAIBackend` (Anthropic, OpenAI, Gemini). iOS wraps it as `enum AIProvider { case cloud(CloudAIBackend); case apple }` with explicit picker registration when AFM is available; macOS uses `typealias AIProvider = CloudAIBackend`. `AppleAFMProvider` remains in the iOS target.

PR 1 ships the seam only. **Model Catalog** (shared base list + platform extensions, dedupe with platform winning) and adapter `modelId` selection are deferred to PR 2. Shared adapter tests live in `SharedTests/` and compile into both `vcdr-macTests` and `vcdr-iosTests`; platform tests cover factory wiring only.

## Considered options

- **Shared selection policy** — move `AIProviderFactory` and settings lookup into Shared. Rejected: macOS reads Mode + Variables; iOS reads AI Prompt Mode + AFM availability; coupling would fight platform lifecycles.
- **`apple` in shared backend enum** — one `CaseIterable` for all backends. Rejected: macOS pickers use `allCases` today; Apple must be registered explicitly per platform, not filtered out of a shared list.
- **Shared `AppleAFMProvider`** — `#if canImport(FoundationModels)` in Shared. Rejected for PR 1: adds framework coupling before macOS needs AFM; adapter is thin and platform-specific.
- **Model catalog in PR 1** — move hardcoded model IDs into Shared immediately. Deferred: catalog merge rules and platform extensions were agreed but belong in a follow-up PR.

## Consequences

- Retry, timeout, and HTTP decode bugs are fixed once in Shared; platform factories only map settings → `(primary, fallback?, maxAttempts, timeout)`.
- iOS `AIProvider` persistence keeps flat raw strings (`"anthropic"`, `"apple"`) via custom `RawRepresentable` — no UserDefaults migration.
- `AIClientError` in Shared is typed on `CloudAIBackend` only; platform-only failures (e.g. AFM unavailable) get platform errors if needed later.
- macOS `localAgent` CLI model lists stay outside Shared; they become Model Catalog extensions in PR 2, not cloud backend identity.
