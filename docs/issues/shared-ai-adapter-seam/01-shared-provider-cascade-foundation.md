## Parent

[Shared AI Adapter Seam PRD](../../prds/shared-ai-adapter-seam.md)

## What to build

Introduce the shared **LLM Adapter Seam** core in the cross-platform Shared module — without rewiring either shipped app yet.

Shared gains **Cloud AI Backend** (Anthropic, OpenAI, Gemini), the **LLM Adapter** protocol, cloud-backend **AIClientError**, and **Provider Cascade** (retry within budget, optional fallback once, timeout race, cancellation handling). Behavior must match today's platform copies byte-for-byte in semantics.

Add **SharedTests** with a scriptable fake LLM Adapter and the full Provider Cascade test suite migrated from existing platform prior art. Wire SharedTests into the **macOS** unit test bundle first so cascade tests run in CI. Both app targets must compile the new Shared production sources even though factories still point at platform-local code until slice 2.

## Type

AFK

## Acceptance criteria

- [x] Shared defines Cloud AI Backend, LLM Adapter protocol, cloud-backend AIClientError, and Provider Cascade with no dependency on Mode, AI Prompt Mode, or platform settings
- [x] Provider Cascade preserves current semantics: retry within budget, timeout via race, single fallback attempt, `AITimedOut`, cancellation → fallback/terminal path
- [x] SharedTests contains fake LLM Adapter and Provider Cascade tests; duplicated cascade tests are removed from platform targets when migrated
- [x] macOS test scheme runs SharedTests cascade suite green
- [x] Both macOS and iOS app targets build with new Shared AI sources present (factories may still reference old platform files until slice 2)
- [x] No user-visible behavior change in either app

## Blocked by

None — can start immediately
