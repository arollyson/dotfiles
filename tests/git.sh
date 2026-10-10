#!/usr/bin/env bash
# Real Git, Git LFS, and gh consumers; all repositories and credentials are local.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
for dependency in git git-lfs gh stow; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'Required test dependency: %s (run bootstrap.sh first)\n' "$dependency" >&2
    exit 1
  }
done
git_bin="$(command -v git)"
gh_bin="$(command -v gh)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-test.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/portable bin" "$scratch/git-only" "$scratch/empty-exec"

# Do not consult the caller's configuration, keychain, authentication, or repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_CONFIG
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM
unset GIT_EXEC_PATH GIT_TEMPLATE_DIR
unset GIT_ASKPASS SSH_ASKPASS GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_DEBUG
unset GIT_LFS_SKIP_SMUDGE GIT_LFS_SKIP_DOWNLOAD_ERRORS
export HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/home/.config"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export GH_CONFIG_DIR="$scratch/home/gh" GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0
export GIT_TEMPLATE_DIR="$scratch/empty-exec"
mkdir -p "$GH_CONFIG_DIR"
bash "$repo_dir/install.sh" >"$scratch/install.log" 2>&1
cd -- "$HOME"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# The real installer must expose the shared filters to a new, ordinary repo.
work="$scratch/local repository"
git init -q "$work"
git -C "$work" config user.name 'Dotfiles regression'
git -C "$work" config user.email 'dotfiles-test@example.invalid'
git -C "$work" config commit.gpgsign false
printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' >"$work/.gitattributes"
printf 'Local LFS content\000with binary bytes\377\n' >"$scratch/expected.bin"
cp "$scratch/expected.bin" "$work/payload.bin"
git -C "$work" add .gitattributes payload.bin
git -C "$work" commit -qm 'Local LFS round trip'
git -C "$work" show HEAD:payload.bin >"$scratch/pointer"
git lfs pointer --check --strict --file="$scratch/pointer" || fail 'LFS add did not store a pointer'
[[ "$(git -C "$work" lfs ls-files -n)" == payload.bin ]] || fail 'LFS did not recognize the tracked file'
rm "$work/payload.bin"
git -C "$work" checkout -- payload.bin
cmp -s "$scratch/expected.bin" "$work/payload.bin" || fail 'LFS process checkout lost the original content'

# Git versions without the process protocol still use the clean/smudge drivers.
clean_config="$scratch/clean.gitconfig"
cp "$repo_dir/git/.config/dotfiles/gitconfig" "$clean_config"
git config --file "$clean_config" --unset filter.lfs.process
printf 'Legacy filter round trip\000\376\n' >"$scratch/expected.bin"
cp "$scratch/expected.bin" "$work/payload.bin"
GIT_CONFIG_GLOBAL="$clean_config" git -C "$work" add payload.bin
git -C "$work" commit -qm 'Local clean and smudge round trip'
git -C "$work" show HEAD:payload.bin >"$scratch/pointer"
git lfs pointer --check --strict --file="$scratch/pointer" || fail 'LFS clean did not store a pointer'
rm "$work/payload.bin"
GIT_CONFIG_GLOBAL="$clean_config" git -C "$work" checkout -- payload.bin
cmp -s "$scratch/expected.bin" "$work/payload.bin" || fail 'LFS smudge checkout lost the original content'

# A missing required filter must fail, not silently commit unfiltered content.
ln -s "$git_bin" "$scratch/git-only/git"
printf 'This must not enter the index without LFS\n' >"$work/missing.bin"
if PATH="$scratch/git-only" GIT_EXEC_PATH="$scratch/empty-exec" \
  "$git_bin" -C "$work" add missing.bin >"$scratch/missing-lfs.log" 2>&1; then
  fail 'Missing required LFS process unexpectedly allowed git add'
fi
if PATH="$scratch/git-only" GIT_EXEC_PATH="$scratch/empty-exec" \
  GIT_CONFIG_GLOBAL="$clean_config" "$git_bin" -C "$work" add missing.bin >"$scratch/missing-lfs-clean.log" 2>&1; then
  fail 'Missing required LFS clean unexpectedly allowed git add'
fi
if git -C "$work" ls-files --error-unmatch missing.bin >/dev/null 2>&1; then
  fail 'A failed required filter left unfiltered content in the index'
fi

# Only a PATH-discovered real gh can answer. Its token lookup is entirely local;
# this synthetic value is intentionally not a usable GitHub credential.
ln -s "$gh_bin" "$scratch/portable bin/gh"
credential_path="$scratch/portable bin:/usr/bin:/bin:/usr/sbin:/sbin"
export GH_TOKEN=dotfiles-test-not-a-real-github-token

fill() {
  printf 'protocol=https\nhost=%s\n\n' "$1" |
    PATH="$credential_path" "$git_bin" credential fill >"$scratch/credential" 2>"$scratch/credential-error"
}

expect_credential() {
  local host="$1" username="$2" password="$3"
  fill "$host" || fail "Could not fill local credentials for $host"
  # Git's response may contain additional fields on newer releases.
  grep -Fxq "protocol=https" "$scratch/credential" || fail "Wrong protocol for $host"
  grep -Fxq "host=$host" "$scratch/credential" || fail "Wrong host for $host"
  grep -Fxq "username=$username" "$scratch/credential" || fail "Wrong credential username for $host"
  grep -Fxq "password=$password" "$scratch/credential" || fail "Wrong credential password for $host"
}

for host in github.com gist.github.com; do
  expect_credential "$host" x-access-token "$GH_TOKEN"
  if printf 'protocol=https\nhost=%s\n\n' "$host" |
    PATH="$scratch/git-only" GIT_EXEC_PATH="$scratch/empty-exec" \
      "$git_bin" credential fill >"$scratch/missing-gh.log" 2>&1; then
    fail "Credentials for $host unexpectedly succeeded with no gh on PATH"
  fi
done

# Use Git's real credential store, not a mock helper, to model an existing
# generic machine-local helper such as GCM. All entries are synthetic.
local_config="$HOME/.config/dotfiles-local/gitconfig"
mkdir -p "$(dirname -- "$local_config")"
generic_store="$scratch/generic credentials"
local_store="$scratch/host credentials"
entrypoint_store="$scratch/entrypoint credentials"

store_credential() {
  printf 'protocol=https\nhost=%s\nusername=%s\npassword=%s\n\n' "$2" "$3" "$4" |
    "$git_bin" credential-store --file="$1" store
}

for host in github.com gist.github.com example.invalid; do
  store_credential "$generic_store" "$host" generic-user generic-test-password
done
git config --file "$local_config" --add credential.helper "store --file='$generic_store'"

# A generic helper added later does not supersede gh for a host that gh handles.
# Other hosts must still retain their generic machine-local integration.
for host in github.com gist.github.com; do
  expect_credential "$host" x-access-token "$GH_TOKEN"
done
expect_credential example.invalid generic-user generic-test-password

# A local host-specific reset replaces gh and the generic helper, even while gh
# has a token. These are the preservation steps needed for an existing GCM user.
for host in github.com gist.github.com; do
  store_credential "$local_store" "$host" local-user local-test-password
  git config --file "$local_config" --add "credential.https://$host.helper" ''
  git config --file "$local_config" --add "credential.https://$host.helper" "store --file='$local_store'"
  expect_credential "$host" local-user local-test-password
done
expect_credential example.invalid generic-user generic-test-password

# Existing settings after the managed block remain the final override layer.
store_credential "$entrypoint_store" github.com entrypoint-user entrypoint-test-password
git config --file "$HOME/.gitconfig" --add credential.https://github.com.helper ''
git config --file "$HOME/.gitconfig" --add credential.https://github.com.helper "store --file='$entrypoint_store'"
expect_credential github.com entrypoint-user entrypoint-test-password
expect_credential gist.github.com local-user local-test-password

printf 'Git LFS and credential integration regressions passed.\n'
