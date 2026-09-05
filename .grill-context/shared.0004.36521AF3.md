---
fragment: 36521AF3
generation: 0004
branch: master
---

+ Secret Store
  The single place every secret the app holds is written and read on both platforms — keychain items, never UserDefaults. It holds each AI Provider's API Key and the macOS Variables list. Its items are synchronizable, so one Apple ID's devices share one set; a device never overwrites a value that is already there. It is not part of the ubiquity container and shares nothing with it but a brand name.
  avoid: keychain wrapper, secrets manager, credential store, SecItem helper, API Key Store
  under: AI Invocation

+ API Key
  The credential an AI Provider presents to its cloud backend. The AI Provider owns it and is the single source of truth for AI calls; it lives in the Secret Store, and a Reserved Variable only mirrors it into the bash environment.
  avoid: token, secret, credential, provider key
  under: AI Invocation
