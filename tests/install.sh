#!/usr/bin/env bash
# Consumer-level installer regressions. Run with: bash tests/install.sh
set -euo pipefail

source_repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
for command in stow zsh git jq; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Required test dependency: %s\n' "$command" >&2
    exit 1
  }
done
export DOTFILES_RUNTIME=native GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
scratch="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-install-test.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo/entrypoints" "$repo/zsh/.config/dotfiles" "$repo/git/.config/dotfiles" "$repo/tmux" "$repo/vim" "$repo/agents/.agents" "$repo/claude/.claude"
cp "$source_repo/install.sh" "$repo/install.sh"
cat >"$repo/zsh/.config/dotfiles/zprofile" <<'PROFILE'
export PROFILE_LOADS=$(( ${PROFILE_LOADS:-0} + 1 ))
export PROFILE_ORDER=shared
PROFILE
cat >"$repo/zsh/.config/dotfiles/zshrc" <<'INTERACTIVE'
export INTERACTIVE_LOADS=$(( ${INTERACTIVE_LOADS:-0} + 1 ))
export INTERACTIVE_ORDER=shared
INTERACTIVE
printf '[dotfiles]\n    order = shared\n    shared = active\n' >"$repo/git/.config/dotfiles/gitconfig"
printf '[user]\n    name = Synthetic Personal\n    email = personal@example.invalid\n' >"$repo/git/.config/dotfiles/gitconfig_personal"
printf '# Synthetic shared instructions\n' >"$repo/agents/.agents/AGENTS.md"
ln -s ../../agents/.agents/AGENTS.md "$repo/claude/.claude/CLAUDE.md"
printf '{"model":"synthetic"}\n' >"$repo/claude/.claude/settings.json"
printf '#!/bin/sh\nexit 0\n' >"$repo/claude/.claude/statusline.sh"
chmod +x "$repo/claude/.claude/statusline.sh"
cp "$source_repo/.gitattributes" "$repo/.gitattributes"
printf 'set -g status off\n' >"$repo/tmux/.tmux.conf"
printf 'set number\n' >"$repo/vim/.vimrc"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
assert_equal() { [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"; }
assert_same() { cmp -s "$1" "$2" || fail "$3"; }
new_home() {
  home="$scratch/$1"
  mkdir -p "$home"
  cp "$source_repo/entrypoints/"* "$repo/entrypoints/"
}
install_home() {
  # Deliberately run outside the checkout.
  (
    cd "$scratch"
    HOME="$home" bash "$repo/install.sh" "$@"
  ) >"$scratch/install.log" 2>&1 || {
    cat "$scratch/install.log" >&2
    fail 'installer unexpectedly failed'
  }
}
reject_install() {
  if (
    cd "$scratch"
    HOME="$home" bash "$repo/install.sh" "$@"
  ) >"$scratch/install.log" 2>&1; then
    fail 'unsafe installation unexpectedly succeeded'
  fi
  [[ ! -e "$home/.config/dotfiles" ]] || fail 'rejected installation changed Stow targets'
}
shell_settings() {
  HOME="$home" ZDOTDIR="$home" zsh -dlic 'printf "%s|%s|%s|%s" "$PROFILE_LOADS" "$INTERACTIVE_LOADS" "$PROFILE_ORDER" "$INTERACTIVE_ORDER"'
}
git_setting() {
  HOME="$home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$home/.gitconfig" git config --global --includes --get "$1"
}
snapshot() {
  mkdir -p "$scratch/snapshot"
  for name in zprofile zshrc gitconfig; do
    cp "$home/.$name" "$scratch/snapshot/$name"
  done
}
assert_snapshot() {
  for name in zprofile zshrc gitconfig; do
    assert_same "$home/.$name" "$scratch/snapshot/$name" "changed $name unexpectedly"
  done
}
file_mode() {
  case "$(uname -s)" in
  Darwin) stat -f '%Lp' "$1" ;;
  *) stat -c '%a' "$1" ;;
  esac
}
legacy_settings() {
  HOME="$home" ZDOTDIR="$home" zsh -dlic 'printf "%s|%s|%s" "$PROFILE_ORDER" "${LEGACY_LOADS:-0}" "${LEGACY_VALUE:-absent}"'
}
assert_legacy_ignored() {
  git -C "$repo" add -A
  if git -C "$repo" ls-files --error-unmatch zsh/.zprofile.d/env.work >/dev/null 2>&1; then
    fail 'routine git add -A staged the private legacy work environment'
  fi
  git -C "$repo" ls-files --error-unmatch .gitignore >/dev/null 2>&1 ||
    fail 'staging protection fixture did not stage ordinary repository files'
}

new_home fresh
install_home
assert_equal "$(shell_settings)" '1|1|shared|shared' 'fresh shell settings'
assert_equal "$(git_setting dotfiles.shared)" active 'fresh Git shared settings'
for name in zprofile zshrc gitconfig; do
  [[ -f "$home/.$name" && ! -L "$home/.$name" ]] || fail "$name must be a real file"
done
[[ -d "$home/.claude" && ! -L "$home/.claude" ]] || fail 'Claude runtime directory was folded into the repository'
for name in CLAUDE.md settings.json statusline.sh; do
  [[ -L "$home/.claude/$name" ]] || fail "missing shared Claude file $name"
done
printf 'synthetic private credential\n' >"$home/.claude/.credentials.json"
mkdir -p "$home/.claude/projects/synthetic"
printf 'synthetic transcript\n' >"$home/.claude/projects/synthetic/session.jsonl"
install_home
assert_equal "$(cat "$home/.claude/.credentials.json")" 'synthetic private credential' 'rerun lost Claude credentials'
[[ ! -e "$repo/claude/.claude/.credentials.json" && ! -e "$repo/claude/.claude/projects" ]] ||
  fail 'Claude runtime data entered checkout'
snapshot
install_home
assert_snapshot
assert_equal "$(shell_settings)" '1|1|shared|shared' 'rerun sourced shared settings more than once'

new_home existing
mkdir -p "$home/.config/dotfiles-local"
printf 'export PROFILE_ORDER=optional\n' >"$home/.config/dotfiles-local/env.zsh"
printf 'export INTERACTIVE_ORDER=optional\n' >"$home/.config/dotfiles-local/interactive.zsh"
printf '[dotfiles]\n    order = optional\n' >"$home/.config/dotfiles-local/gitconfig"
# Model a Homebrew-created shellenv entrypoint without a trailing newline.
printf '# Homebrew shellenv and local settings\nexport PROFILE_ORDER=homebrew' >"$home/.zprofile"
printf 'export INTERACTIVE_ORDER=machine\n' >"$home/.zshrc"
printf '[dotfiles]\n    order = machine' >"$home/.gitconfig"
chmod 600 "$home/.zprofile" "$home/.zshrc" "$home/.gitconfig"
snapshot
install_home
assert_equal "$(shell_settings)" '1|1|homebrew|machine' 'existing shell settings must override shared and optional local settings'
assert_equal "$(git_setting dotfiles.order)" machine 'existing Git settings must win'
assert_equal "$(git_setting dotfiles.shared)" active 'existing Git config must load shared settings'
# Check original bytes retained as the exact suffix, including missing newlines.
for name in zprofile zshrc gitconfig; do
  original="$scratch/snapshot/$name"
  old_size="$(wc -c <"$original")"
  new_size="$(wc -c <"$home/.$name")"
  dd if="$home/.$name" of="$scratch/suffix" bs=1 skip="$((new_size - old_size))" 2>/dev/null
  assert_same "$original" "$scratch/suffix" "lost local bytes in $name"
  backups=("$home/.local/state/dotfiles/backups/"*/".$name")
  assert_same "$original" "${backups[0]}" "missing original backup for $name"
  case "$(uname -s)" in
  Darwin) mode="$(stat -f '%Lp' "$home/.$name")" ;;
  *) mode="$(stat -c '%a' "$home/.$name")" ;;
  esac
  assert_equal "$mode" 600 "changed restrictive permissions for $name"
done
snapshot
install_home
assert_snapshot
# Replace a template with a new managed revision. Local bytes and precedence
# must survive and the revision must be observed, not merely installed as text.
cat >"$repo/entrypoints/zprofile" <<'PROFILE'
# >>> dotfiles managed >>>
source "$HOME/.config/dotfiles/zprofile"
if [[ -r "$HOME/.config/dotfiles-local/env.zsh" ]]; then
    source "$HOME/.config/dotfiles-local/env.zsh"
fi
export MANAGED_REVISION=updated
# <<< dotfiles managed <<<
PROFILE
install_home
assert_equal "$(HOME="$home" ZDOTDIR="$home" zsh -dlic 'printf "%s|%s|%s" "$PROFILE_LOADS" "$PROFILE_ORDER" "$MANAGED_REVISION"')" '1|homebrew|updated' 'managed update lost precedence or duplicated shared source'
snapshot
install_home
assert_snapshot

new_home optional
mkdir -p "$home/.config/dotfiles-local"
printf 'export PROFILE_ORDER=optional\n' >"$home/.config/dotfiles-local/env.zsh"
printf 'export INTERACTIVE_ORDER=optional\n' >"$home/.config/dotfiles-local/interactive.zsh"
printf '[dotfiles]\n    order = optional\n' >"$home/.config/dotfiles-local/gitconfig"
install_home
assert_equal "$(shell_settings)" '1|1|optional|optional' 'optional local shell hooks'
assert_equal "$(git_setting dotfiles.order)" optional 'optional local Git include must follow shared include'

new_home identity-default
mkdir -p "$home/.config/dotfiles-local"
printf '[user]\n    name = Synthetic Local\n    email = local@example.invalid\n[commit]\n    gpgsign = true\n[user]\n    signingkey = synthetic-key\n[credential]\n    helper = synthetic-helper\n[safe]\n    directory = /synthetic/trusted\n' >"$home/.config/dotfiles-local/gitconfig"
printf '[user]\n    email = tail@example.invalid\n[dotfiles]\n    tail = retained' >"$home/.gitconfig"
cp "$home/.gitconfig" "$scratch/identity-tail"
cp "$home/.config/dotfiles-local/gitconfig" "$scratch/identity-private"
install_home
assert_equal "$(git_setting user.email)" tail@example.invalid 'default install changed local identity precedence'
install_home --git-profile work
assert_equal "$(git_setting user.email)" local@example.invalid 'work selector did not use machine-local email'
assert_equal "$(git_setting user.name)" 'Synthetic Local' 'work selector did not use machine-local name'
assert_equal "$(git_setting commit.gpgsign)" true 'work selector changed signing policy'
assert_equal "$(git_setting user.signingkey)" synthetic-key 'work selector changed signing key'
snapshot
install_home
assert_snapshot
assert_equal "$(git_setting user.email)" local@example.invalid 'rerun forgot explicit work profile'
install_home --git-profile personal
assert_equal "$(git_setting user.email)" personal@example.invalid 'personal selector did not override local identity'
assert_equal "$(git_setting user.name)" 'Synthetic Personal' 'personal selector did not select shared name'
assert_equal "$(git_setting credential.helper)" synthetic-helper 'personal selector lost credentials'
assert_equal "$(git_setting safe.directory)" /synthetic/trusted 'personal selector lost trust settings'
assert_equal "$(git_setting commit.gpgsign)" true 'personal selector disabled signing'
assert_equal "$(git_setting user.signingkey)" synthetic-key 'personal selector replaced signing key'
assert_equal "$(git_setting dotfiles.tail)" retained 'identity selector lost user entrypoint tail'
template_size="$(wc -c <"$repo/entrypoints/gitconfig")"
tail_size="$(wc -c <"$scratch/identity-tail")"
dd if="$home/.gitconfig" of="$scratch/identity-preserved" bs=1 \
  skip="$template_size" count="$tail_size" 2>/dev/null
assert_same "$scratch/identity-preserved" "$scratch/identity-tail" 'identity selection altered private tail bytes'
assert_same "$home/.config/dotfiles-local/gitconfig" "$scratch/identity-private" 'identity selection modified private Git config'
snapshot
install_home
assert_snapshot
assert_equal "$(git_setting user.email)" personal@example.invalid 'rerun forgot explicit personal profile'
[[ ! -e "$home/.gitconfig_user" ]] || fail 'installer resurrected obsolete Git identity shim'
printf '[dotfiles]\n    appended = preserved\n[user]\n    email = appended@example.invalid\n' >>"$home/.gitconfig"
install_home
assert_equal "$(git_setting dotfiles.appended)" preserved 'rerun lost local settings appended after identity footer'
assert_equal "$(git_setting user.email)" personal@example.invalid 'rerun failed to reapply selected identity after new tail'
snapshot
install_home
assert_snapshot

new_home identity-missing
reject_install --git-profile work
new_home identity-empty
mkdir -p "$home/.config/dotfiles-local"
printf '[credential]\n    helper = synthetic\n' >"$home/.config/dotfiles-local/gitconfig"
reject_install --git-profile work
new_home identity-repository
mkdir -p "$home/.config" "$repo/private-identity"
printf '[user]\n    email = synthetic@example.invalid\n' >"$repo/private-identity/gitconfig"
ln -s "$repo/private-identity" "$home/.config/dotfiles-local"
reject_install --git-profile work

new_home legacy
# These are the exact bare templates written by the previous installer.
for name in zprofile zshrc gitconfig; do
  LC_ALL=C awk '$0 != "# >>> dotfiles managed >>>" && $0 != "# <<< dotfiles managed <<<"' "$repo/entrypoints/$name" >"$home/.$name"
done
printf 'export PROFILE_ORDER=legacy-local\n' >>"$home/.zprofile"
install_home
assert_equal "$(shell_settings)" '1|1|legacy-local|shared' 'legacy template migration duplicated shell sources'
snapshot
install_home
assert_snapshot

new_home middle
printf 'export PROFILE_ORDER=before\n' >"$scratch/local-before"
printf 'export PROFILE_ORDER=after' >"$scratch/local-after"
cat "$scratch/local-before" "$repo/entrypoints/zprofile" "$scratch/local-after" >"$home/.zprofile"
cat "$scratch/local-before" "$scratch/local-after" >"$scratch/local-expected"
install_home
assert_equal "$(shell_settings)" '1|1|after|shared' 'moving managed block must preserve local precedence'
original_size="$(wc -c <"$scratch/local-expected")"
installed_size="$(wc -c <"$home/.zprofile")"
dd if="$home/.zprofile" of="$scratch/local-actual" bs=1 skip="$((installed_size - original_size))" 2>/dev/null
assert_same "$scratch/local-expected" "$scratch/local-actual" 'moving managed block altered surrounding local bytes'
snapshot
install_home
assert_snapshot

for name in zprofile zshrc gitconfig; do
  new_home "symlink-$name"
  printf 'untouched target\n' >"$scratch/link-target"
  cp "$scratch/link-target" "$scratch/link-original"
  ln -s "$scratch/link-target" "$home/.$name"
  reject_install
  [[ -L "$home/.$name" ]] || fail 'installer replaced a symlink'
  assert_same "$scratch/link-target" "$scratch/link-original" 'installer wrote through a symlink'
done

for malformed in unterminated duplicate reversed indented; do
  new_home "malformed-$malformed"
  printf 'export PROFILE_ORDER=untouched\n' >"$home/.zprofile"
  printf '[dotfiles]\n    order = untouched\n' >"$home/.gitconfig"
  case "$malformed" in
  unterminated) printf '# >>> dotfiles managed >>>\n' >"$home/.zshrc" ;;
  duplicate) cat "$repo/entrypoints/zshrc" "$repo/entrypoints/zshrc" >"$home/.zshrc" ;;
  reversed) printf '# <<< dotfiles managed <<<\n# >>> dotfiles managed >>>\n' >"$home/.zshrc" ;;
  indented) printf '  # >>> dotfiles managed >>>\n  # <<< dotfiles managed <<<\n' >"$home/.zshrc" ;;
  esac
  snapshot
  reject_install
  assert_snapshot
done

new_home nonregular
mkdir "$home/.zshrc"
printf 'untouched child\n' >"$home/.zshrc/child"
cp "$home/.zshrc/child" "$scratch/nonregular-original"
reject_install
assert_same "$home/.zshrc/child" "$scratch/nonregular-original" 'installer changed a non-regular entrypoint'

new_home conflict
printf 'export PROFILE_ORDER=untouched\n' >"$home/.zprofile"
printf 'export INTERACTIVE_ORDER=untouched\n' >"$home/.zshrc"
printf '[dotfiles]\n    order = untouched\n' >"$home/.gitconfig"
printf 'conflicting tmux settings\n' >"$home/.tmux.conf"
snapshot
cp "$home/.tmux.conf" "$scratch/tmux-original"
reject_install
assert_snapshot
assert_same "$home/.tmux.conf" "$scratch/tmux-original" 'Stow conflict overwrote local tmux settings'
install_home --backup
[[ -L "$home/.tmux.conf" ]] || fail '--backup did not install shared tmux configuration'
backups=("$home/.local/state/dotfiles/backups/"*/stow/.tmux.conf)
assert_same "${backups[0]}" "$scratch/tmux-original" '--backup lost conflicting local tmux file'
assert_equal "$(shell_settings)" '1|1|untouched|untouched' '--backup lost local entrypoint settings'
assert_equal "$(git_setting dotfiles.order)" untouched '--backup lost local Git tail'

new_home claude-conflict
mkdir -p "$home/.claude/projects/synthetic"
printf '# private local instructions\n' >"$home/.claude/CLAUDE.md"
chmod 600 "$home/.claude/CLAUDE.md"
cp -p "$home/.claude/CLAUDE.md" "$scratch/claude-original"
printf 'synthetic credential\n' >"$home/.claude/.credentials.json"
printf 'synthetic transcript\n' >"$home/.claude/projects/synthetic/session.jsonl"
reject_install
install_home --backup
backups=("$home/.local/state/dotfiles/backups/"*/stow/.claude/CLAUDE.md)
assert_same "${backups[0]}" "$scratch/claude-original" '--backup lost local Claude instructions'
assert_equal "$(file_mode "${backups[0]}")" 600 'Claude backup broadened local permissions'
assert_equal "$(cat "$home/.claude/.credentials.json")" 'synthetic credential' '--backup changed Claude credentials'
assert_equal "$(cat "$home/.claude/projects/synthetic/session.jsonl")" 'synthetic transcript' '--backup changed Claude transcript'
[[ ! -e "$repo/claude/.claude/.credentials.json" && ! -e "$repo/claude/.claude/projects" ]] ||
  fail '--backup moved private Claude runtime into repository'

new_home backup-symlink-conflict
printf 'synthetic local link target\n' >"$scratch/tmux-link-target"
cp "$scratch/tmux-link-target" "$scratch/tmux-link-original"
ln -s "$scratch/tmux-link-target" "$home/.tmux.conf"
reject_install --backup
assert_same "$scratch/tmux-link-target" "$scratch/tmux-link-original" '--backup modified a symlink target'
[[ -L "$home/.tmux.conf" ]] || fail '--backup removed a conflicting symlink'

new_home backup-repository-storage
mkdir -p "$home/.local/state/dotfiles" "$repo/private-backups"
ln -s "$repo/private-backups" "$home/.local/state/dotfiles/backups"
printf 'synthetic conflict\n' >"$home/.tmux.conf"
cp "$home/.tmux.conf" "$scratch/unsafe-backup-original"
reject_install --backup
assert_same "$home/.tmux.conf" "$scratch/unsafe-backup-original" 'unsafe backup storage changed local conflict'

new_home folded-claude
ln -s "$repo/claude/.claude" "$home/.claude"
reject_install --backup
[[ -L "$home/.claude" ]] || fail 'installer changed folded Claude directory without preserving its runtime'

# An older checkout still protects its work file from routine staging, and
# ordinary installation must neither claim migration nor publish private links.
cp "$source_repo/.gitignore" "$repo/.gitignore"
git -C "$repo" init --quiet
new_home privacy-filter
install_home
assert_equal "$(git -C "$repo" config --get filter.strip-automode.required)" true 'direct installer did not require privacy filter'
printf '{"model":"synthetic","autoMode":{"environment":["synthetic-private"]}}\n' >"$repo/claude/.claude/settings.json"
git -C "$repo" add .gitattributes claude/.claude/settings.json
staged_settings="$(git -C "$repo" show :claude/.claude/settings.json)"
assert_equal "$(printf '%s' "$staged_settings" | jq -r 'has("autoMode")')" false 'privacy filter staged private autoMode data'
assert_equal "$(printf '%s' "$staged_settings" | jq -r '.model')" synthetic 'privacy filter changed ordinary Claude settings'
assert_equal "$(jq -r 'has("autoMode")' "$repo/claude/.claude/settings.json")" true 'clean filter destroyed local runtime settings'
mkdir -p "$repo/zsh/.zprofile.d"
printf 'export PROFILE_ORDER=legacy-work\nexport LEGACY_LOADS=%s\nexport LEGACY_VALUE="preserved synthetic value"' "\$(( \${LEGACY_LOADS:-0} + 1 ))" >"$repo/zsh/.zprofile.d/env.work"
chmod 640 "$repo/zsh/.zprofile.d/env.work"
cp -p "$repo/zsh/.zprofile.d/env.work" "$scratch/legacy-original"
assert_legacy_ignored
new_home migration-opt-in
install_home
assert_same "$repo/zsh/.zprofile.d/env.work" "$scratch/legacy-original" 'default installation changed legacy environment'
assert_equal "$(legacy_settings)" 'shared|0|absent' 'default install unexpectedly loaded legacy private settings'
[[ ! -e "$home/.zprofile.d/env.work" && ! -L "$home/.zprofile.d/env.work" ]] ||
  fail 'default installation published a legacy private Stow link'
case "$(cat "$scratch/install.log")" in
*'was not migrated;'*) ;;
*) fail 'default installer omitted explicit migration opt-in notice' ;;
esac

# No-collision migration preserves exact bytes, modes, and runnable settings.
install_home --migrate-local
local_env="$home/.config/dotfiles-local/env.zsh"
[[ ! -e "$repo/zsh/.zprofile.d/env.work" ]] || fail 'migration left work contents inside checkout'
assert_same "$local_env" "$scratch/legacy-original" 'migration changed original environment bytes'
assert_equal "$(file_mode "$local_env")" 640 'migration changed original environment permissions'
assert_equal "$(legacy_settings)" 'legacy-work|1|preserved synthetic value' 'migrated environment did not load through login entrypoint'
backups=("$home/.local/state/dotfiles/backups/"*/env.work)
assert_same "${backups[0]}" "$scratch/legacy-original" 'migration failed to back up legacy source outside repository'
assert_equal "$(file_mode "${backups[0]}")" 640 'migration backup changed legacy permissions'
cp -p "$local_env" "$scratch/migrated-original"
install_home --migrate-local
assert_same "$local_env" "$scratch/migrated-original" 'repeat migration changed environment'
assert_equal "$(legacy_settings)" 'legacy-work|1|preserved synthetic value' 'repeat migration duplicated legacy settings'
case "$(cat "$scratch/install.log")" in
*'Legacy work environment migrated to '*) fail 'rerun falsely reported migration' ;;
esac
cp -p "$scratch/legacy-original" "$repo/zsh/.zprofile.d/env.work"
install_home --migrate-local
assert_same "$local_env" "$scratch/migrated-original" 'retry after publication duplicated unmixed legacy settings'
assert_equal "$(legacy_settings)" 'legacy-work|1|preserved synthetic value' 'publication retry duplicated legacy loads'

# A collision must retain both files, including absent EOF newlines. The real
# login shell observes legacy-only settings once and existing local overrides.
new_home migration-collision
cp -p "$scratch/legacy-original" "$repo/zsh/.zprofile.d/env.work"
mkdir -p "$home/.config/dotfiles-local"
local_env="$home/.config/dotfiles-local/env.zsh"
printf 'export PROFILE_ORDER=existing-local\nexport LOCAL_LOADS=%s' "\$(( \${LOCAL_LOADS:-0} + 1 ))" >"$local_env"
chmod 600 "$local_env"
cp -p "$local_env" "$scratch/local-env-original"
install_home --migrate-local
[[ ! -e "$repo/zsh/.zprofile.d/env.work" ]] || fail 'collision migration left work file inside checkout'
assert_equal "$(legacy_settings)" 'existing-local|1|preserved synthetic value' 'collision migration lost legacy values or local precedence'
assert_equal "$(HOME="$home" ZDOTDIR="$home" zsh -dlic 'printf "%s" "$LOCAL_LOADS"')" 1 'collision migration duplicated existing local settings'
assert_equal "$(file_mode "$local_env")" 600 'collision migration broadened private environment permissions'
backups=("$home/.local/state/dotfiles/backups/"*/env.work)
assert_same "${backups[0]}" "$scratch/legacy-original" 'collision migration lost legacy backup'
assert_equal "$(file_mode "${backups[0]}")" 640 'collision backup changed legacy permissions'
backups=("$home/.local/state/dotfiles/backups/"*/env.zsh)
assert_same "${backups[0]}" "$scratch/local-env-original" 'collision migration lost existing local backup'
assert_equal "$(file_mode "${backups[0]}")" 600 'collision backup changed local permissions'
legacy_size="$(wc -c <"$scratch/legacy-original")"
dd if="$local_env" of="$scratch/legacy-prefix" bs=1 count="$legacy_size" 2>/dev/null
assert_same "$scratch/legacy-prefix" "$scratch/legacy-original" 'collision migration altered legacy bytes'
local_size="$(wc -c <"$scratch/local-env-original")"
merged_size="$(wc -c <"$local_env")"
dd if="$local_env" of="$scratch/local-env-suffix" bs=1 skip="$((merged_size - local_size))" 2>/dev/null
assert_same "$scratch/local-env-suffix" "$scratch/local-env-original" 'collision migration altered local bytes'
cp -p "$local_env" "$scratch/merged-original"
install_home --migrate-local
assert_same "$local_env" "$scratch/merged-original" 'collision rerun duplicated merged contents'
assert_equal "$(legacy_settings)" 'existing-local|1|preserved synthetic value' 'collision rerun changed effective settings'

# Ignore protection remains in force for another legacy clone/file after the
# migration, rather than depending on the work file having been deleted.
cp -p "$scratch/legacy-original" "$repo/zsh/.zprofile.d/env.work"
assert_legacy_ignored
install_home --migrate-local
assert_same "$local_env" "$scratch/merged-original" 'retry after publication duplicated merged legacy settings'
assert_equal "$(legacy_settings)" 'existing-local|1|preserved synthetic value' 'merged publication retry changed effective settings'
cp -p "$scratch/legacy-original" "$repo/zsh/.zprofile.d/env.work"

# Unsafe local destinations and legacy inputs are rejected without modifying
# either user's environment or publishing any shared configuration.
new_home migration-local-symlink
mkdir -p "$home/.config/dotfiles-local"
printf 'export PROFILE_ORDER=symlink-target\n' >"$scratch/env-target"
cp -p "$scratch/env-target" "$scratch/env-target-original"
ln -s "$scratch/env-target" "$home/.config/dotfiles-local/env.zsh"
reject_install --migrate-local
[[ -L "$home/.config/dotfiles-local/env.zsh" ]] || fail 'migration replaced local environment symlink'
assert_same "$scratch/env-target" "$scratch/env-target-original" 'migration wrote through local environment symlink'
assert_same "$repo/zsh/.zprofile.d/env.work" "$scratch/legacy-original" 'rejected migration changed legacy source'

new_home migration-local-directory
mkdir -p "$home/.config/dotfiles-local/env.zsh"
printf 'untouched child\n' >"$home/.config/dotfiles-local/env.zsh/child"
cp "$home/.config/dotfiles-local/env.zsh/child" "$scratch/env-child-original"
reject_install --migrate-local
assert_same "$home/.config/dotfiles-local/env.zsh/child" "$scratch/env-child-original" 'migration changed non-regular local environment'
assert_same "$repo/zsh/.zprofile.d/env.work" "$scratch/legacy-original" 'non-regular destination rejection changed legacy source'

new_home migration-storage-in-repo
mkdir -p "$home/.config" "$repo/private-local"
ln -s "$repo/private-local" "$home/.config/dotfiles-local"
reject_install --migrate-local
[[ ! -e "$repo/private-local/env.zsh" ]] || fail 'migration published private environment inside repository'
assert_same "$repo/zsh/.zprofile.d/env.work" "$scratch/legacy-original" 'unsafe storage rejection changed legacy source'

new_home migration-legacy-symlink
rm "$repo/zsh/.zprofile.d/env.work"
ln -s "$scratch/env-target" "$repo/zsh/.zprofile.d/env.work"
reject_install --migrate-local
[[ -L "$repo/zsh/.zprofile.d/env.work" ]] || fail 'migration replaced legacy environment symlink'
assert_same "$scratch/env-target" "$scratch/env-target-original" 'migration changed legacy symlink target'

printf 'Installer regression tests passed.\n'
