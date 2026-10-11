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

## Packages

`install.sh` links these Stow packages into `~`. Tool-specific notes live in the
package's own README.

| Package | Contents |
| --- | --- |
| `zsh`, `git`, `tmux`, `vim` | Shared shell, Git, tmux, and Vim configuration |
| [`agents`](agents/README.md) | Shared `AGENTS.md` for coding agents |
| [`claude`](claude/README.md) | Claude Code configuration |
| [`omp`](omp/README.md) | omp configuration |

`entrypoints/` holds the templates copied to `~/.zprofile`, `~/.zshrc`, and `~/.gitconfig`.

## Tests

Tests use temporary home directories and never touch host packages or the login shell.

```sh
bash tests/run.sh
prek install && prek run --all-files
```
