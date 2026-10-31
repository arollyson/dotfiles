#!/usr/bin/env bash
# refusal-fallback.ts against real omp and an offline mock provider, in a
# scratch HOME. Skips when omp or node is missing (CI installs neither).
#
# The security target's key comes from a slow `!command`, so a handler that
# awaits credential resolution before installing its override loses the race
# against omp's retry and the cyber cases fail.
set -euo pipefail
source_repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixtures="$source_repo/tests/fixtures/refusal-fallback"
extension="$source_repo/omp/.omp/agent/extensions/refusal-fallback.ts"
for command in omp node; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'SKIP: refusal-fallback cases (%s is not installed)\n' "$command"
    exit 0
  fi
done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-refusal-tests.XXXXXX")"
server_pid=''
cleanup() {
  if [[ -n $server_pid ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  # Scoped to the directory mktemp just created.
  if [[ $scratch == "${TMPDIR:-/tmp}"/dotfiles-refusal-tests.* ]]; then
    find "$scratch" -depth -delete
  fi
}
trap cleanup EXIT
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# The server prints its port once listening; the FIFO read blocks until then
# and returns empty if the server exits first.
mkfifo "$scratch/port.fifo"
node "$fixtures/server.mjs" >"$scratch/port.fifo" &
server_pid=$!
port=''
read -r port <"$scratch/port.fifo" || true
[[ -n $port ]] || fail 'fixture server did not report a port'

export HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/home/.config" XDG_DATA_HOME="$scratch/data" \
  XDG_STATE_HOME="$scratch/state" XDG_CACHE_HOME="$scratch/cache" REFUSAL_FIXTURE_PORT="$port"
mkdir -p "$HOME/.omp/agent" "$scratch/project"
cat >"$HOME/.omp/agent/config.yml" <<'YAML'
advisor:
  enabled: false
modelRoles:
  security: slowkey/target
retry:
  baseDelayMs: 1
  maxRetries: 1
  fallbackChains:
    default: [mock/generic]
YAML
cat >"$HOME/.omp/agent/models.yml" <<YAML
providers:
  slowkey:
    baseUrl: http://127.0.0.1:$port
    api: anthropic-messages
    apiKey: "!sleep 1 && echo fixture-key"
    models:
      - { id: target, reasoning: true, contextWindow: 200000, maxTokens: 4096 }
      - { id: target-slow, reasoning: true, contextWindow: 200000, maxTokens: 4096 }
YAML

omp_args=(--no-title --no-extensions -e "$fixtures/providers.ts" -e "$extension")
roles() {
  printf 'modelRoles:\n  default: %s\n' "$1" >"$scratch/roles.yml"
  [[ -z ${2:-} ]] || printf '  security: %s\n' "$2" >>"$scratch/roles.yml"
}
answer() {
  roles "$1"
  (cd "$scratch/project" && omp -p "${omp_args[@]}" --config "$scratch/roles.yml" 'say hi' 2>"$scratch/stderr") |
    tail -n 1 || true
}
expect() {
  [[ $2 == "$3" ]] || fail "$1: expected '$3', got '$2' ($(tail -n 3 "$scratch/stderr" | tr '\n' ' '))"
  printf 'ok    %s\n' "$1"
}

expect 'Anthropic cyber refusal retries on the security role' "$(answer mock/cyber)" TARGET
expect 'Anthropic non-cyber refusal keeps the normal chain' "$(answer mock/bio)" GENERIC
expect 'OpenAI cyber_policy retries on the security role' "$(answer mockoai/sol-cyber)" TARGET
expect 'OpenAI content filter keeps the normal chain' "$(answer mockoai/sol-filter)" GENERIC

# A block that never retries must not leave the override behind for the next
# ordinary failure on the same model (flaky models rate-limit after a block).
rpc() {
  roles "$2" "${3:-}"
  (cd "$scratch/project" && node "$fixtures/rpc.mjs" "$1" "${omp_args[@]}" --config "$scratch/roles.yml" 2>"$scratch/stderr") |
    tail -n 1 || true
}
expect 'Retry-disabled block releases the override' "$(rpc disabled mock/flaky-disabled)" 'completed GENERIC'
expect 'Aborted fallback retry releases the override' "$(rpc abort mock/flaky-abort slowkey/target-slow)" 'completed GENERIC'
