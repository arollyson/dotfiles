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

Linux and macOS. Homebrew is optional.

## Install

```sh
git clone --recurse-submodules https://github.com/<you>/.dotfiles ~/.dotfiles
cd ~/.dotfiles
./bootstrap.sh
```

In a devcontainer, CI, or anywhere you only want the configs:

```sh
./bootstrap.sh --no-packages --git-profile work
```

`--no-packages` skips Homebrew and the Brewfile entirely and only links configs.
It needs `stow` and `git` on PATH; nothing else.

| flag | effect |
|------|--------|
| `--no-packages` | Link configs only; no Homebrew, no Brewfile |
| `--git-profile personal\|work` | Pick the git identity non-interactively |
| `--no-shell` | Don't try to make zsh the login shell |

Reruns are idempotent.

## Layout

```
git/        .gitconfig + per-identity fragments
tmux/       .tmux.conf
vim/        .vimrc and a native-pack colorscheme submodule
zsh/        .zshenv .zprofile .zshrc and their fragment dirs
```

### zsh load order

| file | scope | holds |
|------|-------|-------|
| `.zshenv` | every zsh | platform detection, `typeset -U path` |
| `.zprofile` | login | PATH, exported vars, Homebrew discovery |
| `.zprofile.d/os.*` | login | per-OS environment |
| `.zprofile.d/env.*` | login | per-environment vars (`env.work` is gitignored) |
| `.zshrc` | interactive | history, completion, keybindings |
| `.zshrc.d/*.zsh` | interactive | aliases, then plugins |

`.zshrc` sources `.zprofile` only when a login shell hasn't already done so, so
PATH is built exactly once either way.

Plugins are looked up across Homebrew, Debian/Ubuntu and Arch locations. A
plugin that isn't installed is skipped silently rather than erroring, which is
what keeps the config usable on hosts without Homebrew.

## Hooks

Linting runs through [prek](https://github.com/j178/prek) using
`.pre-commit-config.yaml`. CI runs the same hooks, so a clean local run means a
clean CI lint.

```sh
prek install                      # once per clone
prek run --all-files              # check everything
prek auto-update --cooldown-days 7
```

Covered: shellcheck and shfmt on bash, `zsh -n` on every zsh fragment,
actionlint and zizmor on workflows, gitleaks on staged changes, plus whitespace,
line-ending, case-conflict and symlink hygiene.

## Tests

```sh
./tests/run.sh
```

Installs into a throwaway `HOME` and checks the result: symlinks land, reruns
are idempotent, both login and interactive shells start silently with no
Homebrew present, `PATH` has no duplicates, the git identity resolves, vim
loads, and a stow conflict aborts without clobbering anything.

CI runs this same script on Linux and macOS, so a clean local run means a clean
CI run apart from the macOS leg.

## Git identity

`~/.gitconfig` includes `~/.gitconfig_user`, which `bootstrap.sh` writes to
point at `.gitconfig_personal` or `.gitconfig_work`. Switch later by editing
that one file, or rerun `./bootstrap.sh --git-profile <name>`.

## Machine-local secrets

Anything host-specific goes in `~/.zprofile.d/env.work`, which is gitignored.
