# ADR-0023: A model select offers only installed models

## Status

Accepted. Amends [ADR-0021](0021-the-ios-library-becomes-plural.md).

## Context

Every model select in both apps offered the whole platform catalogue — the
Default Transcription Model picker and each Mode's or Prompt Mode's
Transcription Override picker — and a pick started a download. That was
deliberate: `override(_:naming:)` installed the model it named "so first use is
warm rather than a download that runs while the person is speaking", and the
Override screen carried a Library row purely to show the fetch it had begun.

The cost is that a select does two jobs with one gesture. A person reading a
list of seven names cannot tell which of them are on the device, what the next
one costs, or that the pointer they are about to move will also spend 1.6 GB.
The Transcription Model Library already exists as the surface for installing
and removing, with each model's state and progress on its own row; the selects
were a second, silent way to install, with no progress and no consent.

## Decision

A model select offers the Installed Models, plus the value it already holds.
A pick is a choice among what is on the device and never starts a download.
Installing and removing belong to the Library alone.

Two rules keep that honest:

- **The Default Transcription Model cannot be uninstalled.** Removal is already
  refused for the Default and for any model a Mode names
  ([ADR-0018](0018-a-transcription-model-may-be-removed-unless-something-names-it.md)),
  and that refusal is what guarantees a select always has at least one thing to
  offer. **Amended by [ADR-0024](0024-a-pinned-model-is-removed-with-consent-only-the-default-is-refused.md):**
  only the Default half of that refusal remains; a model Modes pin is removable
  with consent. The guarantee this rule rests on is unaffected. To reclaim the space the Default holds, install another model, make it
  the Default, and then remove the first.
- **A device with an empty Library installs the shipped Default once.** This is
  the one install the app does unasked, because a fresh device has no
  alternative to offer. It is a first-run install, not a pick.

## Consequences

The Library row on the Override screen goes away — it existed only to narrate a
download the pick started, and there is no such download now.

A person who wants a model a Mode does not yet have must visit the Library
first. That is one more step than before, and it is the price of a select that
tells the truth about what it will do.

Because a select can only name an Installed Model, the Default is always
installed, and the app never has to decide what to record with when a stored
choice points at nothing. The one path that can still empty the model root is
outside the app — a manual delete, or an install that stopped part-way. Nothing
special handles it: the recording proceeds and the wait is narrated where it is
met, which is the rule dictation already follows for an unready model
([ADR-0006](0006-recording-is-never-refused-for-an-unready-model.md)).

Each model now declares its install size in the app, because no transcription
backend publishes one, and a person choosing what to install is choosing by
that number. The Library shows it on every model that is not installed; a
select shows no sizes, since a select spends nothing.
