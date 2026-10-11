#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
names=(zprofile zshrc gitconfig)
begin_marker='# >>> dotfiles managed >>>'
end_marker='# <<< dotfiles managed <<<'
work_dir=''
staged=()
migrate_local=false
legacy_env="$repo_dir/zsh/.zprofile.d/env.work"
local_env=''
migration_ready=false
backup_conflicts=false
git_profile=''
sync_omp=false
profile_begin='# >>> dotfiles git identity >>>'
profile_end='# <<< dotfiles git identity <<<'
conflict_targets=()
conflict_backups=()
stow_done=false
packages=(git tmux vim zsh agents claude)
[[ ! -d "$repo_dir/omp" ]] || packages+=(omp)

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --migrate-local) migrate_local=true ;;
  --backup) backup_conflicts=true ;;
  --sync-omp) sync_omp=true ;;
  --git-profile)
    [[ $# -ge 2 ]] || die '--git-profile requires personal or work.'
    git_profile="$2"
    case "$git_profile" in personal | work) ;; *) die '--git-profile requires personal or work.' ;; esac
    shift
    ;;
  --help)
    printf 'Usage: %s [--backup] [--migrate-local] [--git-profile personal|work] [--sync-omp]\n' "$0"
    printf 'Back up conflicting local Stow files outside the checkout; preserve all entrypoint tails.\n'
    printf 'Work identity must be provisioned in ~/.config/dotfiles-local/gitconfig.\n'
    printf 'Opt in to moving legacy zsh/.zprofile.d/env.work into ~/.config/dotfiles-local/env.zsh.\n'
    printf 'Omp settings are regular local files, seeded only when absent; --sync-omp explicitly applies public preferences.\n'
    exit 0
    ;;
  *) die "Unknown option: $1 (see $0 --help)" ;;
  esac
  shift
done

cleanup() {
  local file
  local index=0
  if ! "$stow_done"; then
    for file in ${conflict_targets[@]+"${conflict_targets[@]}"}; do
      if [[ ! -e "$file" && ! -L "$file" ]]; then
        cp -p -- "${conflict_backups[$index]}" "$file"
      else
        printf 'Local conflict backup retained at %s; destination changed: %s\n' "${conflict_backups[$index]}" "$file" >&2
      fi
      index=$((index + 1))
    done
  fi
  for file in ${staged[@]+"${staged[@]}"}; do
    [[ -z "$file" ]] || rm -f -- "$file"
  done
  [[ -z "$work_dir" ]] || rm -rf -- "$work_dir"
}
trap cleanup EXIT

check_entrypoint() {
  local target="$1"
  [[ ! -L "$target" ]] || die "Refusing symlink $target; no symlink target was changed."
  [[ ! -e "$target" || -f "$target" ]] || die "Refusing non-regular entrypoint $target."
}

check_unchanged() {
  local name="$1" target="$HOME/.$1"
  check_entrypoint "$target"
  if [[ -f "$work_dir/$name.original" ]]; then
    cmp -s "$target" "$work_dir/$name.original" || die "Entrypoint changed during installation: $target; refusing to overwrite it."
  else
    [[ ! -e "$target" ]] || die "Entrypoint appeared during installation: $target; refusing to overwrite it."
  fi
}

# Return byte offsets, not rewritten text: even local files without a final
# newline retain their exact contents. Only one complete, exact block is safe.
managed_span() {
  LC_ALL=C awk -v begin="${2:-$begin_marker}" -v end="${3:-$end_marker}" '
        BEGIN { offset = 0 }
        $0 == begin {
            if (state != 0) bad = 1
            first = offset
            state = 1
        }
        $0 == end {
            if (state != 1) bad = 1
            last = offset + length($0) + 1
            state = 2
        }
        /^[[:space:]]*# (>>>|<<<) dotfiles (managed|git identity)/ {
            if ((begin ~ /git identity/ && $0 ~ /git identity/) ||
                (begin !~ /git identity/ && $0 ~ /managed/)) {
                if ($0 != begin && $0 != end) bad = 1
            }
        }
        { offset += length($0) + 1 }
        END {
            if (bad || state == 1) exit 1
            if (state == 2) print first, last
            else print -1, -1
        }
    ' "$1"
}

# Resolve existing parent symlinks before creating the backup directory.
backup_location() {
  local path="${1:-$HOME/.local/state/dotfiles/backups}" suffix='' part
  while [[ ! -d "$path" ]]; do
    part="${path##*/}"
    suffix="/$part$suffix"
    path="${path%/*}"
    [[ -n "$path" ]] || path=/
  done
  path="$(cd -- "$path" && pwd -P)$suffix"
  case "$path/" in
  "$repo_dir/"*) die "Refusing to store local files or backups inside repository $repo_dir." ;;
  esac
  printf '%s\n' "$path"
}

file_mode() {
  case "$(uname -s)" in
  Darwin) stat -f '%Lp' "$1" ;;
  *) stat -c '%a' "$1" ;;
  esac
}

check_migration_unchanged() {
  [[ ! -L "$legacy_env" && -f "$legacy_env" ]] &&
    cmp -s "$legacy_env" "$work_dir/env.work.original" &&
    [[ "$(file_mode "$legacy_env")" == "$legacy_mode" ]] ||
    die "Legacy work environment changed during installation; refusing to migrate it."
  [[ ! -L "$local_env" ]] || die "Refusing symlink $local_env."
  if [[ -f "$work_dir/env.zsh.original" ]]; then
    [[ -f "$local_env" ]] &&
      cmp -s "$local_env" "$work_dir/env.zsh.original" &&
      [[ "$(file_mode "$local_env")" == "$local_mode" ]] ||
      die "Local environment changed during installation; refusing to overwrite it."
  else
    [[ ! -e "$local_env" ]] || die "Local environment appeared during installation; refusing to overwrite it."
  fi
}

command -v stow >/dev/null 2>&1 || die 'GNU Stow is required; install it before running install.sh.'
[[ -d "$HOME" ]] || die "HOME is not a directory: $HOME"
backup_location "$HOME" >/dev/null
# Register before any operation that could clean Claude settings. A required
# filter fails closed when jq is missing, including direct installer users.
if [[ -e "$repo_dir/.git" ]]; then
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$repo_dir" config --local \
    filter.strip-automode.clean "jq --indent 2 'del(.autoMode)'"
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$repo_dir" config --local \
    filter.strip-automode.smudge cat
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$repo_dir" config --local \
    filter.strip-automode.required true
fi
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-install.XXXXXX")"

# Validate every entrypoint before Stow or any home-file mutation.
for name in "${names[@]}"; do
  target="$HOME/.$name"
  check_entrypoint "$target"
  if [[ -f "$target" ]]; then
    cp -p -- "$target" "$work_dir/$name.original"
    if ! span="$(managed_span "$work_dir/$name.original")"; then
      die "Malformed dotfiles managed block in $target; file left unchanged."
    fi
    printf '%s\n' "$span" >"$work_dir/$name.span"
  fi
done

# Claude's runtime directory must never resolve into the versioned package.
[[ ! -L "$HOME/.claude" ]] || die 'Refusing symlink ~/.claude; move its runtime data to a real directory before installation.'

# Omp resources may be linked individually, never its runtime directories or
# local settings. Validate before Stow conflict handling can move anything.
if [[ -d "$repo_dir/omp" ]]; then
  for relative in .omp .omp/agent .omp/agent/extensions .omp/agent/extensions/.lib .omp/agent/themes .omp/agent/rules; do
    target="$HOME/$relative"
    [[ ! -L "$target" ]] || die "Refusing folded Omp directory $target; move runtime data to real directories first."
    [[ ! -e "$target" || -d "$target" ]] || die "Refusing non-directory Omp path $target."
    backup_location "$target" >/dev/null
  done
  for relative in config.yml config.yaml settings.json models.yml models.yaml models.json lsp.json; do
    target="$HOME/.omp/agent/$relative"
    [[ ! -L "$target" ]] || die "Refusing symlink Omp settings $target; no target was changed."
    [[ ! -e "$target" || -f "$target" ]] || die "Refusing non-regular Omp settings $target."
    backup_location "$target" >/dev/null
  done
elif "$sync_omp"; then
  die '--sync-omp requires the omp package and omp-sync.sh.'
fi

# A separate identity-only footer wins over preserved local identity settings
# without overriding their credentials, trust, signing, or other preferences.
# Keep the selection in this bounded block, never in a second identity shim.
git_original="$work_dir/gitconfig.original"
git_content="$work_dir/gitconfig.content"
if [[ -f "$git_original" ]]; then
  identity_span="$(managed_span "$git_original" "$profile_begin" "$profile_end")" ||
    die 'Malformed dotfiles Git identity block; file left unchanged.'
  read -r identity_first identity_last <<<"$identity_span"
  if [[ "$identity_first" -ge 0 ]]; then
    identity_size="$(wc -c <"$git_original")"
    [[ "$identity_first" -gt 0 ]] ||
      die 'Git identity block lacks its separator; file left unchanged.'
    dd if="$git_original" of="$work_dir/identity.original" bs=1 \
      skip="$identity_first" count="$((identity_last - identity_first))" 2>/dev/null
    saved_profile="$(LC_ALL=C awk '/^# dotfiles git profile: / { print $5 }' "$work_dir/identity.original")"
    case "$saved_profile" in personal | work) ;; *) die 'Invalid saved Git profile; file left unchanged.' ;; esac
    [[ -n "$git_profile" ]] || git_profile="$saved_profile"
    # Retain the separator when new local content follows the old footer,
    # so an original tail without an EOF newline cannot join the next line.
    identity_prefix="$((identity_first - 1))"
    if [[ "$identity_last" -lt "$identity_size" ]]; then
      identity_prefix="$identity_first"
    fi
    dd if="$git_original" of="$git_content" bs=1 \
      count="$identity_prefix" 2>/dev/null
    if [[ "$identity_last" -lt "$identity_size" ]]; then
      dd if="$git_original" bs=1 skip="$identity_last" 2>/dev/null >>"$git_content"
    fi
    managed_span "$git_content" >"$work_dir/gitconfig.span" ||
      die 'Malformed dotfiles managed block; file left unchanged.'
  else
    cp -p -- "$git_original" "$git_content"
  fi
fi
if [[ -n "$git_profile" ]]; then
  command -v git >/dev/null 2>&1 || die 'Git is required to select an identity.'
  if [[ "$git_profile" == work ]]; then
    identity_file="$(backup_location "$HOME/.config/dotfiles-local/gitconfig")"
    [[ ! -L "$HOME/.config/dotfiles-local/gitconfig" && -f "$identity_file" ]] ||
      die 'Work profile requires a regular ~/.config/dotfiles-local/gitconfig with user.email configured outside the checkout.'
  else
    identity_file="$repo_dir/git/.config/dotfiles/gitconfig_personal"
  fi
  identity_email="$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git config --file "$identity_file" --get user.email || true)"
  [[ -n "$identity_email" ]] || die "$git_profile profile requires user.email in $identity_file."
  identity_name="$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git config --file "$identity_file" --get user.name || true)"
  identity_footer="$work_dir/identity.new"
  printf '%s\n# dotfiles git profile: %s\n' "$profile_begin" "$git_profile" >"$identity_footer"
  if [[ -n "$identity_name" ]]; then
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git config --file "$identity_footer" user.name "$identity_name"
  fi
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git config --file "$identity_footer" user.email "$identity_email"
  printf '%s\n' "$profile_end" >>"$identity_footer"
fi

if [[ -e "$legacy_env" || -L "$legacy_env" ]]; then
  if "$migrate_local"; then
    [[ ! -L "$legacy_env" && -f "$legacy_env" ]] || die "Refusing non-regular legacy environment $legacy_env."
    local_root="$(backup_location "$HOME/.config/dotfiles-local")"
    local_env="$local_root/env.zsh"
    [[ ! -L "$local_env" ]] || die "Refusing symlink $local_env."
    [[ ! -e "$local_env" || -f "$local_env" ]] || die "Refusing non-regular local environment $local_env."
    cp -p -- "$legacy_env" "$work_dir/env.work.original"
    legacy_mode="$(file_mode "$work_dir/env.work.original")"
    cp -p -- "$work_dir/env.work.original" "$work_dir/env.zsh.new"
    chmod u+w "$work_dir/env.zsh.new"
    migration_mode="$legacy_mode"
    if [[ -f "$local_env" ]]; then
      cp -p -- "$local_env" "$work_dir/env.zsh.original"
      local_mode="$(file_mode "$work_dir/env.zsh.original")"
      # Legacy settings load first; existing local settings remain the
      # final overrides. Preserve every original byte, even without EOF
      # newlines, and never broaden either file's access permissions.
      printf '\n# Existing local environment overrides migrated legacy settings.\n' >>"$work_dir/env.zsh.new"
      prefix_size="$(wc -c <"$work_dir/env.zsh.new")"
      dd if="$work_dir/env.zsh.original" of="$work_dir/env.zsh.prefix" \
        bs=1 count="$prefix_size" 2>/dev/null
      # If publication succeeded but removing the old source failed,
      # retry retirement without inserting the same settings again.
      if cmp -s "$work_dir/env.zsh.original" "$work_dir/env.work.original" ||
        cmp -s "$work_dir/env.zsh.prefix" "$work_dir/env.zsh.new"; then
        cat -- "$work_dir/env.zsh.original" >"$work_dir/env.zsh.new"
      else
        cat -- "$work_dir/env.zsh.original" >>"$work_dir/env.zsh.new"
      fi
      printf -v legacy_permissions '%d' "0$legacy_mode"
      printf -v local_permissions '%d' "0$local_mode"
      printf -v migration_mode '%o' "$((legacy_permissions & local_permissions))"
    fi
    migration_ready=true
  else
    printf 'Legacy work environment was not migrated; run %s --migrate-local to move it outside the checkout.\n' "$0" >&2
  fi
fi

# Prepare all replacements before publishing any of them.
changed=()
for name in "${names[@]}"; do
  target="$HOME/.$name"
  template="$repo_dir/entrypoints/$name"
  replacement="$work_dir/$name.new"
  cat -- "$template" >"$replacement"
  original="$work_dir/$name.original"
  if [[ "$name" == gitconfig && -f "$git_content" ]]; then
    original="$git_content"
  fi
  if [[ -f "$original" ]]; then
    read -r first last <"$work_dir/$name.span"
    size="$(wc -c <"$original")"
    if [[ "$first" -ge 0 ]]; then
      # Move the managed block ahead of all local content for precedence.
      dd if="$original" bs=1 count="$first" 2>/dev/null >>"$replacement"
      if [[ "$last" -lt "$size" ]]; then
        dd if="$original" bs=1 skip="$last" 2>/dev/null >>"$replacement"
      fi
    else
      # The prior installer copied the unmarked template verbatim. Remove
      # that known prefix, but retain any settings subsequently appended.
      LC_ALL=C awk -v begin="$begin_marker" -v end="$end_marker" \
        '$0 != begin && $0 != end' "$template" >"$work_dir/$name.legacy"
      legacy_size="$(wc -c <"$work_dir/$name.legacy")"
      dd if="$original" of="$work_dir/$name.prefix" bs=1 count="$legacy_size" 2>/dev/null
      if cmp -s "$work_dir/$name.prefix" "$work_dir/$name.legacy"; then
        dd if="$original" bs=1 skip="$legacy_size" 2>/dev/null >>"$replacement"
      else
        cat -- "$original" >>"$replacement"
      fi
    fi
  fi
  if [[ "$name" == gitconfig && -n "$git_profile" ]]; then
    printf '\n' >>"$replacement"
    cat -- "$identity_footer" >>"$replacement"
  fi
  original="$work_dir/$name.original"
  if [[ -f "$original" ]] && cmp -s "$original" "$replacement"; then
    continue
  fi
  stage="$(mktemp "$HOME/.dotfiles-$name.XXXXXX")"
  staged[${#staged[@]}]="$stage"
  cat -- "$replacement" >"$stage"
  if [[ -f "$original" ]]; then
    case "$(uname -s)" in
    Darwin) mode="$(stat -f '%Lp' "$original")" ;;
    *) mode="$(stat -c '%a' "$original")" ;;
    esac
    chmod "$mode" "$stage"
  else
    chmod 600 "$stage"
  fi
  changed[${#changed[@]}]="$name"
done

# Back up pre-existing local files outside the checkout, before changing them.
backup_dir=''
for name in ${changed[@]+"${changed[@]}"}; do
  if [[ -f "$work_dir/$name.original" ]]; then
    if [[ -z "$backup_dir" ]]; then
      backup_root="$(backup_location)"
      (
        umask 077
        mkdir -p -- "$backup_root"
      )
      backup_dir="$(mktemp -d "$backup_root/install.XXXXXX")"
    fi
    cp -p -- "$work_dir/$name.original" "$backup_dir/.$name"
  fi
done
if "$migration_ready"; then
  if [[ -z "$backup_dir" ]]; then
    backup_root="$(backup_location)"
    (
      umask 077
      mkdir -p -- "$backup_root"
    )
    backup_dir="$(mktemp -d "$backup_root/install.XXXXXX")"
  fi
  cp -p -- "$work_dir/env.work.original" "$backup_dir/env.work"
  if [[ -f "$work_dir/env.zsh.original" ]]; then
    cp -p -- "$work_dir/env.zsh.original" "$backup_dir/env.zsh"
  fi
  check_migration_unchanged
  (
    umask 077
    mkdir -p -- "$local_root"
  )
  migration_stage="$(mktemp "$local_root/.env.zsh.XXXXXX")"
  staged[${#staged[@]}]="$migration_stage"
  cat -- "$work_dir/env.zsh.new" >"$migration_stage"
  chmod "$migration_mode" "$migration_stage"
fi

# Detect endpoint edits made while preparing the install rather than losing them.
for name in "${names[@]}"; do
  check_unchanged "$name"
done

# Never adopt local data into the repository. Only Stow-reported conflicts that
# are regular local files can be moved to the outside-checkout backup tree.
if ! stow --simulate --dir="$repo_dir" --target="$HOME" --no-folding \
  --ignore='(^|/)\.zprofile\.d(/|$)' "${packages[@]}" >"$work_dir/stow.log" 2>&1; then
  if ! "$backup_conflicts"; then
    cat "$work_dir/stow.log" >&2
    die 'Stow conflicts detected; use --backup to preserve conflicting local regular files outside the checkout.'
  fi
  LC_ALL=C awk '
        /existing target is neither a link nor a directory: / {
            sub(/^.*existing target is neither a link nor a directory: /, ""); print; next
        }
        / over existing target .* since neither a link nor a directory/ {
            sub(/^.* over existing target /, "")
            sub(/ since neither a link nor a directory.*$/, ""); print; next
        }
        / over existing non-directory target / {
            sub(/^.* over existing non-directory target /, ""); print
        }
    ' "$work_dir/stow.log" | LC_ALL=C sort -u >"$work_dir/conflicts"
  while IFS= read -r relative; do
    [[ -n "$relative" && "$relative" != /* && "$relative" != ../* && "$relative" != */../* ]] ||
      die 'Unsafe Stow conflict path.'
    target="$HOME/$relative"
    [[ ! -L "$target" && -f "$target" ]] || die "Refusing to back up non-regular conflict $target."
    backup_location "$target" >/dev/null
    if [[ -z "$backup_dir" ]]; then
      backup_root="$(backup_location)"
      (
        umask 077
        mkdir -p -- "$backup_root"
      )
      backup_dir="$(mktemp -d "$backup_root/install.XXXXXX")"
    fi
    conflict_backup="$backup_dir/stow/$relative"
    (
      umask 077
      mkdir -p -- "${conflict_backup%/*}"
    )
    cp -p -- "$target" "$conflict_backup"
    conflict_targets[${#conflict_targets[@]}]="$target"
    conflict_backups[${#conflict_backups[@]}]="$conflict_backup"
    cmp -s "$target" "$conflict_backup" || die "Conflict changed during backup: $target."
    rm -- "$target"
  done <"$work_dir/conflicts"
  if ! stow --simulate --dir="$repo_dir" --target="$HOME" --no-folding \
    --ignore='(^|/)\.zprofile\.d(/|$)' "${packages[@]}"; then
    die 'Remaining Stow conflicts cannot be safely backed up; original local files restored.'
  fi
fi
stow --dir="$repo_dir" --target="$HOME" --no-folding \
  --ignore='(^|/)\.zprofile\.d(/|$)' "${packages[@]}"
stow_done=true

# Seed only absent default-profile files. Do not consult effective configuration
# (which can contain project, overlay, provider, or machine-private values).
if [[ -d "$repo_dir/omp" ]]; then
  (
    umask 077
    mkdir -p -- "$HOME/.omp/agent"
    if [[ ! -e "$HOME/.omp/agent/config.yml" && ! -e "$HOME/.omp/agent/config.yaml" &&
      ! -e "$HOME/.omp/agent/settings.json" && ! -e "$HOME/.omp/agent/agent.db" &&
      ! -d "${XDG_DATA_HOME:-$HOME/.local/share}/omp" ]]; then
      cp -- "$repo_dir/omp/.config/dotfiles/omp/preferences.yml" "$HOME/.omp/agent/config.yml"
    fi
    if [[ ! -e "$HOME/.omp/agent/models.yml" && ! -e "$HOME/.omp/agent/models.yaml" &&
      ! -e "$HOME/.omp/agent/models.json" ]]; then
      cp -- "$repo_dir/omp/.config/dotfiles/omp/models.yml" "$HOME/.omp/agent/models.yml"
    fi
    if [[ ! -e "$HOME/.omp/agent/lsp.json" ]]; then
      cp -- "$repo_dir/omp/.config/dotfiles/omp/lsp.json" "$HOME/.omp/agent/lsp.json"
    fi
  )
  if "$sync_omp"; then
    bash "$repo_dir/omp-sync.sh"
  fi
fi
index=0
for name in ${changed[@]+"${changed[@]}"}; do
  check_unchanged "$name"
  mv -f -- "${staged[$index]}" "$HOME/.$name"
  staged[index]=''
  index=$((index + 1))
done
if "$migration_ready"; then
  check_migration_unchanged
  mv -f -- "$migration_stage" "$local_env"
  # The protected legacy file is removed only after publication succeeds.
  rm -- "$legacy_env"
  printf 'Legacy work environment migrated to %s (existing local overrides load last).\n' "$local_env"
fi
if [[ -n "$backup_dir" ]]; then
  printf 'Original local files backed up to %s\n' "$backup_dir"
fi
