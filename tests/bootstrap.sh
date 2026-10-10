#!/usr/bin/env bash
# All package, network, account, and privilege operations are fakes. No sudo runs.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-bootstrap-tests.XXXXXX")"
trap 'rm -rf -- "$workspace"' EXIT
# Exclude the caller's Homebrew bin directories from fresh-install discovery.
original_path=/usr/bin:/bin:/usr/sbin:/sbin
case_number=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  [[ ! -f "$case_dir/output" ]] || cat "$case_dir/output" >&2
  exit 1
}

assert_log() {
  grep -Fq -- "$1" "$CASE_LOG" || fail "Expected log entry: $1"
}

assert_no_log() {
  if grep -Fq -- "$1" "$CASE_LOG"; then
    fail "Unexpected log entry: $1"
  fi
}

assert_not_installed() {
  [[ ! -e "$CASE_INSTALL_MARKER" ]] || fail 'Dotfiles installed after an earlier bootstrap failure'
}

setup_case() {
  case_number=$((case_number + 1))
  case_dir="$workspace/case $case_number"
  mkdir -p "$case_dir/bin" "$case_dir/home/.linuxbrew/bin" "$case_dir/repo with spaces" "$case_dir/outside"
  cp "$repo_dir/bootstrap.sh" "$case_dir/repo with spaces/bootstrap.sh"
  cp "$repo_dir/Brewfile" "$case_dir/repo with spaces/Brewfile"
  cat >"$case_dir/repo with spaces/install.sh" <<'INSTALL_DOTFILES'
#!/usr/bin/env bash
touch "$CASE_INSTALL_MARKER"
INSTALL_DOTFILES
  export CASE_LOG="$case_dir/log"
  export CASE_INSTALL_MARKER="$case_dir/dotfiles-installed"
  export CASE_PREFIX="$case_dir/home/.linuxbrew"
  export MOCK_OS=Linux MOCK_ARCH=aarch64 MOCK_UID=1000 CURRENT_SHELL=/bin/bash
  export REGISTERED_SHELL=0 SUDO_FAIL=0 BUNDLE_FAIL=0 SHELLENV_FAIL=0 GIT_FAIL=0
  export APT_FAIL=0 CURL_FAIL=0 INSTALLER_FAIL=0
  : >"$CASE_LOG"
  cat >"$case_dir/mock" <<'MOCK'
#!/bin/bash
set -euo pipefail
name="${0##*/}"
case "$name" in
    uname)
        if [[ "$1" == -m ]]; then printf '%s\n' "$MOCK_ARCH"; else printf '%s\n' "$MOCK_OS"; fi
        ;;
    id)
        if [[ "$1" == -u ]]; then printf '%s\n' "$MOCK_UID"; else printf 'dev\n'; fi
        ;;
    brew)
        printf 'brew %s\n' "$*" >> "$CASE_LOG"
        case "$1" in
            --prefix) printf '%s\n' "$CASE_PREFIX" ;;
            shellenv) [[ "$SHELLENV_FAIL" == 0 ]] || exit 1; printf ':\n' ;;
            bundle) [[ "$BUNDLE_FAIL" == 0 ]] ;;
            *) exit 91 ;;
        esac
        ;;
    getent) printf 'dev:x:1000:1000:Development:%s:%s\n' "$HOME" "$CURRENT_SHELL" ;;
    dscl) printf 'UserShell: %s\n' "$CURRENT_SHELL" ;;
    grep) [[ "$REGISTERED_SHELL" == 1 ]] ;;
    sudo)
        printf 'sudo %s\n' "$*" >> "$CASE_LOG"
        [[ "$SUDO_FAIL" == 0 ]] || exit 1
        [[ "$1" == -n ]] || exit 92
        shift
        case "$1" in
            true) ;;
            env) shift; exec /usr/bin/env "$@" ;;
            tee) cat >/dev/null ;;
            chsh) ;;
            *) exit 93 ;;
        esac
        ;;
    apt-get)
        printf 'apt-get %s (DEBIAN_FRONTEND=%s)\n' "$*" "${DEBIAN_FRONTEND:-}" >> "$CASE_LOG"
        [[ "$APT_FAIL" == 0 ]]
        ;;
    curl)
        printf 'curl %s\n' "$*" >> "$CASE_LOG"
        [[ "$CURL_FAIL" == 0 ]] || exit 22
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == --output ]]; then
                shift
                cat > "$1" <<'INSTALLER'
#!/bin/bash
set -euo pipefail
printf 'installer (NONINTERACTIVE=%s)\n' "${NONINTERACTIVE:-}" >> "$CASE_LOG"
[[ "$INSTALLER_FAIL" == 0 ]] || exit 94
chmod +x "$HOME/.linuxbrew/bin/brew"
INSTALLER
                exit 0
            fi
            shift
        done
        exit 95
        ;;
    git)
        printf 'git %s (GIT_TERMINAL_PROMPT=%s)\n' "$*" "${GIT_TERMINAL_PROMPT:-}" >> "$CASE_LOG"
        [[ "$GIT_FAIL" == 0 ]]
        ;;
    xcode-select|chsh) printf '%s %s\n' "$name" "$*" >> "$CASE_LOG" ;;
    zsh) printf 'interactive-zsh\n' >> "$CASE_LOG"; exit 96 ;;
    *) exit 97 ;;
esac
MOCK
  chmod +x "$case_dir/mock"
  for name in uname id brew getent dscl grep sudo apt-get curl git xcode-select chsh; do
    cp "$case_dir/mock" "$case_dir/bin/$name"
  done
  cp "$case_dir/mock" "$CASE_PREFIX/bin/zsh"
}

run_bootstrap() {
  (
    cd -- "$case_dir/outside"
    env PATH="$case_dir/bin:$original_path" HOME="$case_dir/home" USER=wrong-account \
      /bin/bash "$case_dir/repo with spaces/bootstrap.sh" "$@" </dev/null >"$case_dir/output" 2>&1
  )
}

expect_success() {
  run_bootstrap "$@" || fail 'Bootstrap unexpectedly failed'
}

expect_failure() {
  if run_bootstrap "$@"; then fail 'Bootstrap unexpectedly succeeded'; fi
}

setup_case
expect_success --no-change-shell
assert_no_log sudo
assert_no_log apt-get
assert_no_log interactive-zsh
expect_success --no-change-shell

setup_case
expect_success
assert_log 'sudo -n true'
assert_log 'sudo -n tee -a /etc/shells'
assert_log "sudo -n chsh -s $CASE_PREFIX/bin/zsh dev"
assert_no_log wrong-account
assert_no_log interactive-zsh
first_mutation=''
while IFS= read -r log_line; do
  case "$log_line" in
  'sudo -n true' | 'brew bundle'* | 'git '* | install)
    first_mutation="$log_line"
    break
    ;;
  esac
done <"$CASE_LOG"
[[ "$first_mutation" == 'sudo -n true' ]] || fail 'Shell privilege was not checked before mutations'

setup_case
export CURRENT_SHELL="$CASE_PREFIX/bin/zsh" REGISTERED_SHELL=1 SUDO_FAIL=1
expect_success
assert_no_log sudo

setup_case
export SUDO_FAIL=1
expect_failure
assert_no_log 'brew bundle'
assert_not_installed

setup_case
export MOCK_OS=Darwin MOCK_ARCH=arm64
expect_success --no-change-shell
assert_no_log apt-get
setup_case
export MOCK_OS=Darwin MOCK_ARCH=x86_64
expect_success --no-change-shell
assert_no_log apt-get

setup_case
export BUNDLE_FAIL=1
expect_failure --no-change-shell
assert_no_log 'git '
assert_not_installed

setup_case
export SHELLENV_FAIL=1
expect_failure --no-change-shell
assert_no_log 'brew bundle'

setup_case
export GIT_FAIL=1
expect_failure --no-change-shell
assert_not_installed

setup_case
export MOCK_UID=0
expect_failure --no-change-shell
assert_no_log brew
expect_success --help
assert_no_log brew

setup_case
export MOCK_OS=FreeBSD
expect_failure --no-change-shell
assert_no_log brew
setup_case
expect_failure --unknown
assert_no_log brew

# Standard off-PATH Homebrew must not shadow these isolated fresh-install cases.
# Never run these cases where discovery could find a real Linuxbrew installation.
if [[ ! -x /home/linuxbrew/.linuxbrew/bin/brew ]] && ! PATH="$original_path" command -v brew >/dev/null 2>&1; then
  setup_case
  mv "$case_dir/bin/brew" "$CASE_PREFIX/bin/brew"
  expect_success --no-change-shell
  assert_no_log apt-get
  assert_no_log curl

  setup_case
  mv "$case_dir/bin/brew" "$CASE_PREFIX/bin/brew"
  chmod -x "$CASE_PREFIX/bin/brew"
  expect_success --no-change-shell
  assert_log 'apt-get update (DEBIAN_FRONTEND=noninteractive)'
  assert_log 'apt-get install -y build-essential procps curl file git (DEBIAN_FRONTEND=noninteractive)'
  assert_log 'installer (NONINTERACTIVE=1)'
  assert_log 'brew bundle'

  for failure in APT_FAIL CURL_FAIL INSTALLER_FAIL; do
    setup_case
    mv "$case_dir/bin/brew" "$CASE_PREFIX/bin/brew"
    chmod -x "$CASE_PREFIX/bin/brew"
    export "$failure=1"
    expect_failure --no-change-shell
    assert_no_log 'brew bundle'
    assert_not_installed
    case "$failure" in
    APT_FAIL)
      assert_no_log curl
      assert_no_log installer
      ;;
    CURL_FAIL) assert_no_log installer ;;
    esac
  done
else
  printf 'SKIP: isolated off-PATH/fresh-install cases (real Linuxbrew discoverable)\n'
fi

# Config-only provisioning must not consult package managers or sudo, including
# root templates whose installed dependencies are managed by the platform.
setup_case
export MOCK_UID=0 SUDO_FAIL=1 BUNDLE_FAIL=1 SHELLENV_FAIL=1 CURL_FAIL=1 APT_FAIL=1
expect_success --no-packages --no-shell --git-profile personal
assert_no_log 'brew '
assert_no_log sudo
assert_no_log apt-get
assert_no_log curl
assert_no_log chsh
assert_no_log interactive-zsh

setup_case
expect_failure --git-profile
assert_no_log 'brew '
assert_no_log 'git '
expect_failure --git-profile unknown
assert_no_log 'brew '
assert_no_log 'git '

printf 'PASS: bootstrap regression cases\n'
