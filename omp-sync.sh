#!/usr/bin/env bash
# Explicitly apply public preferences to regular, default-profile local settings.
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() {
  printf 'omp-sync: %s\n' "$*" >&2
  exit 1
}
case "${1:-}" in
--help | -h)
  printf '%s\n' 'Usage: bash omp-sync.sh' \
    'Explicitly sync public preferences and exact Claude context caps.' \
    'Only ~/.omp/agent default-profile settings are changed; named profiles, project settings,' \
    'overlays, providers, private fields, and unowned model roles remain local.' \
    'Requires Omp, jq, and Mike Farah yq v4. Backups stay outside the checkout.'
  exit 0
  ;;
'') [[ $# -eq 0 ]] || fail 'Unexpected arguments; see --help.' ;;
*) fail 'Unexpected arguments; see --help.' ;;
esac
for command in omp jq yq; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing required command: $command."
done
case "$(yq --version)" in
*'github.com/mikefarah/yq/'*'version v4.'*) ;;
*) fail 'Mike Farah yq v4 is required; no settings were changed.' ;;
esac
[[ -d "$HOME" ]] || fail 'HOME must be an existing directory.'

# Resolve the deepest existing ancestor, including links, before making paths.
# No local settings, private temporaries, or backups may resolve into the repo.
outside_repo() {
  local path="$1" suffix='' part
  while [[ ! -d "$path" ]]; do
    part="${path##*/}"
    suffix="/$part$suffix"
    path="${path%/*}"
    [[ -n "$path" ]] || path=/
  done
  path="$(cd -- "$path" && pwd -P)$suffix"
  case "$path/" in "$repo_dir/"*) fail 'Refusing a local destination inside the checkout.' ;; esac
  printf '%s\n' "$path"
}
agent_dir="$HOME/.omp/agent"
for path in "$HOME/.omp" "$agent_dir"; do
  [[ ! -L "$path" ]] || fail 'Refusing a folded Omp runtime directory.'
  [[ ! -e "$path" || -d "$path" ]] || fail 'An Omp runtime path is not a directory.'
  outside_repo "$path" >/dev/null
done
for path in "${XDG_DATA_HOME:-$HOME/.local/share}/omp" \
  "${XDG_STATE_HOME:-$HOME/.local/state}/omp" "${XDG_CACHE_HOME:-$HOME/.cache}/omp"; do
  outside_repo "$path" >/dev/null
done
for name in config.yml config.yaml settings.json models.yml models.yaml models.json; do
  path="$agent_dir/$name"
  [[ ! -L "$path" ]] || fail "Refusing symlink settings: $name."
  [[ ! -e "$path" || -f "$path" ]] || fail "Refusing non-regular settings: $name."
  outside_repo "$path" >/dev/null
done
config_file="$agent_dir/config.yml"
[[ -e "$config_file" || ! -e "$agent_dir/config.yaml" ]] || config_file="$agent_dir/config.yaml"
models_file="$agent_dir/models.yml"
[[ -e "$models_file" || ! -e "$agent_dir/models.yaml" ]] || models_file="$agent_dir/models.yaml"
blueprints="$repo_dir/omp/.config/dotfiles/omp"
backup_root="$(outside_repo "$HOME/.local/state/dotfiles/backups")"
temp_root="$(outside_repo "${TMPDIR:-/tmp}")"
umask 077
work_dir="$(mktemp -d "$temp_root/dotfiles-omp-sync.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
file_mode() {
  case "$(uname -s)" in Darwin) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac
}
# Scope every native call independently; inherited profile/root/overlay selectors
# never change the target. Neutral cwd prevents project configuration discovery.
native_config() {
  (
    cd -- "$work_dir"
    unset PI_CONFIG_FILES PI_PROFILE PI_CODING_AGENT_DIR PI_CONFIG_DIR
    export OMP_PROFILE=default
    omp config "$@"
  )
}

# Reject malformed/multi-document YAML before native startup can quarantine it.
# Keep all private parsed data in the private temporary directory, never stdout.
parse_mapping() {
  local input="$1" output="$2"
  yq eval -o=json '.' "$input" 2>"$work_dir/parse.log" |
    jq -se 'if length == 1 and .[0] == null then {} elif length == 1 and (.[0] | type) == "object" then .[0] else error("mapping required") end' \
      >"$output" 2>>"$work_dir/parse.log" || fail 'Settings must contain one valid YAML mapping; no settings were changed.'
}
parse_mapping "$blueprints/preferences.yml" "$work_dir/preferences.json"
parse_mapping "$blueprints/models.yml" "$work_dir/caps.json"
# Validate model files before any native legacy-settings migration.
models_source="$models_file"
[[ -f "$models_source" || ! -f "$agent_dir/models.json" ]] || models_source="$agent_dir/models.json"
if [[ -f "$models_source" ]]; then
  cp -p -- "$models_source" "$work_dir/models.original"
  parse_mapping "$models_source" "$work_dir/models.json"
else
  printf '{}\n' >"$work_dir/models.json"
fi
# Let Omp migrate legacy global settings before applying selected preferences.
# Seeding YAML first would silently shadow settings.json or settings in agent.db.
if [[ ! -e "$config_file" ]]; then
  if [[ -f "$agent_dir/settings.json" ]]; then
    parse_mapping "$agent_dir/settings.json" "$work_dir/legacy-settings.json"
  fi
  native_config get modelRoles --json >"$work_dir/native.json" 2>"$work_dir/native.log" ||
    fail 'Native legacy settings migration failed; public preferences were not applied.'
fi
if [[ "$models_source" != "$models_file" ]]; then
  # JSON is valid YAML; retain the private original, fields, and permissions.
  if [[ -e "$models_file" ]] || ! cmp -s "$models_source" "$work_dir/models.original"; then
    fail 'Legacy models changed during migration; refusing to overwrite local edits.'
  fi
  cp -p -- "$work_dir/models.original" "$models_file"
fi
if [[ -f "$config_file" ]]; then
  cp -p -- "$config_file" "$work_dir/config.original"
  config_mode="$(file_mode "$config_file")"
  parse_mapping "$config_file" "$work_dir/config.json"
else
  config_mode=600
  printf '{}\n' >"$work_dir/config.json"
fi

# Each record is one registered setting, not an invented dotted child key.
# Merge against the GLOBAL file, never the effective CLI response: even ambient
# per-setting environment values must not be copied into persistent settings.
jq -r 'def entries_at($prefix): to_entries[] | .key as $key |
  ($prefix + [$key]) as $path |
  if ($path | join(".")) as $id |
    (["modelRoles", "task.agentModelOverrides", "retry.fallbackChains"] | index($id)) != null
  then $path | join(".")
  elif (.value | type) == "object" then .value | entries_at($path)
  else $path | join(".") end;
  entries_at([])' "$work_dir/preferences.json" >"$work_dir/keys"
: >"$work_dir/plan"
while IFS= read -r key; do
  jq -c --arg key "$key" --slurpfile public "$work_dir/preferences.json" '
    ($key | split(".")) as $path | getpath($path) as $old |
    ($public[0] | getpath($path)) as $owned |
    if ($owned | type) == "object" then
      if $old == null or ($old | type) == "object" then ($old // {}) * $owned
      else error("record setting is not a mapping") end
    else $owned end' "$work_dir/config.json" >"$work_dir/value" 2>"$work_dir/plan.log" ||
    fail 'An owned record setting is not a mapping; no settings were changed.'
  if ! jq -e --arg key "$key" --slurpfile desired "$work_dir/value" \
    'getpath($key | split(".")) == $desired[0]' "$work_dir/config.json" >/dev/null; then
    jq -cn --arg key "$key" --slurpfile value "$work_dir/value" \
      '{key: $key, value: $value[0]}' >>"$work_dir/plan"
  fi
done <"$work_dir/keys"

# Deep merging the cap-only blueprint changes no provider/header/model fields.
# Reject scalar/array ancestors instead of destroying malformed private data.
jq -e --slurpfile caps "$work_dir/caps.json" '
  . as $local | all($caps[0] | paths(scalars); . as $path |
    all(range(1; $path | length); . as $n |
      ($local | getpath($path[0:$n])) as $parent |
      $parent == null or ($parent | type) == "object"))' \
  "$work_dir/models.json" >/dev/null 2>"$work_dir/models.log" ||
  fail 'A model override ancestor is not a mapping; no settings were changed.'
models_changed=false
if ! jq -e --slurpfile caps "$work_dir/caps.json" '. == (. * $caps[0])' "$work_dir/models.json" >/dev/null; then
  models_changed=true
  if [[ -f "$models_file" ]]; then
    cp -p -- "$models_file" "$work_dir/models.new"
  else
    printf '{}\n' >"$work_dir/models.new"
    chmod 600 "$work_dir/models.new"
  fi
  yq eval-all -i 'select(fileIndex == 0) * select(fileIndex == 1)' \
    "$work_dir/models.new" "$blueprints/models.yml" 2>"$work_dir/models.log" ||
    fail 'Could not merge model context caps; no settings were changed.'
  if [[ -f "$work_dir/models.original" ]]; then
    chmod "$(file_mode "$work_dir/models.original")" "$work_dir/models.new"
  fi
fi

check_unchanged() {
  local destination="$1" original="$2"
  [[ ! -L "$destination" ]] || fail 'Settings became a symlink during sync; refusing to write.'
  if [[ -f "$original" ]]; then
    if [[ ! -f "$destination" ]] || ! cmp -s "$destination" "$original"; then
      fail 'Settings changed during sync; refusing to overwrite local edits.'
    fi
  else
    [[ ! -e "$destination" ]] || fail 'Settings appeared during sync; refusing to overwrite local edits.'
  fi
}
check_unchanged "$config_file" "$work_dir/config.original"
check_unchanged "$models_file" "$work_dir/models.original"
if [[ ! -s "$work_dir/plan" ]] && ! "$models_changed"; then
  printf 'Omp preferences already match; no existing files changed.\n'
  exit 0
fi
# Missing config is safely seeded before config CLI startup (no legacy DB or JSON
# migration). The seed already matches; normal installer reruns never use this CLI.
mkdir -p -- "$agent_dir"
if [[ ! -e "$config_file" ]]; then
  cp -- "$blueprints/preferences.yml" "$config_file"
  chmod 600 "$config_file"
  : >"$work_dir/plan"
fi
# Validate registered keys before the first setter, without exposing local values.
while IFS= read -r entry; do
  key="$(printf '%s\n' "$entry" | jq -r '.key')"
  if ! native_config get "$key" --json >"$work_dir/native.json" 2>"$work_dir/native.log" ||
    ! jq -e --arg key "$key" '.key == $key and has("value")' "$work_dir/native.json" >/dev/null; then
    fail 'Native Omp configuration lookup failed; no setters were run.'
  fi
done <"$work_dir/plan"

backup_dir=''
if { [[ -s "$work_dir/plan" && -f "$work_dir/config.original" ]]; } ||
  { [[ "$models_changed" == true && -f "$work_dir/models.original" ]]; }; then
  mkdir -p -- "$backup_root"
  backup_dir="$(mktemp -d "$backup_root/omp-sync.XXXXXX")"
  if [[ -s "$work_dir/plan" && -f "$work_dir/config.original" ]]; then
    cp -p -- "$work_dir/config.original" "$backup_dir/${config_file##*/}"
  fi
  if "$models_changed" && [[ -f "$work_dir/models.original" ]]; then
    cp -p -- "$work_dir/models.original" "$backup_dir/${models_file##*/}"
  fi
fi
if [[ -s "$work_dir/plan" ]]; then
  check_unchanged "$config_file" "$work_dir/config.original"
  while IFS= read -r entry; do
    key="$(printf '%s\n' "$entry" | jq -r '.key')"
    value="$(printf '%s\n' "$entry" | jq -c '.value')"
    native_config set "$key" "$value" >"$work_dir/native.log" 2>&1 ||
      fail 'Native Omp setter failed; originals are retained in the private backup directory.'
    chmod "$config_mode" "$config_file"
  done <"$work_dir/plan"
fi
if "$models_changed"; then
  check_unchanged "$models_file" "$work_dir/models.original"
  # Preserve the staged source mode while publishing atomically on this filesystem.
  model_stage="$(mktemp "$agent_dir/.models-sync.XXXXXX")"
  cp -p -- "$work_dir/models.new" "$model_stage"
  mv -f -- "$model_stage" "$models_file"
fi
if [[ -n "$backup_dir" ]]; then
  printf 'Omp preferences synchronized; private backups: %s\n' "$backup_dir"
else
  printf 'Omp preferences already match; no existing files changed.\n'
fi
