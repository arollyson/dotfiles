#!/usr/bin/env bash
# hooks/private-terms.sh in a scratch repository with synthetic terms, so this
# public test never names a real private term.
set -euo pipefail
source_repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
hook="$source_repo/hooks/private-terms.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-private-terms.XXXXXX")"
cleanup() {
  # Scoped to the directory mktemp just created.
  if [[ $scratch == "${TMPDIR:-/tmp}"/dotfiles-private-terms.* ]]; then
    find "$scratch" -depth -delete
  fi
}
trap cleanup EXIT
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

terms="$scratch/terms"
printf '# synthetic\nzebracorn\nmoon-base[0-9]\n' >"$terms"
repo="$scratch/repo"
git init -q "$repo"
cd "$repo"
git config user.name Tester
git config user.email tester@example.com
git config commit.gpgsign false
unset CI

# Runs the hook with the given terms file; prints "blocked" or "allowed".
run() {
  local list="$1"
  shift
  if DOTFILES_PRIVATE_TERMS="$list" "$hook" "$@" >"$scratch/out" 2>&1; then
    printf 'allowed\n'
  else
    printf 'blocked\n'
  fi
}
expect() {
  [[ $2 == "$3" ]] || fail "$1: expected $3, got $2 ($(tr '\n' ' ' <"$scratch/out"))"
  printf 'ok    %s\n' "$1"
}

printf 'clean\n' >clean.txt
printf 'path=moon-base7\n' >leak.txt
printf 'x\n' >zebracorn.txt
git add clean.txt leak.txt zebracorn.txt
message="$scratch/message"
printf 'Tidy notes\n# zebracorn in a comment is ignored\n' >"$message"

expect 'clean staged file passes' "$(run "$terms" staged clean.txt)" allowed
expect 'term in staged content blocks' "$(run "$terms" staged clean.txt leak.txt)" blocked
expect 'term in file name blocks' "$(run "$terms" staged zebracorn.txt)" blocked
expect 'clean message and identity pass' "$(run "$terms" message "$message")" allowed
printf 'Fix zebracorn setup\n' >"$scratch/bad-message"
expect 'term in commit message blocks' "$(run "$terms" message "$scratch/bad-message")" blocked
expect 'term in committer identity blocks' \
  "$(GIT_COMMITTER_EMAIL=me@zebracorn.example run "$terms" message "$message")" blocked

# A malformed regex must fail closed in every mode, even with a valid term
# listed alongside it that would otherwise match.
printf 'zebracorn\n(unbalanced\n' >"$scratch/malformed"
expect 'malformed list blocks staged scan' "$(run "$scratch/malformed" staged clean.txt)" blocked
grep -q 'invalid regex' "$scratch/out" || fail 'malformed list did not report the invalid regex'
expect 'malformed list blocks message scan' "$(run "$scratch/malformed" message "$message")" blocked
expect 'malformed list blocks push scan' \
  "$(PRE_COMMIT_TO_REF=HEAD run "$scratch/malformed" push)" blocked

expect 'missing list blocks locally' "$(run "$scratch/absent" staged clean.txt)" blocked
expect 'missing list skips in CI' "$(CI=true run "$scratch/absent" staged clean.txt)" allowed
: >"$scratch/empty"
expect 'empty list opts out' "$(run "$scratch/empty" staged leak.txt)" allowed

# Push scans commits absent from every remote-tracking ref.
git rm -q --cached leak.txt zebracorn.txt
git commit -q -m base
git update-ref refs/remotes/origin/main HEAD
printf 'alias go=zebracorn\n' >>clean.txt
git commit -q -am 'add alias'
expect 'unpushed commit adding a term blocks' "$(PRE_COMMIT_TO_REF="$(git rev-parse HEAD)" run "$terms" push)" blocked
git update-ref refs/remotes/origin/main HEAD
git checkout -q HEAD~1 -- clean.txt
git commit -q -am 'drop alias'
expect 'unpushed commit removing a term passes' "$(PRE_COMMIT_TO_REF="$(git rev-parse HEAD)" run "$terms" push)" allowed
expect 'branch deletion push passes' "$(PRE_COMMIT_TO_REF=0000000000000000000000000000000000000000 run "$terms" push)" allowed
