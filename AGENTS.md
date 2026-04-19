# AGENTS.md

Guidance for AI coding agents working on this repository. This file is an index — the actual content lives in [`docs/`](./docs/).

## Architecture

- [Project Overview](./docs/architecture/overview.md) — tech stack, build command, project structure
- [Architecture Rules](./docs/architecture/rules.md) — the 10 non-negotiable rules (no god objects, no singletons, no magic numbers, …). **Read this before writing code.**
- [Workflows, Permissions & Gotchas](./docs/architecture/workflows.md) — how to add a new action/provider/hotkey, required permissions, known timing pitfalls

## Runtime

If you are in a folder /workspaces, most likely, you are in containerized environment. If it is so, use REAL_PWD env variable to work with path-based MCPs
