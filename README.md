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

## Claude configuration privacy

Claude configuration is installed with Stow's `--no-folding`: `~/.claude` remains
a real directory, with only the shared configuration files linked into it.
Existing credentials, sessions, and other runtime files remain outside this
repository. A symlinked or folded `~/.claude` directory is rejected rather than
adopted.

Both bootstrap and direct installation register the required `strip-automode`
Git clean filter in this checkout. It removes `.autoMode` from the staged
`claude/.claude/settings.json` while retaining it in the working file. This keeps
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

## Verification

After installing dependencies:

```sh
bash tests/install.sh
bash tests/bootstrap.sh
bash tests/startup.sh
bash tests/git.sh
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
CI runs that suite on macOS and Linux, plus the repository lint hooks.

Install the hooks with `prek install`; run them with `prek run --all-files`.
They check shell syntax, ShellCheck, formatting, merge markers, secrets, workflow
safety, and the staged Claude privacy invariant.
