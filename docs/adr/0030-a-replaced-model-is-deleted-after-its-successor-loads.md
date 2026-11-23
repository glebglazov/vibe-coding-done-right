# ADR-0030: A replaced Transcription Model is deleted after its successor loads

Adds to ADR-0018, which covers a model the person removes. When a release replaces a Transcription Model with a successor, as Parakeet Ultra replaces Parakeet v3, the person never asked for the old model to go, but nothing can use it again. The app deletes the old model's folders from the model root without asking, and only after the successor has loaded with no error, so a failed download or load always leaves the old model on disk. The successor gets its own key, and the old key is read as the successor's key wherever a stored key is read, so the Default, a Mode's override and family settings move to the successor with no prompt.

## Considered Options

- **Keep the old model until the person removes it.** Rejected: the Library no longer lists it, so the person cannot see or remove the ~500 MB it holds.
- **Keep transcribing with the old model while the successor downloads.** Rejected: more code for a change that runs once for each install. The next dictation waits for the download, as on a first install.
- **Keep the old key for the successor.** Rejected: a key would name a model that is gone. The cost of the new key is that an older build cannot read it (on the Mac, an older build drops every custom Mode when one Mode pins the new key).

## Consequences

During the replacement, the old and new models are both on disk until the new one loads. A downgrade over a replacement downloads the old model again.
