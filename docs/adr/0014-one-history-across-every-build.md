# One history across every build of the app

The user runs Debug and Release builds of this app interchangeably, on the same
devices, and requires the full history to be present in all of them. This is a
product requirement, not an implementation accident. It constrains which sync
transports are available, and it is the reason CloudKit stays deferred even
after the container proves insufficient.

## Context

Nothing in the code marks a build. `FileHistoryStore.localStorageRoot` is a
fixed path — `~/Library/Application Support/VCDR` — with no bundle id and no
build configuration in it, and both the Debug and the Release Mac target use the
bundle id `glebglazov.vcdr-mac`. iOS is the same shape through its fixed app
group. So one Local Store already serves every build on a device.

A reader could easily take that for an oversight and "fix" it by keying the path
on the build configuration. That would split the user's history in two, which is
the outcome this ADR exists to forbid.

## Decision

Every build of the app on one device reads and writes one Local Store, and syncs
through one container folder. No storage path, container identifier or database
name is keyed on the build configuration.

A Sync Transport that cannot honour this is not eligible, however well it
performs.

## Consequences

**CloudKit gains a second blocker.** [ADR-0010](0010-a-local-store-answers-every-read.md)
deferred CloudKit on one condition — adopt it if the container proves
insufficient behind the Local Store. That condition is now necessary but not
sufficient. CloudKit chooses its Development or Production database by how the
build is signed, so a development-signed build and a Developer ID build would
hold two separate histories. Pinning every build to Production through
`com.apple.developer.icloud-container-environment` may work, but it is not
documented for development-signed builds, and Production neither auto-creates
schema nor allows a field to be removed — so a pinned Debug build could not
experiment with a record shape without a Console deployment first.

Until that is settled, adopting CloudKit means breaking this requirement.

**The ubiquity container honours it for free.** The container identifier
`iCloud.glebglazov.vcdr` carries no environment, so every build reaches the same
folder of Record Files. This is one of the reasons the container remains the
transport.

**The export ledger cannot tell builds apart, and must not learn to.** A row in
the Local Store that still owes a Record File records nothing about which build
wrote it. Under a split-environment transport that would leak records both ways
and read as a bug. Under this requirement it is the behaviour we want, and the
seam that would separate them — documented at `FileHistoryStore.swift:309-311` —
stays closed on purpose.
