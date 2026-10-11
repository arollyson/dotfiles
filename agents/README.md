# agents

`.agents/AGENTS.md` is the shared, harness-neutral instructions file, linked to
`~/.agents/AGENTS.md`.

- omp reads it directly. Don't create `~/.omp/agent/AGENTS.md`; it would hide this file.
- Claude Code reads it through `~/.claude/CLAUDE.md` (see [claude](../claude/README.md)).
- Keep tool-specific guidance in that tool's package, not here.
