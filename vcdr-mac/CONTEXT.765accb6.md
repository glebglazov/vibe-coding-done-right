---
fragment: 765accb6
generation: 0001
branch: master
---

+ AI Provider
  The user-selectable, key-owning AI backend on macOS, edited on the AI Providers screen: a Cloud AI Backend together with its stored API Key and configured status. A Mode's provider picker offers only configured AI Providers. macOS AI Providers are cloud-only; the term is shared with iOS, where the set also includes Apple (governed by Platform Backend Registration). An AI Provider is configured when it has a non-empty stored API Key.
  avoid: Cloud AI Provider, provider enum, AIProvider case
  under: Modes And Processing

- Cloud AI Provider

+ Reserved Variable
  A Variable name reserved for an AI Provider's API Key — ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY. By default no such Variable row exists; the AI Provider's API Key is injected into the bash environment under this name as a fallback. AI calls always read the AI Provider's API Key directly, never a Variable. A user may create an explicit Variable with a Reserved name to override the bash-facing value only; this does not change the key any AI call uses. An empty value on a Reserved Variable is treated as unset — it falls back to the provider key rather than blanking the bash variable; only a non-empty value overrides.
  avoid: API key variable, required variable, magic variable
  under: Modes And Processing
