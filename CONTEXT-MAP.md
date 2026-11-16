# Context Map

This repository has multiple product contexts. Use this map to choose the
right glossary and ADR location before applying domain language or recording
architecture decisions.

## VCDR_IOS

Path: `vcdr-ios/`

Glossary: `vcdr-ios/CONTEXT.md`

ADRs: `vcdr-ios/docs/adr/`

Owns iOS-specific language for the main app, custom keyboard extension,
widgets, app-group communication, keyboard-driven recording, Hot Mic Session,
Keyboard Channel, Live Activity presence, and iOS Recording Run behavior.

## VCDR_MAC

Path: `vcdr-mac/`

Glossary: `vcdr-mac/CONTEXT.md`

ADRs: `vcdr-mac/docs/adr/`

Owns macOS-specific language for the menu bar app, hotkeys, capture panel,
Accessibility-based Cursor Context, transcription flow, and output delivery.

Create `vcdr-mac/CONTEXT.md` lazily when the first macOS-specific term is
resolved.

## SHARED

Path: `Shared/`

Glossary: `Shared/CONTEXT.md`

ADRs: `docs/adr/`

Owns language that is genuinely shared across products. Do not place a term
here unless it has the same meaning in both the iOS and macOS contexts.

Create `Shared/CONTEXT.md` lazily when the first shared term is resolved.

## EVALS

Path: `evals/`

Glossary: `evals/CONTEXT.md`

ADRs: `evals/docs/adr/`

Owns the language of prompt and model measurement — eval sets, arms, the run
ledger, fingerprints, and the two score axes. This is tooling language, not
product language: a term belongs here precisely because it means nothing to the
iOS or macOS product, and Shared's own rule keeps it out of Shared.
