# AI Provider owns the API key; the Reserved Variable is a bash-only fallback

## Context

macOS originally had no Providers screen: a Cloud AI Backend's API key *was* a
Variable named `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GOOGLE_API_KEY`,
auto-created empty in `AppSettings` and read at call time by `AIProviderFactory`
via `variableEnvironment[provider.apiKeyVariableName]`. The same lookup served
both AI calls and bash scripts. We added a Providers screen (mirroring iOS) so
keys are configured per AI Provider, and demoted the Variable.

## Decision

The **AI Provider** owns its API Key and is the single source of truth: AI calls
always read the Provider's stored key directly, never a Variable. Each Provider's
key is additionally injected into the bash environment under its **Reserved
Variable** name (`ANTHROPIC_API_KEY`, etc.) as a *fallback* — so existing bash
scripts keep working with zero configuration. A user may create an explicit
Variable with a Reserved name to override the bash-facing value only; this never
changes the key any AI call uses. An empty Reserved Variable is treated as unset
(falls back to the provider key) — only a non-empty value overrides. The
reserved rows are no longer auto-created; the Variables screen is empty by
default and moves to an "Advanced" sidebar section.

A one-shot migration copies each non-empty Reserved-named Variable value into the
matching (still-empty) Provider key and deletes that Variable row, so upgrading
users keep both working AI calls and the bash fallback.

## Considered Options

- **Variable stays the source of truth** (status quo, seed the Provider from it):
  rejected — two editable homes for one secret, and the iOS model already treats
  the Provider as authoritative.
- **A Variable override also redirects AI calls**: rejected — makes the
  bash-facing convenience silently change which key reaches the cloud, the exact
  footgun the divergence warning exists to prevent.

## Consequences

- AI calls and bash scripts can intentionally diverge; the Variables screen warns
  when a Reserved override duplicates (safe to delete) or differs from the
  provider key (intended?).
- Storage stays plain `UserDefaults` for now; because the Provider is the single
  read/write seam for the key, swapping to Keychain / iCloud Keychain later is a
  localized change.
