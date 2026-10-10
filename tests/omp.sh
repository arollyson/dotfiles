#!/usr/bin/env bash
# Consumer behavior using real Stow/jq/yq and, when installed, native Omp.
# Never starts a session, extensions, models, or MCP, or touches the caller's HOME.
set -euo pipefail
source_repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
for command in stow jq yq; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Required test dependency: %s\n' "$command" >&2
    exit 1
  }
done
native_available=false
if command -v omp >/dev/null 2>&1; then
  native_available=true
else
  printf 'SKIP: native Omp sync/config cases (omp is not installed); installer privacy cases still run.\n'
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-omp-tests.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo" "$scratch/project/.omp" "$scratch/xdg-data" "$scratch/xdg-state" "$scratch/xdg-cache"
export XDG_DATA_HOME="$scratch/xdg-data" XDG_STATE_HOME="$scratch/xdg-state" XDG_CACHE_HOME="$scratch/xdg-cache"
cp "$source_repo/install.sh" "$source_repo/omp-sync.sh" "$repo/"
for package in entrypoints git tmux vim zsh claude omp; do
  cp -R "$source_repo/$package" "$repo/$package"
done
# A project/overlay/profile trap: sync must never read these effective values.
printf 'modelRoles:\n  project-only: private/project\n' >"$scratch/project/.omp/config.yml"
printf 'modelRoles:\n  overlay-only: private/overlay\n' >"$scratch/overlay.yml"
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
same() { cmp -s "$1" "$2" || fail "$3"; }
new_home() {
  home="$scratch/$1"
  mkdir -p "$home"
}
install_home() {
  (
    cd "$scratch/project"
    HOME="$home" bash "$repo/install.sh" "$@"
  ) >"$scratch/install.log" 2>&1 || {
    cat "$scratch/install.log" >&2
    fail 'Omp installation failed'
  }
}
sync_home() {
  (
    cd "$scratch/project"
    HOME="$home" OMP_PROFILE=work PI_PROFILE=work \
      PI_CONFIG_FILES="$scratch/overlay.yml" PI_CODING_AGENT_DIR="$scratch/wrong-agent" PI_CONFIG_DIR=.wrong \
      bash "$repo/omp-sync.sh"
  ) >"$scratch/sync.log" 2>&1 || {
    cat "$scratch/sync.log" >&2
    fail 'Omp sync failed'
  }
}
reject_sync() {
  if (
    cd "$scratch/project"
    HOME="$home" bash "$repo/omp-sync.sh"
  ) >"$scratch/sync.log" 2>&1; then
    fail 'Unsafe Omp sync succeeded'
  fi
}

new_home fresh
install_home
for file in config.yml models.yml lsp.json; do
  [[ -f "$home/.omp/agent/$file" && ! -L "$home/.omp/agent/$file" ]] || fail 'Seeded settings must be regular files'
done
for directory in .omp .omp/agent .omp/agent/extensions .omp/agent/extensions/.lib .omp/agent/themes .omp/agent/rules; do
  [[ -d "$home/$directory" && ! -L "$home/$directory" ]] || fail 'Omp runtime/resource directories must not fold'
done
[[ -L "$home/.omp/agent/extensions/answer.ts" ]] || fail 'Authored extension was not installed individually'
mkdir -p "$home/.omp/agent/sessions" "$home/.omp/agent/cache" "$home/.omp/profiles/private/agent"
printf 'private session\n' >"$home/.omp/agent/sessions/example.jsonl"
printf 'private database\n' >"$home/.omp/agent/agent.db"
printf 'private authentication\n' >"$home/.omp/agent/auth.json"
printf 'private MCP\n' >"$home/.omp/agent/mcp.json"
printf 'private named profile\n' >"$home/.omp/profiles/private/agent/config.yml"
cp "$home/.omp/agent/config.yml" "$scratch/fresh-config"
cp "$home/.omp/agent/models.yml" "$scratch/fresh-models"
install_home
if "$native_available"; then sync_home; fi
same "$home/.omp/agent/config.yml" "$scratch/fresh-config" 'Matching install/sync changed preference bytes'
same "$home/.omp/agent/models.yml" "$scratch/fresh-models" 'Matching install/sync changed model bytes'
[[ ! -d "$home/.local/state/dotfiles/backups" ]] || fail 'Matching install/sync made backups'
[[ "$(cat "$home/.omp/agent/agent.db")" == 'private database' ]] || fail 'Runtime database changed'
[[ "$(cat "$home/.omp/profiles/private/agent/config.yml")" == 'private named profile' ]] || fail 'Named profile changed'
[[ ! -e "$repo/omp/.omp/agent/agent.db" && ! -e "$repo/omp/.omp/agent/sessions" && ! -e "$repo/omp/.omp/agent/auth.json" && ! -e "$repo/omp/.omp/agent/mcp.json" ]] || fail 'Private runtime entered checkout'

new_home legacy-runtime
mkdir -p "$home/.omp/agent"
printf 'private unmigrated database\n' >"$home/.omp/agent/agent.db"
printf '{"private":"legacy settings"}\n' >"$home/.omp/agent/settings.json"
cp "$home/.omp/agent/agent.db" "$scratch/legacy-db"
cp "$home/.omp/agent/settings.json" "$scratch/legacy-settings"
install_home
same "$home/.omp/agent/agent.db" "$scratch/legacy-db" 'Seeding touched the existing runtime database'
same "$home/.omp/agent/settings.json" "$scratch/legacy-settings" 'Seeding migrated private legacy settings'
[[ ! -e "$home/.omp/agent/settings.json.bak" ]] || fail 'Installer launched a settings migration'
[[ ! -e "$home/.omp/agent/config.yml" && ! -e "$home/.omp/agent/config.yaml" ]] ||
  fail 'Installer shadowed private legacy settings with public defaults'

if "$native_available"; then
  new_home legacy-sync
  mkdir -p "$home/.omp/agent"
  printf '{"modelRoles":{"default":"private/previous","work-role":"private/retained"},"private":{"enabled":true}}\n' \
    >"$home/.omp/agent/settings.json"
  printf '{"providers":{"private":{"baseUrl":"https://example.invalid/private","apiKey":"PRIVATE_PLACEHOLDER"}}}\n' \
    >"$home/.omp/agent/models.json"
  cp "$home/.omp/agent/models.json" "$scratch/legacy-models"
  install_home --sync-omp
  (
    cd "$scratch"
    unset PI_CONFIG_FILES PI_PROFILE PI_CODING_AGENT_DIR PI_CONFIG_DIR
    HOME="$home" OMP_PROFILE=default omp config get modelRoles --json
  ) >"$scratch/legacy-roles.json"
  jq -e '.value["work-role"] == "private/retained" and
    .value.default == "anthropic/claude-opus-5-5:high"' \
    "$scratch/legacy-roles.json" >/dev/null ||
    fail 'Explicit sync lost migrated private roles or did not select the requested primary'
  [[ "$(yq '.private.enabled' "$home/.omp/agent/config.yml")" == true ]] ||
    fail 'Native migration lost private legacy fields'
  [[ "$(yq '.providers.private.baseUrl' "$home/.omp/agent/models.yml")" == https://example.invalid/private ]] ||
    fail 'Caps sync shadowed legacy private providers'
  same "$home/.omp/agent/models.json" "$scratch/legacy-models" 'Legacy private models original changed'
fi

new_home existing
mkdir -p "$home/.omp/agent"
cat >"$home/.omp/agent/config.yaml" <<'CONFIG'
# Private global configuration
modelRoles:
  default: private/previous
  work-role: private/retained
  vision: private/vision
  memory: private/memory
task:
  agentModelOverrides:
    scout: private/previous
    work-agent: private/retained
  maxConcurrent: 7
retry:
  fallbackChains:
    default: [private/previous]
    work-role: [private/retained]
  maxRetries: 9
private:
  endpoint: https://example.invalid/private
  enabled: true
providers:
  private:
    headers:
      X-Private: retained
CONFIG
cat >"$home/.omp/agent/models.yaml" <<'MODELS'
# Keep this private provider comment.
providers:
  private:
    baseUrl: https://example.invalid/private
    apiKey: PRIVATE_PLACEHOLDER
    headers:
      X-Private: retained
    models:
      - id: private-model
        contextWindow: 12345
        maxTokens: 123
  anthropic:
    headers:
      X-Private: retained
    modelOverrides:
      claude-opus-5-5:
        contextWindow: 12345
        maxTokens: 123
        name: Private display name
        headers:
          X-Model: retained
      private-model:
        contextWindow: 98765
      claude-haiku-5-5:
        contextWindow: 100000
private-root: retained
MODELS
printf '{"servers":{"private":{"command":"do-not-start"}}}\n' >"$home/.omp/agent/lsp.json"
chmod 640 "$home/.omp/agent/config.yaml" "$home/.omp/agent/models.yaml"
cp "$home/.omp/agent/config.yaml" "$scratch/config.original"
cp "$home/.omp/agent/models.yaml" "$scratch/models.original"
cp "$home/.omp/agent/lsp.json" "$scratch/lsp.original"
install_home
same "$home/.omp/agent/config.yaml" "$scratch/config.original" 'Normal install overwrote local config'
same "$home/.omp/agent/models.yaml" "$scratch/models.original" 'Normal install overwrote local models'
[[ ! -e "$home/.omp/agent/config.yml" && ! -e "$home/.omp/agent/models.yml" ]] || fail 'Installer ignored YAML alternatives'
if "$native_available"; then
  install_home --sync-omp
  # Compare every unowned field semantically, including unknown record members.
  yq -o=json '.' "$home/.omp/agent/config.yaml" >"$scratch/config.after.json"
  yq -o=json '.' "$scratch/config.original" >"$scratch/config.before.json"
  yq -o=json '.' "$repo/omp/.config/dotfiles/omp/preferences.yml" >"$scratch/public.json"
  jq -e --slurpfile original "$scratch/config.before.json" --slurpfile public "$scratch/public.json" \
    '. == ($original[0] * $public[0]) and .modelRoles["project-only"] == null and .modelRoles["overlay-only"] == null' \
    "$scratch/config.after.json" >/dev/null || fail 'Explicit sync lost private settings or serialized effective values'
  yq -o=json '.' "$home/.omp/agent/models.yaml" >"$scratch/models.after.json"
  yq -o=json '.' "$scratch/models.original" >"$scratch/models.before.json"
  yq -o=json '.' "$repo/omp/.config/dotfiles/omp/models.yml" >"$scratch/caps.json"
  jq -e --slurpfile original "$scratch/models.before.json" --slurpfile caps "$scratch/caps.json" \
    '. == ($original[0] * $caps[0])' "$scratch/models.after.json" >/dev/null || fail 'Caps sync lost private provider/model fields'
  grep -Fq '# Keep this private provider comment.' "$home/.omp/agent/models.yaml" || fail 'Caps sync discarded private comment'
  same "$home/.omp/agent/lsp.json" "$scratch/lsp.original" 'Explicit preferences sync changed local LSP'
  case "$(uname -s)" in
  Darwin)
    mode="$(stat -f '%Lp' "$home/.omp/agent/config.yaml")"
    model_mode="$(stat -f '%Lp' "$home/.omp/agent/models.yaml")"
    ;;
  *)
    mode="$(stat -c '%a' "$home/.omp/agent/config.yaml")"
    model_mode="$(stat -c '%a' "$home/.omp/agent/models.yaml")"
    ;;
  esac
  [[ "$mode" == 640 && "$model_mode" == 640 ]] || fail 'Sync changed local file permissions'
  backups=("$home/.local/state/dotfiles/backups/omp-sync."*)
  [[ ${#backups[@]} -eq 1 && -d "${backups[0]}" ]] || fail 'Missing pre-sync backup'
  same "${backups[0]}/config.yaml" "$scratch/config.original" 'Private config backup differs'
  same "${backups[0]}/models.yaml" "$scratch/models.original" 'Private models backup differs'
  cp "$home/.omp/agent/config.yaml" "$scratch/config.synced"
  cp "$home/.omp/agent/models.yaml" "$scratch/models.synced"
  sync_home
  same "$home/.omp/agent/config.yaml" "$scratch/config.synced" 'Idempotent sync rewrote local config'
  same "$home/.omp/agent/models.yaml" "$scratch/models.synced" 'Idempotent sync rewrote local models'
  backups=("$home/.local/state/dotfiles/backups/omp-sync."*)
  [[ ${#backups[@]} -eq 1 ]] || fail 'Idempotent sync made another backup'
  (
    cd "$scratch"
    unset PI_CONFIG_FILES PI_PROFILE PI_CODING_AGENT_DIR PI_CONFIG_DIR
    HOME="$home" OMP_PROFILE=default omp config get modelRoles --json
  ) >"$scratch/native-roles.json"
  jq -e --slurpfile global "$scratch/config.after.json" '.value == $global[0].modelRoles' \
    "$scratch/native-roles.json" >/dev/null || fail 'Native Omp did not observe the synchronized global roles'
fi

# Fail closed before native startup or mutation, including inactive YAML siblings.
for file in config.yml config.yaml models.yml models.yaml; do
  new_home "symlink-${file}"
  mkdir -p "$home/.omp/agent"
  cp "$scratch/config.original" "$scratch/symlink-target"
  ln -s "$scratch/symlink-target" "$home/.omp/agent/$file"
  if "$native_available"; then reject_sync; fi
  same "$scratch/symlink-target" "$scratch/config.original" 'Sync changed a symlink target'
  if HOME="$home" bash "$repo/install.sh" --backup >"$scratch/install.log" 2>&1; then fail 'Installer accepted linked settings'; fi
  [[ ! -e "$home/.zprofile" ]] || fail 'Rejected settings changed installer entrypoints'
done
new_home folded
ln -s "$repo/omp/.omp" "$home/.omp"
if "$native_available"; then reject_sync; fi
if HOME="$home" bash "$repo/install.sh" --backup >"$scratch/install.log" 2>&1; then fail 'Installer accepted folded runtime'; fi
for directory in .omp/agent .omp/agent/extensions .omp/agent/extensions/.lib .omp/agent/themes .omp/agent/rules; do
  new_home "folded-${RANDOM}"
  mkdir -p "$home/${directory%/*}" "$scratch/external-directory"
  ln -s "$scratch/external-directory" "$home/$directory"
  if HOME="$home" bash "$repo/install.sh" --backup >"$scratch/install.log" 2>&1; then
    fail 'Installer accepted a folded Omp runtime/resource directory'
  fi
  [[ ! -e "$home/.zprofile" ]] || fail 'Rejected folded directory changed entrypoints'
done
new_home ancestor
mkdir -p "$repo/private-home/.omp/agent"
ln -s "$repo/private-home" "$home/linked-home"
home="$home/linked-home"
if "$native_available"; then reject_sync; fi
[[ ! -e "$repo/private-home/.omp/agent/config.yml" ]] || fail 'Sync wrote through checkout ancestor'
if HOME="$home" bash "$repo/install.sh" >"$scratch/install.log" 2>&1; then fail 'Installer accepted checkout ancestor'; fi
if "$native_available"; then
  for malformed in 'modelRoles: [unterminated' '- scalar-root' $'theme: x\n---\ntheme: y'; do
    new_home "malformed-${RANDOM}"
    mkdir -p "$home/.omp/agent"
    printf '%s\n' "$malformed" >"$home/.omp/agent/config.yml"
    cp "$home/.omp/agent/config.yml" "$scratch/malformed.original"
    reject_sync
    same "$home/.omp/agent/config.yml" "$scratch/malformed.original" 'Malformed config was changed/quarantined'
  done
  new_home malformed-models
  mkdir -p "$home/.omp/agent"
  printf 'theme:\n  dark: private\n' >"$home/.omp/agent/config.yml"
  printf 'providers:\n  anthropic: private-scalar\n' >"$home/.omp/agent/models.yml"
  cp "$home/.omp/agent/config.yml" "$scratch/malformed.original"
  reject_sync
  same "$home/.omp/agent/config.yml" "$scratch/malformed.original" 'Rejected models changed preferences'
fi
printf 'PASS: Omp installer regular settings and runtime privacy\n'
if "$native_available"; then printf 'PASS: native Omp explicit sync and private preservation\n'; fi
