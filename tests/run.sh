#!/usr/bin/env bash
#
# Verification for these dotfiles. Installs into a scratch HOME and checks the
# result, so it never touches the real one.
#
# CI runs this exact script, so a clean run here means a clean run there --
# except for the macOS leg, which only CI can exercise.
#
# Usage: ./tests/run.sh

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"

# Scoped deliberately: only ever removes the directory mktemp just handed us.
cleanup() {
  if [[ -n ${SCRATCH:-} && -d $SCRATCH && $SCRATCH == "${TMPDIR:-/tmp}"/* ]]; then
    rm -rf -- "$SCRATCH"
  fi
}
trap cleanup EXIT

if [[ -t 1 ]]; then
  C_OK=$'\033[0;32m' C_NO=$'\033[0;31m' C_OFF=$'\033[0m'
else
  C_OK="" C_NO="" C_OFF=""
fi

passed=0
failed=0
ok() {
  printf '%sok    %s%s\n' "$C_OK" "$C_OFF" "$*"
  passed=$((passed + 1))
}
no() {
  printf '%snot ok%s %s\n' "$C_NO" "$C_OFF" "$*"
  failed=$((failed + 1))
}

# script(1) hands the pty an EOF and some platforms echo it back: macOS prints
# a literal ^D. That is the terminal talking, not the shell, so it must not
# count as startup output.
sanitize() {
  # Strip every C0 control character except tab and newline, plus DEL. The
  # hand-picked list this replaced missed the backspaces macOS emits to erase
  # its echoed ^D, which then read as "output" that displays as nothing.
  tr -d '\000-\010\013-\037\177' | sed 's/\^D//g' | sed '/^[[:space:]]*$/d'
}

# Renders captured output for a failure message. Falls back to a byte dump when
# the text is all non-printing, so a mystery failure reports what it actually
# got instead of a blank line.
render() {
  local text=$1
  # [:graph:] is "printable and not space" -- the test is whether there is any
  # visible glyph at all. Checking [:space:] instead lets control characters
  # like backspace count as content and print as a blank line.
  if [[ -n ${text//[![:graph:]]/} ]]; then
    printf '%s' "$text"
  else
    printf '(non-printing bytes) %s' "$(printf '%s' "$text" | od -An -c | tr -s ' ' | tr '\n' ' ')"
  fi
}

# A login shell is not an interactive one: .zshrc and .zshrc.d only run for the
# latter, which needs a pty. script(1) is spelled differently per platform.
#
# stdin is /dev/null so anything that prompts during startup gets an immediate
# EOF and fails loudly. Without it a compinit question blocks forever: macOS
# happens to deliver EOF and abort, Linux CI just hung until the job died. The
# wall-clock guard catches every other way a shell can wedge; macOS ships no
# timeout(1), hence the hand-rolled wait.
interactive_output() {
  local home=$1 out="$SCRATCH/interactive.$$" pid waited=0
  # stty -echo stops the pty echoing our EOF straight back: macOS returns a
  # literal ^D plus erase characters, which is the terminal talking, not zsh.
  local cmd='stty -echo 2>/dev/null; zsh -lic true'
  if [[ $(uname -s) == Darwin ]]; then
    HOME="$home" script -q /dev/null /bin/sh -c "$cmd" </dev/null >"$out" 2>&1 &
  else
    HOME="$home" script -qec "$cmd" /dev/null </dev/null >"$out" 2>&1 &
  fi
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((waited >= 20)); then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "shell startup blocked for ${waited}s (something is prompting)"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || true
  cat "$out"
  rm -f "$out"
}

command -v zsh >/dev/null 2>&1 || {
  echo "zsh is required to run these tests" >&2
  exit 1
}
command -v stow >/dev/null 2>&1 || {
  echo "stow is required to run these tests" >&2
  exit 1
}

HOME_A="$SCRATCH/home"
mkdir -p "$HOME_A"

# --- install ---------------------------------------------------------------
if HOME="$HOME_A" "$REPO_ROOT/bootstrap.sh" \
  --no-packages --no-shell --git-profile personal >"$SCRATCH/install.log" 2>&1; then
  ok "bootstrap --no-packages succeeds"
else
  no "bootstrap --no-packages failed"
  cat "$SCRATCH/install.log" >&2
fi

for link in .zshenv .zprofile .zshrc .zshrc.d .zprofile.d .vimrc .tmux.conf .gitconfig; do
  if [[ -L $HOME_A/$link ]]; then
    ok "linked $link"
  else
    no "missing symlink $link"
  fi
done

if HOME="$HOME_A" "$REPO_ROOT/bootstrap.sh" \
  --no-packages --no-shell >>"$SCRATCH/install.log" 2>&1; then
  ok "rerunning bootstrap is idempotent"
else
  no "rerunning bootstrap failed"
fi

# --- shell startup ---------------------------------------------------------
# No Homebrew plugins exist in a scratch HOME, which is exactly the devcontainer
# case: startup must be silent, not merely survivable.
login_err="$(HOME="$HOME_A" zsh -l -c 'true' </dev/null 2>&1 >/dev/null | sanitize || true)"
if [[ -z $login_err ]]; then
  ok "login shell starts silently"
else
  no "login shell wrote to stderr: $login_err"
fi

inter_out="$(interactive_output "$HOME_A" | sanitize)"
if [[ -z $inter_out ]]; then
  ok "interactive shell starts silently"
else
  no "interactive shell produced output: $(render "$inter_out")"
fi

path_all="$(HOME="$HOME_A" zsh -l -c 'print -r -- $PATH' | tr ':' '\n' | grep -c . || true)"
path_uniq="$(HOME="$HOME_A" zsh -l -c 'print -r -- $PATH' | tr ':' '\n' | grep . | sort -u | wc -l | tr -d ' ')"
if [[ $path_all -eq $path_uniq ]]; then
  ok "PATH has no duplicates ($path_all entries)"
else
  no "PATH has duplicates ($path_all entries, $path_uniq unique)"
fi

if [[ -z "$(HOME="$HOME_A" zsh -l -c 'print -r -- $PATH' | tr ':' '\n' | grep -x '/bin' | sed -n 2p)" ]]; then
  ok "no duplicated bare /bin from an unset GOROOT"
else
  no "bare /bin appears more than once in PATH"
fi

# An insecure directory on fpath must not stop compinit to ask a question:
# that aborts it outright and leaves the shell with no completion. Homebrew's
# share/zsh is group-writable on macOS often enough that this is the real
# failure mode, and it reproduces anywhere via a world-writable directory.
insecure="$SCRATCH/insecure-site-functions"
mkdir -p "$insecure"
chmod 777 "$insecure"
rm -f "$HOME_A/.zcompdump"
# Prepend, never replace: a bare FPATH= would hide compinit's own definitions
# and the test would fail for entirely the wrong reason.
default_fpath="$(HOME="$HOME_A" zsh -l -c 'print -rn -- ${(j.:.)fpath}')"
insecure_out="$(FPATH="$insecure:$default_fpath" interactive_output "$HOME_A" | sanitize)"
if [[ -z $insecure_out ]]; then
  ok "insecure fpath directory does not abort compinit"
else
  no "insecure fpath directory broke startup: $(render "$insecure_out")"
fi

# --- git -------------------------------------------------------------------
if [[ -n "$(HOME="$HOME_A" git config --get user.email || true)" ]]; then
  ok "git identity resolves through .gitconfig_user"
else
  no "git identity is unset"
fi

# The default-branch alias must fall back rather than yielding "origin/".
norepo="$SCRATCH/norepo"
mkdir -p "$norepo"
git -C "$norepo" init -q .
git -C "$norepo" -c user.name="dotfiles tests" -c user.email="tests@example.invalid" \
  commit -q --allow-empty -m init
branch="$(git -C "$norepo" -c include.path="$REPO_ROOT/git/.gitconfig" defaultbranch || true)"
if [[ $branch == "main" ]]; then
  ok "defaultbranch falls back to main without origin/HEAD"
else
  no "defaultbranch returned '$branch', expected 'main'"
fi

# --- vim -------------------------------------------------------------------
if HOME="$HOME_A" vim -N -es -c 'qa!' </dev/null >/dev/null 2>&1; then
  ok "vim loads the config"
else
  no "vim failed to load the config"
fi

# --- failure modes ---------------------------------------------------------
# A real file where a symlink belongs must abort loudly, not clobber it.
HOME_B="$SCRATCH/conflict"
mkdir -p "$HOME_B"
echo "pre-existing" >"$HOME_B/.zshrc"
if HOME="$HOME_B" "$REPO_ROOT/bootstrap.sh" \
  --no-packages --no-shell --git-profile personal >/dev/null 2>&1; then
  no "stow conflict was not reported"
else
  ok "stow conflict exits non-zero"
fi
if [[ "$(cat "$HOME_B/.zshrc")" == "pre-existing" ]]; then
  ok "conflicting file left untouched"
else
  no "conflicting file was overwritten"
fi

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
