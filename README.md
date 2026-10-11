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

## Installation

Clone the repository and run the unattended bootstrap:

```sh
git clone https://github.com/arollyson/dotfiles "$HOME/.dotfiles"
bash "$HOME/.dotfiles/bootstrap.sh"
```

The script works from any directory and exits after setup; it does not start
an interactive shell. It discovers or installs Homebrew, installs the
platform-compatible `Brewfile` dependencies, initializes Vim submodules, installs
the dotfiles, and sets the current account's login shell to Homebrew's Zsh.
Reruns retain local settings and avoid repeating an already-complete shell change.
Start a new login session after installation.

Prerequisites:

- Run as the intended non-root development account with a writable home directory.
  Homebrew does not support installation as root.
- Required privileged operations must already work with `sudo -n`. The bootstrap
  never asks for a password; it fails with an actionable error if access is missing.
- On macOS, install the Xcode Command Line Tools before unattended provisioning.
- Intel Macs use `/usr/local` and an Intel-capable pinned Homebrew installer;
  Apple Silicon and Linux use a separate pinned installer. Intel macOS is an
  upstream [Tier 3 configuration](https://docs.brew.sh/Installation#macos-requirements),
  so package availability and source builds remain subject to Homebrew's support policy.
- Fresh Linux Homebrew installation supports Debian/Ubuntu-style systems and
  installs its build prerequisites using `apt-get`. An existing Homebrew
  installation does not require `apt-get`.

For remote development templates that manage the login shell themselves:

```sh
bash "$HOME/.dotfiles/bootstrap.sh" --no-change-shell </dev/null
```

This still installs all dependencies and dotfiles, but leaves the account's
login shell unchanged. GUI casks are installed on macOS only.

For images that provision native packages themselves, install Git, GNU Stow,
Zsh, and jq first, then use config-only bootstrap:

```sh
bash "$HOME/.dotfiles/bootstrap.sh" --no-packages --no-shell </dev/null
```

This mode does not invoke Homebrew or package managers and also supports root
devcontainers. It attempts submodule initialization but warns rather than
aborting if that step fails offline. `--no-shell` aliases `--no-change-shell`.
Shell startup supports native packages without Homebrew; set
`DOTFILES_RUNTIME=native` to deliberately bypass an installed Homebrew too.

If dependencies are already installed and only dotfiles need updating:

```sh
bash "$HOME/.dotfiles/install.sh"
```

## Shared and machine-local settings

Stow installs the shared shell and Git configuration under
`~/.config/dotfiles/`. The files `~/.zprofile`, `~/.zshrc`, and `~/.gitconfig`
are regular files copied from `entrypoints/` on first installation, not
symlinks into this repository. Endpoint tools can edit them without changing
the shared dotfiles.

Optional machine-local settings live outside this repository:

| File | Purpose |
| --- | --- |
| `~/.config/dotfiles-local/env.zsh` | Environment variables, certificate trust, and local shell configuration |
| `~/.config/dotfiles-local/interactive.zsh` | Additional interactive shell settings |
| `~/.config/dotfiles-local/gitconfig` | Git identity, signing, certificate, and credential overrides |

These files are not required and do not need a separate repository.
Shared Git settings use the personal identity by default and configure Git LFS
plus PATH-resolved `gh` credential helpers for GitHub and gist. The bootstrap
installs both `git-lfs` and `gh`.

The local Git include follows the shared settings. Scalar overrides in the same
section take precedence; credential helper lists need an explicit reset. To replace the shared
GitHub or gist helper, add the matching `[credential "https://github.com"]` or
`[credential "https://gist.github.com"]` section to the local Git config, with an
empty `helper =` before your preferred helper. A later generic `[credential]`
helper alone does not replace the shared host-specific helper.

An explicit `--git-profile personal|work` selection is supported by both bootstrap
and the installer. `work` requires `user.email` directly configured in the regular
machine-local Git config above; `user.name` is optional. `personal` selects the
shared personal name and email. Selection persists across reruns in an
identity-only managed footer after the preserved local content in `~/.gitconfig`.
It overrides only name/email, not signing, trust, or credential configuration.
Without an explicit or previously saved selection, local identity overrides win.

The installer automatically adds or updates a marked shared-settings block in
existing regular entrypoint files, including a profile created by Homebrew.
Local content outside that block is retained byte-for-byte after shared settings,
so local overrides continue to win. No manual merging is needed for regular files.
Original entrypoints are backed up outside the checkout under
`~/.local/state/dotfiles/backups/` before changes.

Shared environment initialization runs once per shell. An optional local loader
ending with a false test does not disable interactive history, completion,
bindings, or Fzf; genuine shared Homebrew initialization failures are reported.
The minimal `.zshenv` establishes platform detection and unique PATH entries.
Shared environment settings load once through the managed `.zprofile`;
interactive `.zshrc.d/` fragments load aliases and native/Homebrew plugins after
base key bindings. Optional interactive machine-local settings run last.

Entrypoint symlinks and malformed managed blocks are rejected without overwriting
their contents. Stow conflicts also fail by default. `--backup` moves conflicting
regular local files to `~/.local/state/dotfiles/backups/install.*/stow/` before
installation, but refuses symlinks or paths resolving into the checkout.
When migrating an older symlink-based installation, preserve its local settings
outside the checkout and remove the old Stow links first. Do not use Stow's
`--adopt`: it would move local configuration into the repo.

## Shared agent instructions

`agents/.agents/AGENTS.md` is the single, harness-neutral source of development
standards. The `agents` Stow package links it to `~/.agents/AGENTS.md`, and each
harness reaches that one file:

| Harness | How it loads the standards |
| --- | --- |
| Omp | Natively, as user context from `~/.agents/AGENTS.md`. A `~/.omp/agent/AGENTS.md` would shadow it, so do not create one. |
| Claude Code | `claude/.claude/CLAUDE.md` is a relative link to the shared file. Claude reads `AGENTS.md` automatically only at project scope; its user-level file is still `~/.claude/CLAUDE.md`. |

Keep harness-specific guidance out of the shared file. Claude-only model routing
and tool/worktree conventions live in `claude/.claude/rules/`; Omp uses its own
search tools, model roles, and task isolation.

## Claude configuration privacy

Claude configuration is installed with Stow's `--no-folding`: `~/.claude` remains
a real directory, with only the shared configuration files linked into it.
Existing credentials, sessions, and other runtime files remain outside this
repository. A symlinked or folded `~/.claude` directory is rejected rather than
adopted.

Claude-only guidance lives in user-level rules that Claude Code loads
automatically: `rules/model-routing.md` (model and subagent routing) and
`rules/claude-code-workflow.md` (`rg`/`fd`/`ast-grep` CLI search and per-subagent
`wt` worktrees).

Both bootstrap and direct installation register the required `strip-automode`
Git filter in this checkout. Its clean step removes `.autoMode` from the staged
`claude/.claude/settings.json` while retaining it in the working file; its smudge
step is a passthrough so checkouts and pulls of that file still work. This keeps
local network layout, hostnames, and private repository references out of commits.
A pre-commit hook checks the staged JSON as a backstop; `.gitignore` allowlists
only the intended shared Claude files.

## Migrating legacy work settings

The old `zsh/.zprofile.d/env.work` path stays permanently ignored, so routine
`git add -A` cannot accidentally include it. Ordinary installation warns if that
file exists, leaves it unchanged, and neither installs nor sources it.

After preserving any edited shell/Git settings outside the checkout and removing
old entrypoint Stow links as described above, explicitly migrate the legacy file:

```sh
bash "$HOME/.dotfiles/install.sh" --migrate-local </dev/null
```

This moves its settings into `~/.config/dotfiles-local/env.zsh`. If that file
already exists, legacy settings are placed first and existing local settings
remain last, so current overrides win. Both originals are backed up under
`~/.local/state/dotfiles/backups/install.*/` before publication. File permissions
are retained for a new destination; a combined file is no more permissive than
either original. The old file is removed only after successful publication, and
reruns do not duplicate settings. Symlink inputs and destinations inside the
checkout are rejected without overwriting local configuration.

## Omp configuration

Portable preferences and extensions are managed by the `omp` Stow package.
The authored extensions and generic push reminder are adapted from
[Brannon Dorsey's configuration](https://github.com/brannondorsey/omp-config)
with permission for public reuse. His work MCP connections, internal endpoints,
work rules, memory service, and automatic configuration commit/push policy are
not imported.

### Settings ownership

`~/.omp/agent` and its resource directories stay real directories, never links
into this repository. Installation links only reviewed extensions, the readable
theme, and the rules. Writable configuration, authentication, databases,
sessions, caches, and generated skills remain outside Git. User context comes
from the shared `~/.agents/AGENTS.md` described above.

| Public blueprint | Local writable configuration |
| --- | --- |
| `omp/.config/dotfiles/omp/preferences.yml` | `~/.omp/agent/config.yml` or existing `config.yaml` |
| `omp/.config/dotfiles/omp/models.yml` | `~/.omp/agent/models.yml` or existing `models.yaml` |
| `omp/.config/dotfiles/omp/lsp.json` | `~/.omp/agent/lsp.json` |

Normal bootstrap/install seeds missing configuration only; reruns leave existing
settings alone. Legacy JSON or runtime settings are not shadowed by a new YAML
seed. The generic LSP blueprint declares Python, TypeScript, and Rust servers,
but does not install or launch their executables.

After editing the public preferences, explicitly apply them:

```sh
bash "$HOME/.dotfiles/omp-sync.sh"
```

Or combine installation and explicit synchronization:

```sh
bash "$HOME/.dotfiles/bootstrap.sh" --sync-omp
# Config-only image with dependencies provisioned:
bash "$HOME/.dotfiles/bootstrap.sh" --no-packages --no-shell --sync-omp </dev/null
```

Sync requires Omp, jq, and Mike Farah yq v4; jq/yq are already in the Brewfile.
It targets the canonical default profile only, not named profiles, project
settings, or overlays. Native Omp migrates legacy settings before sync; legacy
private model definitions are preserved when creating YAML overrides. Unknown
roles, private provider/header fields, and unrelated settings are retained.
Existing files are backed up under `~/.local/state/dotfiles/backups/omp-sync.*/`
before preference/cap changes. Matching reruns do not rewrite files or create
another backup.

Use `/settings` normally: it writes the regular local config, not the public
blueprint. Changes remain local across normal installation reruns; explicit sync
reapplies the selected repo-owned preferences. Existing model-specific or provider
wildcard fallback chains take precedence over role chains and are preserved.

### Selected models and UI

| Workload | Model | Effort |
| --- | --- | --- |
| Primary, planning, deep work, general task agents | Claude Opus 5.5 | high |
| Code review, including the `security-reviewer` agent | GPT-6 Astra | high |
| Small tasks, scouts, mechanical tasks, tiny helpers | GPT-6 Luna | low |
| Background advisor | GPT-6.1 Sol | medium |
| Explicit security work (`security` role) | GLM 5.3 via LiteLLM | high |
| Explicit fast security work (`security-fast` role) | GLM 5.3 Flash via LiteLLM | low |

The installed catalog has no GPT-6.1 Luna; the small role explicitly uses GPT-6
Luna. Model selections live in the blueprint, not embedded in custom agent
prompts. Normal fallbacks first try a LiteLLM capacity relay of the same model,
then the earlier cross-provider fallback, then that fallback's relay:

| Roles | Fallback chain |
| --- | --- |
| Primary, planning, slow, task | Opus relay → GPT-6.1 Sol (high) → Sol relay |
| Review | Astra relay → Opus (high) → Opus relay |
| Small, tiny | Luna relay → Sonnet (low) → Sonnet relay |
| Advisor | Sol relay → Sonnet (medium) → Sonnet relay |

Relay entries have no effort suffix and inherit the failing turn's effort. A relay
is another route to the same model family, not an independent quota pool or a
way around provider guardrails; it may share upstream limits and policies. No
normal chain contains GLM. The `security` role falls back only to Flash and
`security-fast` only to full GLM; neither falls back to Claude or GPT. One-shot
extension completions use the small role with low effort; they are not the full
agent retry loop.
Planning, slow work, and general task roles follow `@default`, so changing the
configured primary also changes those roles.

The advisor uses the three-turn backlog policy. The existing `cyberpunk-readable`
theme and Claude-shaped composer are retained, thinking blocks are hidden
(Ctrl+T toggles them and saves the choice), and memory/autolearning are off.
Exact Claude 5-family overrides use a 400k context budget; the inherited Haiku 4.5
overrides use 150k. Future model releases require explicit overrides after checking
their real context limits.

### GLM security sessions

**Refusals do not automatically switch normal sessions to GLM.** Select a GLM
model with `/model` and repeat the request. Ordinary refusal prose does not
trigger retry; GLM and its gateway can also refuse or filter requests.

The public `litellm/...` selectors are model names, not credentials. Omp's built-in
LiteLLM provider uses `LITELLM_API_KEY` or saved `/login` credentials. Its endpoint
comes from local `providers.litellm.baseUrl` in `models.yml`, then
`LITELLM_BASE_URL`, then localhost. Keep private URLs and authentication out of
this repository. An exported shell URL is sufficient when Omp inherits it;
pin the URL in local `models.yml` for launches that do not inherit that environment.

Start a security session with the per-run overlay. It routes the primary,
planning, slow, and general task roles to `@security`, scouts, mechanical
workers, and tiny helpers to `@security-fast`, and keeps their fallbacks within
GLM. It is a read-only layer for that process, never seeded into `config.yml`.

```sh
# After installation links the overlay:
omp --config "$HOME/.config/dotfiles/omp/security.yml"
# From the checkout before installation:
omp --config "$HOME/.dotfiles/omp/.config/dotfiles/omp/security.yml"
```

To change only the main model, select either role directly:

```sh
omp --model @security        # full GLM, high effort
omp --model @security-fast   # GLM Flash, low effort
```

Review routes are unchanged in both cases: `reviewer` and `security-reviewer`
stay on `@review` (Astra, falling back to its relay and then Opus), and the
advisor keeps Sol. Select Fable manually for a review when wanted, for example
with the session-only Alt+P task model pick. The overlay is not a model preset;
`/modelpreset switch` clears roles a preset omits.

### Extensions and private configuration

- Shared status row, passive cache evidence, and `/cache-status`.
- `/priority high|medium|low|clear` and shortcuts; mirrors priority onto cmux.
- `/fork-tab` and `/branch-tab`; cmux/tmux integration, with manual launch guidance
  outside those terminals.
- `/answer` and Ctrl+.; extracts questions using the small model and collects answers.
- `/find-session`; searches local history and sends bounded candidate metadata and
  matching excerpts to the small model for ranking. Work excerpts can leave the
  machine. Review provider/data policy before using it on sensitive sessions.
- `/gwt`; creates a worktree under `$PROJECT_HOME/worktrees` (default `~/dev/worktrees`).
  With no task it stops after worktree creation. With a task it requests implementation,
  verification, a commit, branch push, and a PR; it never requests a merge.

The generic default-branch push reminder is advisory, not branch protection.
It does not authorize publication. No extension automatically commits or pushes
configuration changes.

The `no-sleep-wait` rule interrupts main-session `bash`/`eval` calls that sleep to
wait (`sleep N`, `time.sleep`, `asyncio.sleep`, `Bun.sleep`, `setTimeout` promises)
and redirects them to async jobs, ready-checked services, or a watching `task`
subagent; subagents may still poll. Matching is incomplete, and with the default
`ttsr.repeatMode: once` it fires at most once per session.

Keep MCP definitions in the native, machine-local `~/.omp/agent/mcp.json`, and work
settings/endpoints in regular local Omp configuration or the existing private
shell environment hook. Do not add them to public blueprints. Omp's authentication
storage and environment variables remain the credential sources.
The package's deny-by-default `.gitignore` permits only the reviewed public files,
not unknown extensions, MCP, settings, auth, or future runtime state.

## Verification

After installing dependencies:

```sh
bash tests/install.sh
bash tests/bootstrap.sh
bash tests/startup.sh
bash tests/git.sh
bash tests/omp.sh
bash tests/run.sh
```

The tests use temporary home directories. Bootstrap regression tests isolate
package, network, account, and privilege commands; they do not change the host's
packages or login shell. The startup regression uses real Zsh and Fzf to exercise
terminal-less automation and Ctrl-R widget initialization in a real pseudo-terminal.
The Git regression exercises real Git, Git LFS, and `gh` with local repositories
and synthetic credentials; it does not authenticate against remote services.
The native integration suite (`tests/run.sh`) also covers config-only bootstrap,
identity precedence, Claude runtime privacy, backups, and installer regressions.
Omp regressions cover local configuration ownership, private-field preservation,
legacy settings, and sync idempotence using the native Omp CLI when installed.
They never start a session or connect to MCP; native sync cases are explicitly
skipped when Omp is unavailable. CI provisions yq v4 and runs the native integration
suite on macOS/Linux, plus the repository lint hooks.

Install the hooks with `prek install`; run them with `prek run --all-files`.
They check shell syntax, ShellCheck, formatting, merge markers, secrets, workflow
safety, and the staged Claude privacy invariant.
