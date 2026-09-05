# Secrets live in a synced keychain, not UserDefaults

## Context

Every secret the app holds sits in plain `UserDefaults`: each AI Provider's API
Key under its own key (`ai_processing_anthropic_api_key`, …) on both platforms,
and on macOS the whole Variables list as a JSON blob. `vcdr-mac`'s ADR-0001
chose that deliberately and named this migration as the follow-up — "storage
stays plain `UserDefaults` for now; because the Provider is the single
read/write seam for the key, swapping to Keychain / iCloud Keychain later is a
localized change."

The exposure is asymmetric. The macOS app is **not sandboxed**, so its
preferences plist is readable by any process running as the user — no prompt, no
TCC gate, `defaults read` is enough. On iOS the same values live inside the
app's own container, where no other app can reach them; the exposure there is
unencrypted device backups only.

Moving to the keychain costs no user-facing permission on either platform. An
app reading its own keychain items needs no entitlement and triggers no consent
dialog. The one thing that could have forced a keychain-access-group entitlement
— the iOS keyboard extension needing a key — does not apply: the extension never
touches a provider or a key, and the only `AIProviderFactory.make` caller is the
host app.

## Decision

A **Secret Store** — keychain items, one per secret — becomes the single place
every secret is written and read. It holds each AI Provider's API Key and the
macOS Variables list (one item for the array). Nothing secret stays in
`UserDefaults`.

- **Shape.** A `Shared/` protocol with a keychain implementation and an
  in-memory double for tests. macOS keeps `apiKey(for:)` / `setAPIKey(_:for:)`
  unchanged as its public seam; iOS drops its three `@AppStorage` bindings onto
  the same seam.
- **Items.** Generic passwords, service = bundle id, account = the existing
  defaults key string, so the migration is one-to-one.
- **Sync.** Items are `kSecAttrSynchronizable`, accessibility
  `kSecAttrAccessibleAfterFirstUnlock`. Both apps carry a shared
  `$(AppIdentifierPrefix)glebglazov.vcdr.keys` access group, because their
  bundle ids differ (`glebglazov.vcdr-mac`, `glebglazov.vcdr-ios`) and their
  default access groups would never see each other. macOS passes
  `kSecUseDataProtectionKeychain: true` on every call — the legacy file-based
  login keychain does not sync, and items written there are stranded.
- **Migration.** One-shot per platform, gated by a persisted flag in the shape
  of the existing `didMigrateProviderKeys`: copy each value into the Secret
  Store *only if the Store's value is empty*, then delete the `UserDefaults`
  entry either way. Where a synced value already exists and differs, the synced
  one wins and the Providers screen shows a one-time notice naming the provider,
  so a superseded key is never lost silently.
- **Failure.** A Store read that fails is not an unset value. It gets its own
  `CloudAIClientError` case rather than reusing `missingAPIKey`, which would
  tell the user to add a key that is already there.

## Considered options

- **Device-local items** (`…ThisDeviceOnly`): rejected. It is the strongest
  accessibility class and needs no shared access group, but it costs the user a
  second paste of every key on every device, and ease of setup won.
- **Encrypt the plist with a keychain-held data key**: rejected. Sound as
  crypto, wrong in structure — it splits one logical value across two stores
  with two lifecycles that come apart on their own (Migration Assistant, an iOS
  reinstall where keychain items outlive `UserDefaults`, a synced ciphertext
  beside a device-local data key). Every one of those yields ciphertext with no
  key, whose only remedy is purge-and-re-enter: a corruption state, a purge
  routine, and a UI for both, existing solely because the layer exists. Direct
  keychain storage has no such state — a missing item is simply unset, which the
  app already models.
- **Provider keys only, Variables left in the plist**: rejected. Same hole, same
  mechanism to close it, and it forfeits the claim that the app keeps no secret
  in `UserDefaults`.
- **One JSON blob for all three provider keys**: rejected. Per-provider items
  match the current layout and keep the migration one-to-one.

## Consequences

- **The bash fallback is unchanged and still injects every provider key into
  every bash script's environment** (`TextProcessingPipeline.swift`), gated only
  for the local agent path via `localAgentPassVariables`. This is the exposure
  the Secret Store does *not* close, and it is knowingly out of scope: gating it
  would silently break every script a user already has. It is its own decision
  for its own day.
- Sync is last-writer-wins per item once migration is done; the "only if empty"
  rule protects the upgrade, not the steady state. On a first launch where the
  synced item has not yet arrived, both devices can see empty and both write.
  Either outcome leaves the user holding one of their own valid keys.
- Choosing sync forfeits `…ThisDeviceOnly`, so the items are in encrypted device
  backups — restorable only to the same Apple ID. Still a clear gain on iOS,
  where the values are in backups as plaintext today.
- Local debug builds sign with a different identity than the notarized Developer
  ID release, so the two see separate items and a re-sign can raise a one-time
  "wants to access your keychain" prompt. Developer-side only.
- macOS-only Variables now sync to iOS, where nothing reads them. Harmless, and
  cheaper than a per-item sync policy.
- **This does not conflict with getting off iCloud for sync.** That effort
  targets the ubiquity container — `UbiquitySubstitutionStore`,
  `UbiquityHistoryStore`, ADR-0004 — which is where the performance cost lives.
  iCloud Keychain is a separate subsystem: a different daemon, a different
  entitlement family, no file coordination, no `NSMetadataQuery`, and reads that
  never touch the network. It is exempt from that effort's "no longer depends on
  iCloud" criterion by decision, not by oversight.
