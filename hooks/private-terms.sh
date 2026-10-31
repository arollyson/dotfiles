#!/usr/bin/env bash
# Block private terms (employer names, internal hosts, tools) from this public repo.
# The term list lives outside the checkout so the list itself never ships.
#
# Usage: private-terms.sh staged FILE... | message MSG_FILE | push
set -euo pipefail

terms_file="${DOTFILES_PRIVATE_TERMS:-$HOME/.config/dotfiles-local/private-terms}"

fail() {
  printf 'private-terms: %s\n' "$*" >&2
  exit 1
}

if [[ ! -f "$terms_file" ]]; then
  # CI has no private list; local machines must opt out explicitly.
  [[ -z "${CI:-}" ]] || exit 0
  fail "missing $terms_file: list one case-insensitive extended regex per line" \
    "(# comments allowed). An empty file disables this check."
fi

work_dir="$(mktemp -d)"
patterns="$work_dir/patterns"
regex_err="$work_dir/regex.err"
# Remove only the files this script creates. A failing trap command would replace
# the exit status, so a leftover directory is reported instead of failing the hook.
cleanup() {
  rm -f -- "$patterns" "$regex_err"
  rmdir -- "$work_dir" 2>/dev/null || printf 'private-terms: left %s\n' "$work_dir" >&2
}
trap cleanup EXIT
grep -v -E '^[[:space:]]*(#|$)' "$terms_file" >"$patterns" || true
[[ -s "$patterns" ]] || exit 0
# grep exits 1 for no match and 2 for an error; an invalid regex must never
# read as a clean scan, so reject the whole list up front.
status=0
grep -E -f "$patterns" /dev/null 2>"$regex_err" || status=$?
[[ "$status" -le 1 ]] ||
  fail "invalid regex in $terms_file: $(head -1 "$regex_err"). Nothing was checked."

found=0
# Reads text on stdin; reports matching lines under a label and returns 1.
# Callers use process substitution: bash 3.2 (macOS) has no lastpipe.
scan() {
  local label="$1" hits status=0
  hits="$(grep -I -i -n -E -f "$patterns")" || status=$?
  case "$status" in
  0)
    printf 'private-terms: %s\n%s\n' "$label" "$hits" >&2
    return 1
    ;;
  1) return 0 ;;
  *) fail "grep failed (status $status) while scanning $label; nothing was allowed." ;;
  esac
}

identity() {
  git var GIT_AUTHOR_IDENT
  git var GIT_COMMITTER_IDENT
}

# Metadata and added lines only: removing a term must stay possible.
commit_text() {
  git log -1 --format='%an <%ae>%n%cn <%ce>%n%B' "$1"
  git show --format= --no-color -U0 "$1" | grep -E '^(\+|rename to )' || true
}

case "${1:-}" in
staged)
  shift
  for file in "$@"; do
    scan "path $file" < <(printf '%s\n' "$file") || found=1
    git cat-file -e ":$file" 2>/dev/null || continue
    scan "staged $file" < <(git show ":$file") || found=1
  done
  ;;
message)
  [[ -f "${2:-}" ]] || fail 'message mode needs the commit message file'
  scan 'commit message' < <(grep -v '^#' "$2") || found=1
  scan 'commit identity' < <(identity) || found=1
  ;;
push)
  # Every commit not yet on any remote, so new branches and --no-verify commits
  # are covered.
  to="${PRE_COMMIT_TO_REF:-}"
  [[ -n "$to" && ! "$to" =~ ^0+$ ]] || exit 0
  while IFS= read -r commit; do
    label="commit $(git log -1 --format='%h %s' "$commit")"
    scan "$label" < <(commit_text "$commit") || found=1
  done < <(git rev-list "$to" --not --remotes)
  ;;
*) fail 'usage: private-terms.sh staged FILE... | message MSG_FILE | push' ;;
esac

if [[ "$found" -ne 0 ]]; then
  fail "matched a term from $terms_file. Move the private value to" \
    "$HOME/.config/dotfiles-local/ (outside this public repo) and try again."
fi
