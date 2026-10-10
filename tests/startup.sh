#!/usr/bin/env bash
# Exercise real Zsh startup with native or Homebrew dependencies and local hooks.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
for dependency in stow zsh fzf script; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'Required test dependency: %s (install with native packages or Homebrew)\n' "$dependency" >&2
    exit 1
  }
done
scratch="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-startup-test.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home/.local/bin" "$scratch/home/.local/golang/bin" \
  "$scratch/home/.docker/bin" "$scratch/home/.krew/bin"
HOME="$scratch/home" bash "$repo_dir/install.sh" >"$scratch/install.log" 2>&1

# Explicitly interactive automation still has no line editor without a TTY.
# Fzf must remain usable without its ZLE integration emitting startup errors.
export HOME="$scratch/home" ZDOTDIR="$scratch/home" TERM=xterm-256color
unset GOROOT GPG_TTY BREW_PREFIX DOTFILES_BREW_PATH KREW_ROOT
zsh -dlic 'printf "alpha\nbeta\n" | fzf --filter beta' \
  </dev/null >"$scratch/output" 2>"$scratch/errors"
printf 'beta\n' >"$scratch/expected"
if ! cmp -s "$scratch/output" "$scratch/expected" || [[ -s "$scratch/errors" ]]; then
  cat "$scratch/output" "$scratch/errors" >&2
  printf 'FAIL: automated shell startup interfered with Fzf filtering\n' >&2
  exit 1
fi

fail() {
  cat "$scratch/output" "$scratch/errors" >&2
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# An absent optional file returns false, but environment effects and the
# interactive configuration must survive that incidental loader status.
mkdir -p "$HOME/.config/dotfiles-local"
# Legacy profile fragments must never be sourced: machine-local hooks replaced
# them. Keep this synthetic file outside the public checkout.
mkdir -p "$HOME/.zprofile.d"
printf 'export DOTFILES_TEST_LEGACY=unexpected\n' >"$HOME/.zprofile.d/env.work"
cat >"$HOME/.config/dotfiles-local/env.zsh" <<'ENV'
export DOTFILES_TEST_ENV=loaded
export EDITOR=machine-local-editor
DOTFILES_TEST_ENV_LOADS=$(( ${DOTFILES_TEST_ENV_LOADS:-0} + 1 ))
[[ -s "$HOME/.optional-env.zsh" ]] && source "$HOME/.optional-env.zsh"
ENV

assert_interactive() {
  local mode="$1" label="$2"
  if ! zsh "$mode" -c '
        [[ "$DOTFILES_TEST_ENV" == loaded && "$DOTFILES_TEST_ENV_LOADS" == 1 ]] || exit 1
        [[ -o hist_ignore_space && -o complete_in_word ]] || exit 1
        [[ "$EDITOR" == machine-local-editor && "$NVM_DIR" == "$HOME/.nvm" ]] || exit 1
        (( ! ${+DOTFILES_TEST_LEGACY} && ! ${+GPG_TTY} )) || exit 1
        if [[ "${DOTFILES_RUNTIME:-}" == native ]]; then
            (( ! ${+BREW_PREFIX} && ! ${+DOTFILES_BREW_PATH} )) || exit 1
        fi
        [[ -d "$ZSH_CACHE_DIR" ]] || exit 1
        (( ${+aliases[gr]} && ${+aliases[jqtable]} && ${+aliases[claude-yolo]} )) || exit 1
        for directory in "$HOME/.local/bin" "$HOME/.local/golang/bin" "$HOME/.docker/bin" "$HOME/.krew/bin"; do
            matches=("${(@)path:#${~directory}}")
            (( $#path - $#matches == 1 )) || exit 1
        done
        unique_path=("${(@u)path}")
        (( $#path == $#unique_path )) || exit 1
        source "$HOME/.config/dotfiles/zprofile"
        [[ "$DOTFILES_TEST_ENV_LOADS" == 1 ]] || exit 1
        (( ${+functions[compdef]} )) || exit 1
        [[ "$(bindkey "^R")" == *history-incremental-search-backward ]] || exit 1
        [[ "${(t)_DOTFILES_PROFILE_LOADED}" != *export* ]] || exit 1
        if [[ -f "$HOME/.test-local-profile" ]]; then
            [[ "$DOTFILES_TEST_PROFILE" == loaded && "$DOTFILES_TEST_PROFILE_LOADS" == 1 ]] || exit 1
        fi
        printf "alpha\nbeta\n" | fzf --filter beta
    ' </dev/null >"$scratch/output" 2>"$scratch/errors"; then
    fail "$label disabled interactive settings or lost local effects"
  fi
  if ! cmp -s "$scratch/output" "$scratch/expected" || [[ -s "$scratch/errors" ]]; then
    fail "$label interfered with terminal-less Fzf filtering"
  fi
}

assert_interactive -dic 'false optional environment tail (non-login)'
assert_interactive -dlic 'false optional environment tail (login)'

# A normal machine-local profile can have the same optional tail after the
# managed block. Its overrides must survive, and it must run only once.
touch "$HOME/.test-local-profile"
cat >>"$HOME/.zprofile" <<'PROFILE'
export DOTFILES_TEST_PROFILE=loaded
DOTFILES_TEST_PROFILE_LOADS=$(( ${DOTFILES_TEST_PROFILE_LOADS:-0} + 1 ))
[[ -s "$HOME/.optional-profile.zsh" ]] && source "$HOME/.optional-profile.zsh"
PROFILE
assert_interactive -dic 'false local profile tail (non-login)'
assert_interactive -dlic 'false local profile tail (login)'

# Native mode deliberately bypasses Brew even when installed, and discards
# inherited Brew prefixes rather than using them for plugin discovery.
DOTFILES_RUNTIME=native BREW_PREFIX=/synthetic/brew DOTFILES_BREW_PATH=/synthetic/brew \
  assert_interactive -dic 'explicit native runtime (non-login)'
DOTFILES_RUNTIME=native BREW_PREFIX=/synthetic/brew DOTFILES_BREW_PATH=/synthetic/brew \
  assert_interactive -dlic 'explicit native runtime (login)'

# Login-only automation loads environment but must not install interactive
# aliases, completions or widgets. A false optional tail is harmless here too.
if ! zsh -dlc '
    [[ "$DOTFILES_TEST_ENV_LOADS" == 1 && "$DOTFILES_TEST_PROFILE_LOADS" == 1 ]] || exit 1
    [[ "$EDITOR" == machine-local-editor ]] || exit 1
    (( ${+_DOTFILES_PROFILE_LOADED} && ! ${+functions[compdef]} && ! ${+aliases[gr]} )) || exit 1
    (( ! ${+DOTFILES_TEST_LEGACY} && ! ${+GPG_TTY} )) || exit 1
    printf "alpha\nbeta\n" | fzf --filter beta
' </dev/null >"$scratch/output" 2>"$scratch/errors"; then
  fail 'login-only shell lost local environment or loaded interactive setup'
fi
if ! cmp -s "$scratch/output" "$scratch/expected" || [[ -s "$scratch/errors" ]]; then
  fail 'login-only startup emitted terminal-less output'
fi

# A real TTY must install Fzf after the base bindings. Testing under script(1)
# exercises the same ordering as an actual interactive terminal on both hosts.
cat >"$scratch/widgets.zsh" <<'WIDGETS'
[[ -t 0 && -t 1 && -o zle ]] || exit 1
[[ "$(bindkey "^R")" == *fzf-history-widget ]] || exit 1
[[ "$DOTFILES_TEST_ENV_LOADS" == 1 && "$DOTFILES_TEST_PROFILE_LOADS" == 1 ]] || exit 1
[[ "$EDITOR" == machine-local-editor ]] || exit 1
print -r -- FZF_WIDGET_OK
WIDGETS
export DOTFILES_TEST_WIDGETS="$scratch/widgets.zsh"
export DOTFILES_TEST_SHELL_MODE
for DOTFILES_TEST_SHELL_MODE in -dic -dlic; do
  printf -v tty_command 'stty -echo 2>/dev/null; zsh %s -c %s' \
    "$DOTFILES_TEST_SHELL_MODE" "'source \"\$DOTFILES_TEST_WIDGETS\"'"
  if [[ $(uname -s) == Darwin ]]; then
    script -q /dev/null /bin/sh -c "$tty_command" </dev/null >"$scratch/output" 2>"$scratch/errors" ||
      fail 'interactive TTY failed to initialize'
  else
    script -qec "$tty_command" /dev/null </dev/null >"$scratch/output" 2>"$scratch/errors" ||
      fail 'interactive TTY failed to initialize'
  fi
  output="$(<"$scratch/output")"
  [[ "$output" == *FZF_WIDGET_OK* && ! -s "$scratch/errors" ]] ||
    fail 'Fzf Ctrl-R was lost after base key bindings'
done

# Native hosts have no Brew to break. On Brew hosts, exercise a genuine failure
# from a deleted working directory rather than a fake command or implementation.
brew_prefix="$(zsh -dlic 'print -r -- "${BREW_PREFIX:-}"' </dev/null)"
if [[ -n "$brew_prefix" ]]; then
  mkdir "$scratch/vanished"
  if ! DOTFILES_TEST_CWD="$scratch/vanished" zsh -dfi -c '
        cd "$DOTFILES_TEST_CWD" || exit 1
        rmdir "$DOTFILES_TEST_CWD" || exit 1
        source "$HOME/.zshrc"
        (( ! ${+_DOTFILES_PROFILE_LOADED} && ! ${+functions[compdef]} )) || exit 1
        (( ! ${+DOTFILES_TEST_ENV} && ! ${+DOTFILES_TEST_PROFILE} )) || exit 1
        [[ ! -o hist_ignore_space ]] || exit 1
    ' </dev/null >"$scratch/output" 2>"$scratch/errors"; then
    fail 'failed shared initialization did not stop dependent setup'
  fi
  errors="$(<"$scratch/errors")"
  if [[ -s "$scratch/output" || "$errors" != *'Homebrew shellenv failed'* || "$errors" != *'dotfiles bootstrap'* ]]; then
    fail 'failed shared initialization did not report an actionable Homebrew error'
  fi
fi
printf 'Automated shell startup regression passed.\n'
