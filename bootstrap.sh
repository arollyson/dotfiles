#!/usr/bin/env bash
set -euo pipefail
set -E

fail() {
  printf 'bootstrap: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: bootstrap.sh [options]

Install dependencies, initialize Vim submodules, and install shared dotfiles.
By default, register Zsh and make it the current account's login shell.

  --no-packages          Install configs only; do not discover or install Homebrew.
  --no-change-shell      Leave the account's login shell unchanged.
  --no-shell             Same as --no-change-shell.
  --backup               Back up conflicting Stow targets outside the checkout.
  --git-profile NAME     Select personal or machine-local work identity.
  --migrate-local        Move legacy env.work into machine-local configuration.
  --help, -h             Show this help.

Full package installation requires a non-root development account.
Config-only installation supports root containers. Any required sudo access must
already work with sudo -n; this script never asks for a password or opens a shell.
USAGE
}

change_shell=true
install_packages=true
installer_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --no-packages) install_packages=false ;;
  --no-change-shell | --no-shell) change_shell=false ;;
  --backup | --migrate-local) installer_args+=("$1") ;;
  --git-profile)
    [[ $# -ge 2 ]] || fail '--git-profile requires personal or work.'
    case "$2" in
    personal | work) installer_args+=(--git-profile "$2") ;;
    *) fail '--git-profile requires personal or work.' ;;
    esac
    shift
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    fail "Unknown option: $1"
    ;;
  esac
  shift
done

trap 'printf "bootstrap: command failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
account="$(id -un)"
account_uid="$(id -u)"
if [[ "$install_packages" == true && "$account_uid" == 0 ]]; then
  fail 'Run package installation as the intended non-root development user (Homebrew does not support root installation). Use --no-packages --no-shell for root templates.'
fi

# Pin installer behavior; current upstream installers reject Intel macOS.
homebrew_installer_ref=09c62fc577ec170172b0a184060f141a2c622dc1

case "$(uname -s)" in
Darwin)
  export DOTFILES_OS=osx
  case "$(uname -m)" in
  arm64) default_brew_prefix=/opt/homebrew ;;
  x86_64)
    default_brew_prefix=/usr/local
    homebrew_installer_ref=6895ebe7fd7e90478237d4219823f9c74e5e76fd
    ;;
  *) fail 'Unsupported macOS architecture; Homebrew requires Apple Silicon or Intel.' ;;
  esac
  ;;
Linux)
  export DOTFILES_OS=linux
  default_brew_prefix=/home/linuxbrew/.linuxbrew
  ;;
*) fail 'Unsupported platform; this bootstrap supports macOS and Linux only.' ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing $1. $2"
}

sudo_checked=false
require_sudo() {
  [[ "$account_uid" != 0 ]] || return 0
  if [[ "$sudo_checked" == false ]]; then
    require_command sudo 'Arrange noninteractive sudo access for this account before retrying.'
    sudo -n true </dev/null || fail 'Passwordless or pre-authorized sudo access is required. Arrange sudo -n access before retrying (or use --no-change-shell if only the shell change needs it).'
    sudo_checked=true
  fi
}

run_privileged() {
  if [[ "$account_uid" == 0 ]]; then
    "$@"
  else
    require_sudo
    sudo -n "$@"
  fi
}

find_brew() {
  brew_binary="$(command -v brew || true)"
  if [[ -n "$brew_binary" ]]; then
    return 0
  fi
  local candidate
  if [[ "$DOTFILES_OS" == osx ]]; then
    for candidate in "$default_brew_prefix/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [[ -x "$candidate" ]]; then
        brew_binary="$candidate"
        return 0
      fi
    done
  else
    for candidate in "$default_brew_prefix/bin/brew" "$HOME/.linuxbrew/bin/brew"; do
      if [[ -x "$candidate" ]]; then
        brew_binary="$candidate"
        return 0
      fi
    done
  fi
  return 1
}

read_login_shell() {
  if [[ "$DOTFILES_OS" == osx ]]; then
    require_command dscl 'The macOS Directory Service tool is required to read the current login shell.'
    local shell_record shell_key
    shell_record="$(dscl . -read "/Users/$account" UserShell)" || fail "Cannot read the login shell for $account from macOS Directory Service."
    read -r shell_key current_shell <<<"$shell_record"
    [[ "$shell_key" == UserShell: && -n "$current_shell" ]] || fail "Cannot determine the login shell for $account."
  else
    require_command getent 'Install the libc getent utility to read the current account login shell.'
    local passwd_record record_account record_uid
    passwd_record="$(getent passwd "$account_uid")" || fail "Cannot find the current account ($account, uid $account_uid) in the system account database."
    IFS=: read -r record_account _ record_uid _ _ _ current_shell <<<"$passwd_record"
    [[ "$record_account" == "$account" && "$record_uid" == "$account_uid" && -n "$current_shell" ]] || fail "Cannot determine the login shell for $account."
  fi
}

shell_registered() {
  [[ -r /etc/shells ]] && grep -Fxq -- "$1" /etc/shells
}

brew_installed=false
if [[ "$install_packages" == true ]]; then
  if find_brew; then
    brew_installed=true
    brew_prefix="$("$brew_binary" --prefix)"
    [[ "$brew_prefix" == /* ]] || fail 'Homebrew returned an invalid installation prefix.'
  else
    brew_prefix="$default_brew_prefix"
  fi
  zsh_path="$brew_prefix/bin/zsh"
else
  zsh_path="$(command -v zsh || true)"
  if [[ "$change_shell" == true && -z "$zsh_path" ]]; then
    printf 'Zsh is not installed; leaving the login shell unchanged in config-only mode.\n' >&2
    change_shell=false
  fi
fi

# Check privileges before installing anything when a shell change is needed.
if [[ "$change_shell" == true ]]; then
  require_command chsh 'Install the system chsh utility or use --no-change-shell.'
  read_login_shell
  if [[ "$current_shell" != "$zsh_path" ]] || ! shell_registered "$zsh_path"; then
    require_sudo
  fi
fi

export NONINTERACTIVE=1
export GIT_TERMINAL_PROMPT=0
export CI=1
if [[ "$install_packages" == true ]]; then
  if [[ "$brew_installed" == false ]]; then
    if [[ "$DOTFILES_OS" == linux ]]; then
      require_command apt-get 'Fresh Linux Homebrew installation requires Debian/Ubuntu-style apt-get and build-essential, procps, curl, file, and git. Provision these and Homebrew separately on other Linux distributions, then retry.'
      require_sudo
      printf 'Installing Linux Homebrew prerequisites\n'
      run_privileged env DEBIAN_FRONTEND=noninteractive apt-get update </dev/null
      run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential procps curl file git </dev/null
    else
      require_sudo
      require_command xcode-select 'Install the Xcode Command Line Tools before retrying.'
      xcode-select -p >/dev/null 2>&1 || fail 'Install the Xcode Command Line Tools (xcode-select --install) before running this unattended bootstrap.'
    fi
    require_command curl 'Install curl before retrying the Homebrew installation.'
    require_command git 'Install git before retrying the Homebrew installation.'
    installer_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-bootstrap.XXXXXX")"
    trap 'rm -rf -- "$installer_dir"' EXIT
    printf 'Installing Homebrew\n'
    curl --fail --show-error --silent --location \
      "https://raw.githubusercontent.com/Homebrew/install/$homebrew_installer_ref/install.sh" \
      --output "$installer_dir/install.sh" </dev/null
    /bin/bash "$installer_dir/install.sh" </dev/null
    find_brew || fail "The Homebrew installer completed but brew was not found. Check $default_brew_prefix/bin/brew and your PATH."
    brew_prefix="$("$brew_binary" --prefix)"
    [[ "$brew_prefix" == /* ]] || fail 'Homebrew returned an invalid installation prefix.'
  fi

  # Capture shellenv separately so a failing brew command cannot be hidden by eval.
  brew_environment="$("$brew_binary" shellenv)"
  eval "$brew_environment"
  export DOTFILES_BREW_PATH="$brew_prefix"
  export BREW_PREFIX="$brew_prefix"
  export PATH="$brew_prefix/bin:$brew_prefix/sbin:$PATH"

  printf 'Installing Homebrew packages\n'
  "$brew_binary" bundle install --file="$repo_dir/Brewfile" </dev/null
  zsh_path="$brew_prefix/bin/zsh"
else
  printf 'Skipping package installation (--no-packages)\n'
fi
require_command git 'Install Git before bootstrapping dotfiles.'
if git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
  printf 'Registering the private Claude settings clean filter\n'
  git -C "$repo_dir" config filter.strip-automode.clean "jq --indent 2 'del(.autoMode)'"
  git -C "$repo_dir" config filter.strip-automode.required true
  printf 'Initializing repository submodules\n'
  if [[ "$install_packages" == true ]]; then
    git -C "$repo_dir" submodule update --init --recursive </dev/null
  elif ! git -C "$repo_dir" submodule update --init --recursive </dev/null; then
    printf 'Submodule fetch failed; continuing config-only installation without missing Vim packages.\n' >&2
  fi
elif [[ "$install_packages" == true ]]; then
  fail 'Full bootstrap requires a Git checkout to initialize Vim submodules.'
else
  printf 'Not a Git checkout; skipping submodule and repository filter setup.\n' >&2
fi
printf 'Installing shared dotfiles and local entrypoints\n'
bash "$repo_dir/install.sh" ${installer_args[@]+"${installer_args[@]}"} </dev/null

if [[ "$change_shell" == true ]]; then
  [[ -x "$zsh_path" ]] || fail "Zsh was not installed at $zsh_path."
  if ! shell_registered "$zsh_path"; then
    require_sudo
    printf '%s\n' "$zsh_path" | run_privileged tee -a /etc/shells >/dev/null
  fi
  if [[ "$current_shell" != "$zsh_path" ]]; then
    require_sudo
    printf 'Setting login shell for %s to %s\n' "$account" "$zsh_path"
    run_privileged chsh -s "$zsh_path" "$account" </dev/null
  fi
fi
printf 'Bootstrap complete. Start a new login session to use the installed settings.\n'
