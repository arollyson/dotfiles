#!/usr/bin/env bash
#
# Install these dotfiles on Linux or macOS.
#
# The package install and the config linking are independent: --no-packages
# links configs only, which is what devcontainers and locked-down hosts want.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STOW_PACKAGES=(git tmux vim zsh)

# Stowed with --no-folding. ~/.claude holds credentials, session transcripts
# and gigabytes of job state; if stow folds the directory then ~/.claude itself
# becomes a symlink into this repo and Claude writes all of that into version
# control. Unfolded, only the named config files are linked.
NO_FOLD_PACKAGES=(claude)

# Pinned so a compromised upstream installer cannot silently change what runs.
# Bump deliberately: https://github.com/Homebrew/install/commits/master
BREW_INSTALLER_REF=b9990527570f7e07d5393f37447b8293ec0a78de

install_packages=1
git_profile=""
set_shell=1

if [[ -t 1 ]]; then
  C_INFO=$'\033[0;32m' C_WARN=$'\033[0;33m' C_ERR=$'\033[0;31m' C_OFF=$'\033[0m'
else
  C_INFO="" C_WARN="" C_ERR="" C_OFF=""
fi

log() { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
warn() { printf '%s==>%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./bootstrap.sh [options]

Options:
  --no-packages         Link configs only; skip Homebrew and all package installs.
                        Use this in devcontainers and CI.
  --git-profile NAME    Select the git identity to include (personal | work).
                        Prompts when omitted on a terminal.
  --no-shell            Don't try to make zsh the login shell.
  -h, --help            Show this message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --no-packages) install_packages=0 ;;
  --no-shell) set_shell=0 ;;
  --git-profile)
    [[ $# -ge 2 ]] || die "--git-profile needs an argument"
    git_profile="$2"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    die "unknown option: $1"
    ;;
  esac
  shift
done

case "$(uname -s)" in
Darwin) DOTFILES_OS=osx ;;
Linux) DOTFILES_OS=linux ;;
*) die "unsupported OS: $(uname -s) (Linux and macOS only)" ;;
esac

# Resolve how to run privileged commands, if at all. Containers often run as
# root with no sudo; unprivileged CI has neither. Both must degrade to skipping
# the privileged steps rather than failing the whole run.
#
# Note the ordering: `sudo -n true` failing only means credentials aren't
# cached, not that sudo is unusable. On an ordinary account sudo works fine, it
# just wants a password, so fall through to prompting whenever there's a
# terminal to prompt on.
if [[ $(id -u) -eq 0 ]]; then
  SUDO=""
  have_privileges=1
elif ! command -v sudo >/dev/null 2>&1; then
  SUDO=""
  have_privileges=0
elif sudo -n true 2>/dev/null; then
  SUDO="sudo"
  have_privileges=1
elif [[ -t 0 ]]; then
  SUDO="sudo"
  have_privileges=1
else
  SUDO=""
  have_privileges=0
fi

init_submodules() {
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
    warn "not a git checkout; skipping submodules (vim colorscheme will be missing)"
    return 0
  }
  log "Fetching submodules"
  # Non-fatal: this needs the network and a writable checkout, and neither is
  # guaranteed on the locked-down hosts --no-packages targets. .vimrc already
  # tolerates the colorscheme being absent.
  git -C "$REPO_ROOT" submodule update --init --recursive ||
    warn "submodule fetch failed; continuing without the vim colorscheme"
}

install_linux_prereqs() {
  # Homebrew on Linux needs a compiler and a few basics before it will run.
  local pkgs=(build-essential curl file git procps stow)

  if ! command -v apt-get >/dev/null 2>&1; then
    warn "no apt-get here; ensure these are installed by hand: ${pkgs[*]}"
    return 0
  fi
  if [[ $have_privileges -eq 0 ]]; then
    warn "no usable sudo; skipping apt install of: ${pkgs[*]}"
    return 0
  fi

  log "Installing build prerequisites via apt"
  $SUDO apt-get update -qq
  $SUDO apt-get install -y --no-install-recommends "${pkgs[@]}"
}

install_brew() {
  if command -v brew >/dev/null 2>&1; then
    log "Homebrew already installed"
    return 0
  fi

  log "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL "https://raw.githubusercontent.com/Homebrew/install/${BREW_INSTALLER_REF}/install.sh")"

  local candidate
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew \
    /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
    if [[ -x $candidate ]]; then
      eval "$("$candidate" shellenv)"
      return 0
    fi
  done

  die "Homebrew installed but its binary was not found in any known prefix"
}

install_brew_packages() {
  log "Installing Brewfile packages"
  brew bundle install --file="$REPO_ROOT/Brewfile"
}

link_dotfiles() {
  command -v stow >/dev/null 2>&1 ||
    die "stow not found. Install it (brew install stow / apt install stow) or rerun without --no-packages."

  log "Linking dotfiles with stow"
  # --restow removes stale links first, which makes reruns idempotent and picks
  # up files that moved between packages.
  if ! stow --dir="$REPO_ROOT" --target="$HOME" --restow "${STOW_PACKAGES[@]}"; then
    die "stow reported conflicts. Move or delete the offending files in \$HOME and rerun."
  fi
  if ! stow --dir="$REPO_ROOT" --target="$HOME" --restow --no-folding "${NO_FOLD_PACKAGES[@]}"; then
    die "stow reported conflicts. Move or delete the offending files in \$HOME and rerun."
  fi
}

# ~/.gitconfig includes ~/.gitconfig_user, which selects an identity. Without
# it git has no user.email and every commit fails.
setup_git_identity() {
  local target="$HOME/.gitconfig_user"

  if [[ -e $target && -z $git_profile ]]; then
    log "git identity already configured ($target)"
    return 0
  fi

  if [[ -z $git_profile ]]; then
    if [[ ! -t 0 ]]; then
      warn "no git identity at $target and no terminal to prompt on."
      warn "rerun with --git-profile personal|work, or create it by hand."
      return 0
    fi
    local reply
    read -r -p "git identity to use [personal/work]: " reply
    git_profile="$reply"
  fi

  case "$git_profile" in
  personal | work) ;;
  *) die "unknown git profile '$git_profile' (expected: personal or work)" ;;
  esac

  [[ -e "$HOME/.gitconfig_$git_profile" ]] ||
    die "$HOME/.gitconfig_$git_profile is missing; run the stow step first"

  log "Setting git identity to '$git_profile'"
  cat >"$target" <<EOF
# Written by bootstrap.sh. Selects which identity ~/.gitconfig pulls in.
[include]
    path = ~/.gitconfig_$git_profile
EOF
}

set_default_shell() {
  local zsh_path
  zsh_path="$(command -v zsh 2>/dev/null)" || {
    warn "zsh not installed; leaving login shell alone"
    return 0
  }

  if [[ ${SHELL:-} == "$zsh_path" ]]; then
    log "zsh is already the login shell"
    return 0
  fi

  # chsh refuses any shell that isn't listed in /etc/shells, and brew's zsh
  # never is.
  if ! grep -qxF "$zsh_path" /etc/shells 2>/dev/null; then
    if [[ $have_privileges -eq 1 ]]; then
      log "Registering $zsh_path in /etc/shells"
      printf '%s\n' "$zsh_path" | $SUDO tee -a /etc/shells >/dev/null
    else
      warn "$zsh_path is not in /etc/shells and this run cannot edit it; skipping chsh"
      return 0
    fi
  fi

  log "Setting login shell to $zsh_path"
  chsh -s "$zsh_path" || warn "chsh failed; set the login shell yourself"
}

main() {
  log "Bootstrapping dotfiles ($DOTFILES_OS) from $REPO_ROOT"

  init_submodules

  if [[ $install_packages -eq 1 ]]; then
    [[ $DOTFILES_OS == linux ]] && install_linux_prereqs
    install_brew
    install_brew_packages
  else
    log "Skipping package installation (--no-packages)"
  fi

  link_dotfiles
  setup_git_identity
  [[ $set_shell -eq 1 ]] && set_default_shell

  log "Done. Start a new shell, or run: exec zsh"
}

main "$@"
