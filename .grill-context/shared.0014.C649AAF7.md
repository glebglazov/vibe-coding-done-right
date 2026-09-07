---
fragment: C649AAF7
generation: 0014
branch: master
---

~ Transcription Model Library
  Every Transcription Model this platform offers, each with the state it is in on this device — not installed, downloading, installed, ready, or beyond this device's reach. It is never shortened: a model whose installability is not known yet is a row that says so. It is also the one surface a person installs a model from and removes one from, and a model may be removed unless it is the Default Transcription Model or something names it.
  was: The set of Transcription Models installed on this device, which a person adds to and removes from. Its membership differs per platform, because a platform only offers models its own transcription path can drive — macOS transcribes a finished recording, where iOS drives a live view. A model may be removed unless it is the Default Transcription Model or something names it; removal is refused rather than silently repointing whatever used it.
  avoid: model list, model manager, downloads, installed models

+ Installed Model
  A member of the Transcription Model Library whose files are on this device. It is the only thing a model select offers, beside the value that select already holds: a pick is a choice among what is here, and never starts a download.
  avoid: downloaded model, available model, present model

~ Default Transcription Model
  The Transcription Model a recording run uses when nothing overrides it. There is exactly one per device, it is chosen from the Installed Models, and it is what stays resident. It is always installed, and stays so because removing it is refused: to remove the model that holds it, install another and make that one the Default first. The one install the app does unasked is this model on a device whose Library is empty. It does not sync between devices, because the models it names are per-device.
  was: The Transcription Model a recording run uses when nothing overrides it. There is exactly one per device, it is always installed, and it is what stays resident. It does not sync between devices, because the models it names are per-device.
  avoid: global model, fallback model, active model

+ Declared Install Size
  What one Transcription Model costs on this device, written down in the app rather than asked of a backend, because no transcription backend publishes it. It is bytes on disk after the install and not bytes downloaded, so the number a person reads before an install is the same measure as the number the Library shows after one. It is approximate, and every model carries one.
  avoid: download size, model size, weight

+ Model Installability
  Whether this device can run one Transcription Model, which only the transcription backend can answer and only over the network. It has three values, not two: yes, no, and not known yet — a device that was offline does not know what it can run, which is not the same as knowing it cannot. Only a definite answer is remembered between launches, and every absent model is asked again in the background at each launch.
  avoid: model support, device support, compatibility
