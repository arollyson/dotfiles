```
      ██            ██     ████ ██  ██
     ░██           ░██    ░██░ ░░  ░██
     ░██  ██████  ██████ ██████ ██ ░██  █████   ██████
  ██████ ██░░░░██░░░██░ ░░░██░ ░██ ░██ ██░░░██ ██░░░░
 ██░░░██░██   ░██  ░██    ░██  ░██ ░██░███████░░█████
░██  ░██░██   ░██  ░██    ░██  ░██ ░██░██░░░░  ░░░░░██
░░██████░░██████   ░░██   ░██  ░██ ███░░██████ ██████
 ░░░░░░  ░░░░░░     ░░    ░░   ░░ ░░░  ░░░░░░ ░░░░░░

personal dotfiles managed with GNU stow
```

Zsh, Git, tmux, Vim, Claude Code, and omp configuration.

## Install

```sh
git clone https://github.com/arollyson/dotfiles "$HOME/.dotfiles"
bash "$HOME/.dotfiles/bootstrap.sh"
```

Installs Homebrew and the `Brewfile`, initializes Vim submodules, links the
dotfiles, and sets Homebrew's Zsh as the login shell. Reruns are safe; open a new
login session afterwards.

- Run as your normal (non-root) user. Any sudo it needs must already work with
  `sudo -n`; it never prompts.
- macOS needs the Xcode Command Line Tools. A fresh Linux Homebrew install needs `apt-get`.

```sh
bash "$HOME/.dotfiles/bootstrap.sh" --no-shell </dev/null               # keep the login shell
bash "$HOME/.dotfiles/bootstrap.sh" --no-packages --no-shell </dev/null # deps preinstalled (Git, Stow, Zsh, jq); works as root
bash "$HOME/.dotfiles/install.sh"                                       # relink dotfiles only
```

Both scripts also take `--backup` (move conflicting files aside instead of
failing), `--git-profile personal|work`, `--migrate-local`, and `--sync-omp`.
`DOTFILES_RUNTIME=native` makes the shell skip Homebrew.

## Local settings

`~/.zprofile`, `~/.zshrc`, and `~/.gitconfig` are regular files, not symlinks.
The installer maintains a `dotfiles managed` block in each; anything after it
loads later and wins. Changed files are backed up to `~/.local/state/dotfiles/backups/`.

| Optional file | Use |
| --- | --- |
| `~/.config/dotfiles-local/env.zsh` | Environment variables, certificates |
| `~/.config/dotfiles-local/interactive.zsh` | Interactive shell settings |
| `~/.config/dotfiles-local/gitconfig` | Git identity, signing, credentials |

- `--git-profile work` needs `user.email` in the local gitconfig. The choice persists.
- To replace the shared `gh` credential helper, add `[credential "https://github.com"]`
  (or `https://gist.github.com`) with an empty `helper =` line before yours.
- From an old symlink-based install: move local edits out of the checkout and
  remove the old Stow links first. Never use `stow --adopt`; it moves local files into the repo.

The legacy `zsh/.zprofile.d/env.work` is ignored until you migrate it into
`env.zsh` (existing `env.zsh` settings stay last and win):

```sh
bash "$HOME/.dotfiles/install.sh" --migrate-local </dev/null
```

## Agent instructions and Claude

- `agents/.agents/AGENTS.md` is the shared, harness-neutral instructions file,
  linked to `~/.agents/AGENTS.md`. omp reads it directly; don't create
  `~/.omp/agent/AGENTS.md`, which would hide it.
- `~/.claude/CLAUDE.md` links to the same file. Claude-only rules live in `claude/.claude/rules/`.
- `~/.claude` stays a real directory; only shared config files are linked into it.
- The installer registers a `strip-automode` Git filter (needs jq) that keeps
  `.autoMode` out of committed `claude/.claude/settings.json`.

## omp

The installer seeds each blueprint into `~/.omp/agent/` only if the file is missing.
`/settings` changes stay local.

| Blueprint (`omp/.config/dotfiles/omp/`) | Local file |
| --- | --- |
| `preferences.yml` | `~/.omp/agent/config.yml` |
| `models.yml` | `~/.omp/agent/models.yml` |
| `lsp.json` | `~/.omp/agent/lsp.json` (servers not installed) |

Reapply blueprint edits (needs omp, jq, and yq v4; backs up first):

```sh
bash "$HOME/.dotfiles/omp-sync.sh"
```

Keep MCP servers in `~/.omp/agent/mcp.json` and credentials or private endpoints
in local config, never in this repo.

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

Extension commands: `/cache-status`, `/priority`, `/fork-tab`, `/branch-tab`,
`/answer` (Ctrl+.), `/find-session`, and `/gwt`.

- `/find-session` sends matching excerpts to the small model, so work content can leave the machine.
- `/gwt [task]` creates a worktree under `$PROJECT_HOME/worktrees` (default
  `~/dev/worktrees`); with a task it opens a PR but never merges.
- Nothing commits or pushes configuration automatically.

## Tests

Tests use temporary home directories and never touch host packages or the login shell.

```sh
bash tests/run.sh                     # also: install, bootstrap, startup, git, omp
prek install && prek run --all-files
```
