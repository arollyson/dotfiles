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

Cyber-safety blocks retry on GLM automatically (see `refusal-fallback` below); nothing
else does. To work on GLM from the start, pick it with `/model`, or start a session on it:

```sh
omp --config "$HOME/.config/dotfiles/omp/security.yml"  # main roles on GLM; review unchanged
omp --model @security                                    # main model only (or @security-fast)
```

LiteLLM authenticates with `LITELLM_API_KEY` or `/login`; its endpoint comes from
`providers.litellm.baseUrl` in local `models.yml`, then `LITELLM_BASE_URL`.

## Extensions and rules

`/cache-status`, `/priority`, `/fork-tab`, `/branch-tab`, `/answer` (Ctrl+.),
`/find-session`, and `/gwt`.

- `refusal-fallback` retries a cyber-safety block (Anthropic refusal category
  `cyber`, OpenAI `cyber_policy`) on the `security` role's model instead of the
  normal fallback chain. Other refusals and ordinary failures keep the normal
  chain. omp's own retry does the switch, so a block it can't replay (for example
  after tool calls ran) isn't retried, and the session stays on GLM until omp
  reverts to the primary model. `tests/refusal-fallback.sh` checks it against a
  mock provider; it needs omp and node, so CI skips it.
- `/find-session` sends matching excerpts to the small model, so work content can leave the machine.
- `/gwt [task]` creates a worktree under `$PROJECT_HOME/worktrees` (default
  `~/dev/worktrees`); with a task it opens a PR but never merges.
- Rules: a reminder against pushing to the default branch, `no-sleep-wait`,
  which stops the main session sleeping to wait, and `no-aws-admin`, which
  stops any agent's `bash`/`eval` call that selects an `*admin*` AWS profile or
  assumes an `*Admin*` role. All three match command text, so indirection (a
  profile name in a variable, a script file) gets past them. They fire on every
  match only with `ttsr.repeatMode: after-gap` and `ttsr.repeatGap: 0`; omp's
  default fires each rule once per session.
- Employer-specific names (profiles, accounts, internal tools) stay out of this
  public repo: keep them in `~/.config/dotfiles-local/` and symlink them into
  `~/.omp/agent/rules/` (omp; `alwaysApply: true` for always-on guidance) and
  `~/.claude/rules/` (Claude Code). Stow leaves those files alone.
- Nothing commits or pushes configuration automatically.

## Hindsight memory

`memory.backend: hindsight` points omp at a local [Hindsight](https://github.com/vectorize-io/hindsight)
service on `localhost:8888`. omp recalls on the first turn and retains the session every
three turns; that text goes through the LiteLLM relay for fact extraction, and memories
stay in the `hindsight-data` Docker volume. Needs Docker and `LITELLM_BASE_URL`.

```sh
bash "$HOME/.config/dotfiles/omp/hindsight/setup-secrets.sh"  # prompts once for the relay key
docker compose -f "$HOME/.config/dotfiles/omp/hindsight/compose.yaml" up -d --wait
```

Secrets live in `~/.config/dotfiles-local/hindsight/` (`0700`, files `0600`); the script
generates the API token and dashboard key and never overwrites or prints them. Login
shells export the token as `HINDSIGHT_API_TOKEN`, so restart omp from a new shell. Check
with `/memory diagnose` and `/memory stats`; the dashboard is at `localhost:9999`.
`docker compose … down` keeps memories; `down --volumes` deletes them.
