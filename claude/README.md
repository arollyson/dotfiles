# claude

Claude Code user configuration.

- `~/.claude/CLAUDE.md` links to the shared [`AGENTS.md`](../agents/README.md).
- Claude-only rules (model routing, search tools, worktrees) live in `.claude/rules/`.
- `~/.claude` stays a real directory; only these shared files are linked into it,
  so credentials and sessions never enter the repo.
- The installer registers a `strip-automode` Git filter (needs jq) that keeps
  `.autoMode` out of committed `.claude/settings.json`.
