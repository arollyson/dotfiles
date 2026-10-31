#!/usr/bin/env bash
# Create the local Hindsight secrets outside the checkout; never overwrite or print them.
set -euo pipefail
umask 077

secrets_dir="$HOME/.config/dotfiles-local/hindsight"
temporary_file=''

log() { printf 'setup-secrets: %s\n' "$1"; }
fail() {
  printf 'setup-secrets: %s\n' "$1" >&2
  exit 1
}
cleanup() { [[ -z "$temporary_file" ]] || rm -f -- "$temporary_file"; }
trap cleanup EXIT

command -v openssl >/dev/null 2>&1 || fail 'required command not found: openssl'
[[ ! -L "$secrets_dir" ]] || fail "refusing symlinked secrets directory: $secrets_dir"
[[ ! -e "$secrets_dir" || -d "$secrets_dir" ]] || fail "expected a directory: $secrets_dir"
mkdir -p -- "$secrets_dir"
chmod 700 "$secrets_dir"

# Returns 0 when a valid secret already exists, 1 when it must be created.
existing_secret() {
  local path="$secrets_dir/$1"
  [[ -e "$path" || -L "$path" ]] || return 1
  [[ ! -L "$path" && -f "$path" ]] || fail "refusing non-regular secret file: $path"
  [[ -s "$path" ]] || fail "refusing empty secret file: $path"
  chmod 600 "$path" || fail "could not restrict $path"
  log "kept existing $1"
}

# link(2) fails instead of replacing a secret that appeared concurrently.
install_secret() {
  local path="$secrets_dir/$1"
  chmod 600 "$temporary_file"
  ln -- "$temporary_file" "$path" 2>/dev/null || fail "secret appeared concurrently; left it unchanged: $path"
  rm -f -- "$temporary_file"
  temporary_file=''
  log "created $1"
}

for name in hindsight_api_token dashboard_access_key; do
  existing_secret "$name" && continue
  temporary_file="$(mktemp "$secrets_dir/.$name.tmp.XXXXXX")"
  openssl rand -hex 32 >"$temporary_file"
  install_secret "$name"
done

if ! existing_secret litellm_api_key; then
  [[ -t 0 ]] || fail 'missing litellm_api_key; rerun interactively to enter the LiteLLM relay key'
  IFS= read -r -s -p 'LiteLLM relay API key: ' relay_key || fail 'could not read litellm_api_key'
  printf '\n'
  [[ -n "$relay_key" ]] || fail 'litellm_api_key cannot be empty'
  temporary_file="$(mktemp "$secrets_dir/.litellm_api_key.tmp.XXXXXX")"
  printf '%s\n' "$relay_key" >"$temporary_file"
  unset relay_key
  install_secret litellm_api_key
fi

log "Hindsight secrets are ready in $secrets_dir"
