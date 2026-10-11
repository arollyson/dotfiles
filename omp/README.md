# omp

Settings blueprints, extensions, rules, and theme for [omp](https://omp.sh).

The installer seeds each blueprint into `~/.omp/agent/` only if the file is missing,
so `/settings` changes stay local.

| Blueprint (`.config/dotfiles/omp/`) | Local file |
| --- | --- |
| `preferences.yml` | `~/.omp/agent/config.yml` |
| `models.yml` | `~/.omp/agent/models.yml` |
| `lsp.json` | `~/.omp/agent/lsp.json` (servers not installed) |

Reapply blueprint edits (needs omp, jq, and yq v4; backs up first), or pass
`--sync-omp` to `bootstrap.sh`/`install.sh`:

```sh
bash "$HOME/.dotfiles/omp-sync.sh"
```

Keep MCP servers in `~/.omp/agent/mcp.json` and credentials or private endpoints
in local config, never in this repo.

## Models

| Role | Model |
| --- | --- |
| default, plan, slow, task | Claude Opus 5.5 (high) |
| review, `security-reviewer` | GPT-6 Astra (high) |
| smol, tiny | GPT-6 Luna (low) |
| advisor | GPT-6.1 Sol (medium) |
| `security` / `security-fast` | GLM 5.3 / GLM 5.3 Flash via LiteLLM |

A refusal does not switch to GLM. Pick it with `/model`, or start a session on it:

```sh
omp --config "$HOME/.config/dotfiles/omp/security.yml"  # main roles on GLM; review unchanged
omp --model @security                                    # main model only (or @security-fast)
```

LiteLLM authenticates with `LITELLM_API_KEY` or `/login`; its endpoint comes from
`providers.litellm.baseUrl` in local `models.yml`, then `LITELLM_BASE_URL`.

## Extensions and rules

`/cache-status`, `/priority`, `/fork-tab`, `/branch-tab`, `/answer` (Ctrl+.),
`/find-session`, and `/gwt`.

- `/find-session` sends matching excerpts to the small model, so work content can leave the machine.
- `/gwt [task]` creates a worktree under `$PROJECT_HOME/worktrees` (default
  `~/dev/worktrees`); with a task it opens a PR but never merges.
- Rules: a reminder against pushing to the default branch, and `no-sleep-wait`,
  which stops the main session sleeping to wait. Both are advisory.
- Nothing commits or pushes configuration automatically.
