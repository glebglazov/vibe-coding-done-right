# ADR-0022: A chunked re-decoding live view settles all but its last two segments

## Status

Accepted. Settles what
[ADR-0021](0021-the-ios-library-becomes-plural.md) left open.

## Context

iOS has one path a recording takes: the live view. Parakeet drives it through
FluidAudio's sliding window, which already reports its answer in two parts —
text it has confirmed and will not revisit, and a volatile tail the next window
may rewrite. A person watching the screen sees words appear, wobble for a
moment, then stop moving.

Whisper has no such window. WhisperKit reaches a live view by decoding the
audio captured so far *from scratch*, again, every second or so. Every word it
has emitted is therefore still in play at every pass: a wider window
re-punctuates, re-splits and occasionally rewords what the previous decode
produced. Shown raw, that is a view where finished sentences twitch while a
person is still talking — visibly a different app from the one Parakeet drives,
for a reason nobody watching could explain.

[ADR-0021](0021-the-ios-library-becomes-plural.md) recorded that iOS would run
Whisper and explicitly did not settle this. That is the decision here.

## Decision

A chunked re-decoding session holds back the **last two segments** of each
decode as its volatile tail and settles everything behind them. Settled text is
final: it is never re-emitted and never rewritten.

What makes that promise keepable is that settling also moves the decode window.
Each pass records the timestamp its settled text ends at and clips the next
decode to start there, so the audio behind the settled text is no longer in the
window that could rewrite it. The clip is not an optimisation that happens to
help; it is the mechanism.

Two segments, because the last one is mid-utterance by construction and the one
before it is what a wider window most often re-punctuates or re-splits. This is
also the count WhisperKit's own streaming reference holds back.

The transcript a run delivers is the settled text plus one final decode of the
audio past the settled point, taken with nothing held back once the recording
has stopped. The live view and the transcript are one artifact, not two answers
to the same recording.

## Consequences

Both families now speak the same two-part shape to the live view — settled
text and a volatile tail — so the view has no idea which model is running and
cannot behave differently because of it. Parakeet reports the two directly;
Whisper is made to produce them.

Settling is a bet, not a proof. A decode clipped at the settled point can no
longer fix a word it settled early, so an occasional wrong word survives into
the transcript where an unclipped re-decode might have corrected it. That is
the price of a view that does not rewrite itself, and it is the same bet
Parakeet's window already makes.

Whisper's live view lags by roughly the volatile tail: two segments of speech
are on screen but not yet committed at any moment. A person reads them as the
sentence they are still speaking, which is what they are.

The reconciliation is a value type over decoded segments and their end
timestamps, with no transcription backend in it, so what the view settles and
when can be tested without a model loaded.
