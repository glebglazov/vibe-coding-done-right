# ADR-0029: Parakeet's settled text takes FluidAudio's seam repair

Narrows ADR-0022 for Parakeet. ADR-0022 says settled text is final. From FluidAudio 0.18, the sliding window can trim or re-join the last few words of its confirmed transcript where two windows meet, to remove words it duplicated or split at that seam (upstream issues #897, #912, #1113). We take that confirmed transcript as FluidAudio gives it. So on iOS, Parakeet's settled text is final except for its last words at a seam, and the live line always equals the text `finish()` returns.

## Considered Options

- **Settled text that only grows**, enforced in `ParakeetLiveSession`. Rejected: the live view would keep words that FluidAudio withdrew as duplicates, and the live line would no longer match the delivered transcript. ADR-0022 says these are one artifact.

## Consequences

A person can see a word at the end of the settled text change at a seam, as the volatile tail changes. Whisper's settling (ADR-0022's last-two-segments rule) does not change.
