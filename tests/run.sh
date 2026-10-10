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
# Native mode must never discover Brew or perform package/account operations.
export DOTFILES_RUNTIME=native GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL

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
export ZDOTDIR="$HOME_A"

# --- install ---------------------------------------------------------------
if HOME="$HOME_A" "$REPO_ROOT/bootstrap.sh" \
  --no-packages --no-shell --git-profile personal >"$SCRATCH/install.log" 2>&1; then
  ok "bootstrap --no-packages succeeds"
else
  no "bootstrap --no-packages failed"
  cat "$SCRATCH/install.log" >&2
fi

# ~/.claude must be a real directory holding symlinks, never a symlink itself:
# folded, Claude Code would write credentials and session transcripts into this
# repo. Note the scratch HOME has no pre-existing ~/.claude, which is the fresh
# machine case where folding actually happens.
if [[ -L $HOME_A/.claude ]]; then
  no ".claude was folded into a symlink (runtime state would land in the repo)"
elif [[ -d $HOME_A/.claude ]]; then
  ok ".claude is a real directory, not folded"
else
  no ".claude was not created"
fi
for link in .claude/CLAUDE.md .claude/settings.json .claude/statusline.sh; do
  if [[ -L $HOME_A/$link ]]; then
    ok "linked $link"
  else
    no "missing symlink $link"
  fi
done
if [[ -x $HOME_A/.claude/statusline.sh ]]; then
  ok "statusline.sh is executable"
else
  no "statusline.sh is not executable"
fi

# Exercise the filter itself, not merely the config line bootstrap wrote.
filter_cmd="$(git -C "$REPO_ROOT" config --get filter.strip-automode.clean || true)"
if [[ -z $filter_cmd ]]; then
  no "strip-automode clean filter is not registered"
elif ! command -v jq >/dev/null 2>&1; then
  no "strip-automode clean filter needs jq, which is not installed"
else
  filtered="$(printf '{"model":"x","autoMode":{"environment":["secret"]}}' | sh -c "$filter_cmd")"
  if [[ $filtered == *autoMode* || $filtered == *secret* ]]; then
    no "strip-automode clean filter left autoMode in place: $filtered"
  elif [[ $filtered != *'"model": "x"'* ]]; then
    no "strip-automode clean filter mangled the rest of the file: $filtered"
  else
    ok "strip-automode clean filter drops autoMode"
  fi
fi

for entrypoint in .zprofile .zshrc .gitconfig; do
  if [[ -f $HOME_A/$entrypoint && ! -L $HOME_A/$entrypoint ]]; then
    ok "$entrypoint is a regular managed entrypoint"
  else
    no "$entrypoint is not a regular managed entrypoint"
  fi
done
# Check consumer-visible settings, not incidental Stow symlink wiring.
if [[ -r $HOME_A/.vimrc && -r $HOME_A/.tmux.conf && -r $HOME_A/.config/dotfiles/zprofile ]]; then
  ok "shared shell, vim, and tmux configs are installed"
else
  no "shared configuration is missing"
fi
printf 'synthetic credential\n' >"$HOME_A/.claude/.credentials.json"
mkdir -p "$HOME_A/.claude/projects/synthetic"
printf 'synthetic transcript\n' >"$HOME_A/.claude/projects/synthetic/session.jsonl"

if HOME="$HOME_A" "$REPO_ROOT/bootstrap.sh" \
  --no-packages --no-shell >>"$SCRATCH/install.log" 2>&1; then
  ok "rerunning bootstrap is idempotent"
else
  no "rerunning bootstrap failed"
fi
if [[ $(cat "$HOME_A/.claude/.credentials.json") == 'synthetic credential' &&
$(cat "$HOME_A/.claude/projects/synthetic/session.jsonl") == 'synthetic transcript' &&
! -e $REPO_ROOT/claude/.claude/projects/synthetic &&
! -e $REPO_ROOT/claude/.claude/.credentials.json ]]; then
  ok "Claude runtime stays outside checkout and survives reruns"
else
  no "Claude runtime data was lost or entered checkout"
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
personal_email="$(GIT_CONFIG_GLOBAL=/dev/null git config --file "$REPO_ROOT/git/.config/dotfiles/gitconfig_personal" --get user.email)"
if [[ $(HOME="$HOME_A" git config --global --includes --get user.email) == "$personal_email" &&
! -e $HOME_A/.gitconfig_user ]]; then
  ok "shared personal identity resolves without obsolete identity shim"
else
  no "personal Git identity is unset or obsolete identity shim exists"
fi

# Explicit selection overrides identity only; local trust/signing/credentials
# and unmarked entrypoint settings survive. Fixtures never contain work data.
HOME_ID="$SCRATCH/identity"
mkdir -p "$HOME_ID/.config/dotfiles-local"
printf '[user]\n    name = Synthetic Local\n    email = synthetic@example.invalid\n    signingkey = synthetic-key\n[commit]\n    gpgsign = true\n[credential]\n    helper = synthetic-helper\n[safe]\n    directory = /synthetic/trusted\n' >"$HOME_ID/.config/dotfiles-local/gitconfig"
printf '[user]\n    email = tail@example.invalid\n[dotfiles]\n    tail = retained\n' >"$HOME_ID/.gitconfig"
cp "$HOME_ID/.config/dotfiles-local/gitconfig" "$SCRATCH/private-git-original"
if HOME="$HOME_ID" "$REPO_ROOT/bootstrap.sh" --no-packages --no-shell >/dev/null 2>&1 &&
  [[ $(HOME="$HOME_ID" git config --global --includes --get user.email) == tail@example.invalid ]]; then
  ok "default identity preserves local precedence"
else
  no "default identity changed machine-local settings"
fi
if HOME="$HOME_ID" "$REPO_ROOT/bootstrap.sh" --no-packages --no-shell --git-profile work >/dev/null 2>&1 &&
  HOME="$HOME_ID" "$REPO_ROOT/bootstrap.sh" --no-packages --no-shell >/dev/null 2>&1 &&
  [[ $(HOME="$HOME_ID" git config --global --includes --get user.email) == synthetic@example.invalid ]]; then
  ok "explicit work identity uses local config and persists on rerun"
else
  no "explicit work identity did not resolve or persist"
fi
if HOME="$HOME_ID" "$REPO_ROOT/bootstrap.sh" --no-packages --no-shell --git-profile personal >/dev/null 2>&1 &&
  HOME="$HOME_ID" "$REPO_ROOT/bootstrap.sh" --no-packages --no-shell >/dev/null 2>&1 &&
  [[ $(HOME="$HOME_ID" git config --global --includes --get user.email) == "$personal_email" &&
  $(HOME="$HOME_ID" git config --global --includes --get commit.gpgsign) == true &&
  $(HOME="$HOME_ID" git config --global --includes --get user.signingkey) == synthetic-key &&
  $(HOME="$HOME_ID" git config --global --includes --get credential.helper) == synthetic-helper &&
  $(HOME="$HOME_ID" git config --global --includes --get safe.directory) == /synthetic/trusted &&
  $(HOME="$HOME_ID" git config --global --includes --get dotfiles.tail) == retained ]] &&
  cmp -s "$HOME_ID/.config/dotfiles-local/gitconfig" "$SCRATCH/private-git-original"; then
  ok "personal selection persists without sacrificing private Git settings or tail"
else
  no "personal selection lost identity, signing, trust, credentials, or tail"
fi
HOME_MISSING="$SCRATCH/missing-identity"
mkdir -p "$HOME_MISSING"
if HOME="$HOME_MISSING" "$REPO_ROOT/bootstrap.sh" --no-packages --no-shell --git-profile work >/dev/null 2>&1; then
  no "work profile succeeded without locally provisioned identity"
else
  ok "work profile requires machine-local identity"
fi

# The default-branch alias must fall back rather than yielding "origin/".
norepo="$SCRATCH/norepo"
mkdir -p "$norepo"
HOME="$HOME_A" GIT_CONFIG_GLOBAL=/dev/null git -C "$norepo" init -q .
HOME="$HOME_A" GIT_CONFIG_GLOBAL=/dev/null git -C "$norepo" -c user.name="dotfiles tests" -c user.email="tests@example.invalid" \
  -c commit.gpgsign=false commit -q --allow-empty -m init
branch="$(HOME="$HOME_A" GIT_CONFIG_GLOBAL=/dev/null git -C "$norepo" -c include.path="$REPO_ROOT/git/.config/dotfiles/gitconfig" defaultbranch || true)"
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
# Package conflicts abort; regular entrypoint tails are intentionally preserved.
HOME_B="$SCRATCH/conflict"
mkdir -p "$HOME_B"
printf 'pre-existing\n' >"$HOME_B/.tmux.conf"
printf '# local entrypoint tail\nexport SYNTHETIC_LOCAL=preserved\n' >"$HOME_B/.zshrc"
cp "$HOME_B/.zshrc" "$SCRATCH/conflict-zshrc"
if HOME="$HOME_B" "$REPO_ROOT/bootstrap.sh" \
  --no-packages --no-shell --git-profile personal >/dev/null 2>&1; then
  no "stow conflict was not reported"
else
  ok "stow conflict exits non-zero"
fi
if [[ "$(cat "$HOME_B/.tmux.conf")" == "pre-existing" ]] &&
  cmp -s "$HOME_B/.zshrc" "$SCRATCH/conflict-zshrc"; then
  ok "conflicting file left untouched"
else
  no "conflicting file was overwritten"
fi

# --- upgrade path ------------------------------------------------------------
# Backups contain only conflicting local regular files, outside the checkout.
# Rerunning over already managed links must never rename repository files.
HOME_C="$SCRATCH/upgrade"
mkdir -p "$HOME_C"
HOME="$HOME_C" "$REPO_ROOT/bootstrap.sh" \
  --no-packages --no-shell --git-profile personal >/dev/null 2>&1
rm -f "$HOME_C/.claude/CLAUDE.md"
printf '# pre-existing\n' >"$HOME_C/.claude/CLAUDE.md"
cp "$HOME_C/.claude/CLAUDE.md" "$SCRATCH/claude-original"
printf 'synthetic private credential\n' >"$HOME_C/.claude/.credentials.json"
repo_baks_before="$(find "$REPO_ROOT" -name '*.bak' -not -path '*/.git/*' | wc -l | tr -d ' ')"

if HOME="$HOME_C" "$REPO_ROOT/bootstrap.sh" \
  --no-packages --no-shell --backup --git-profile personal >/dev/null 2>&1; then
  ok "--backup installs over pre-existing config"
else
  no "--backup run failed"
fi

if [[ -L $HOME_C/.claude/CLAUDE.md ]]; then
  ok "pre-existing CLAUDE.md replaced by a symlink"
else
  no "CLAUDE.md was not linked"
fi

claude_backups=("$HOME_C/.local/state/dotfiles/backups/"*/stow/.claude/CLAUDE.md)
if cmp -s "${claude_backups[0]}" "$SCRATCH/claude-original" &&
  [[ $(cat "$HOME_C/.claude/.credentials.json") == 'synthetic private credential' ]]; then
  ok "original CLAUDE.md backed up outside checkout; credentials preserved"
else
  no "Claude backup or private credentials were lost"
fi

repo_baks_after="$(find "$REPO_ROOT" -name '*.bak' -not -path '*/.git/*' | wc -l | tr -d ' ')"
if [[ $repo_baks_before -eq $repo_baks_after ]]; then
  ok "--backup left the repo untouched"
else
  no "--backup renamed files inside the repo ($repo_baks_before -> $repo_baks_after)"
fi

# Installer-focused cases include exact-byte entrypoint preservation, migration
# permissions/retries, staged privacy filtering, and unsafe backup rejection.
if bash "$REPO_ROOT/tests/install.sh" >"$SCRATCH/installer-tests.log" 2>&1; then
  ok "installer privacy, identity, migration, and backup regressions"
else
  no "installer regressions failed"
  cat "$SCRATCH/installer-tests.log" >&2
fi

if bash "$REPO_ROOT/tests/omp.sh" >"$SCRATCH/omp-tests.log" 2>&1; then
  if command -v omp >/dev/null 2>&1; then
    ok "Omp installer and native sync/privacy regressions"
  else
    ok "Omp installer seeding and runtime privacy regressions"
    printf 'skip  native Omp sync/config cases (omp is not installed)\n'
  fi
else
  no "Omp privacy and sync regressions failed"
  cat "$SCRATCH/omp-tests.log" >&2
fi

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
