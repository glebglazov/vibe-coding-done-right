---
fragment: 031F4D82
generation: 0012
branch: master
---

+ Transcription Model Family
  A group of Transcription Models that share what they can be told — every Whisper is one family, Parakeet is its own. It is the unit Transcription Model Settings belong to, because a language hint or a vocabulary prompt is a property of the speech being transcribed rather than of which size of a model transcribes it.
  avoid: model group, model kind, provider, engine

~ Transcription Model Settings
  The settings one Transcription Model Family accepts, which no other family need accept — Whisper's language hint and free-text prompt, Parakeet's vocabulary boost. They are held in a store keyed by family, so switching between members of a family finds the same answers, and they survive the family being switched away from, switched back to, and its models being deleted.
  was: The settings one Transcription Model accepts, which no other model need accept — Whisper's language hint and free-text prompt, Parakeet's vocabulary boost. They are held in a store keyed by model, so they survive being switched away from, switched back to, and the model itself being deleted.
