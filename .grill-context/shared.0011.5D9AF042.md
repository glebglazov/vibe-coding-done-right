---
fragment: 5D9AF042
generation: 0011
branch: master
---

+ Transcription Model
  The on-device audio model that turns a recording's speech into text, before any AI processing runs. Distinct from the AI model that processes the text afterwards: it is a concern of the recording run rather than of the processing recipe.
  avoid: ASR model, speech model, audio provider, transcription engine

+ Transcription Model Settings
  The settings one Transcription Model accepts, which no other model need accept — Whisper's language hint and free-text prompt, Parakeet's vocabulary boost. They are held in a store keyed by model, so they survive being switched away from, switched back to, and the model itself being deleted.
  avoid: transcription options, model config, model parameters

+ Default Transcription Model
  The Transcription Model a recording run uses when nothing overrides it. There is exactly one per device, it is always installed, and it is what stays resident. It does not sync between devices, because the models it names are per-device.
  avoid: global model, fallback model, active model

+ Transcription Model Library
  The set of Transcription Models installed on this device, which a person adds to and removes from. Its membership differs per platform, because a platform only offers models its own transcription path can drive — macOS transcribes a finished recording, where iOS drives a live view. A model may be removed unless it is the Default Transcription Model or something names it; removal is refused rather than silently repointing whatever used it.
  avoid: model list, model manager, downloads

+ Transcription Model Capability
  What one Transcription Model declares it can be told, typed by kind rather than as a list of string options — a language hint, a free-text prompt, a vocabulary boost. Two Transcription Models differ in which kinds they declare, not merely in the values they accept, which is why Mode Parameter cannot express this.
  avoid: model option, transcription parameter, model feature

+ Language Hint
  A Transcription Model Capability that names the language a recording is in. It is a decoder input rather than a preference: a hint that does not match the speech makes Whisper translate into the hinted language instead of transcribing, with plausible text and no error. It therefore has a detect value meaning "send nothing", and is never set from a guess.
  avoid: primary language, language preference, locale setting
