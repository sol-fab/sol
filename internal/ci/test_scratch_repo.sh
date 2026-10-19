#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/scratch_repo.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "  [OK]   $1"; }
fail() {
  echo "  [FAIL] $1" >&2
  exit 1
}

real="$tmp/real"
scratch_repo_init "$real" -b main
git -C "$real" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
before="$(git -C "$real" rev-parse --absolute-git-dir)"
scratch_repo_assert "$real" || fail "a repository made by scratch_repo_init must resolve inside itself"
pass "scratch_repo_init creates a repository that resolves inside itself"

[ "$(git -C "$real" config --get maintenance.auto)" = "false" ] \
  || fail "scratch_repo_init left background maintenance enabled"
[ "$(git -C "$real" config --get gc.auto)" = "0" ] \
  || fail "scratch_repo_init left automatic gc enabled"
pass "scratch_repo_init disables background maintenance so cleanup cannot race a pack write"

if scratch_repo_assert "$tmp/absent" 2>"$tmp/assert.err"; then
  fail "scratch_repo_assert accepted a directory that is not a repository"
fi
pass "scratch_repo_assert refuses a directory that is not a repository"

if (export GIT_DIR="$real/.git"; scratch_repo_init "$tmp/leaked" -b main) 2>"$tmp/leak.err"; then
  fail "scratch_repo_init initialized a repository while GIT_DIR was exported"
fi
[ -e "$tmp/leaked/.git" ] && fail "scratch_repo_init created a repository despite refusing"
grep -q 'GIT_DIR' "$tmp/leak.err" \
  || fail "the refusal does not name the leaked variable: $(cat "$tmp/leak.err")"
[ "$(git -C "$real" rev-parse --absolute-git-dir)" = "$before" ] \
  || fail "the repository GIT_DIR named changed"
pass "a leaked GIT_DIR is refused, named, and leaves the named repository untouched"

leaked="$(
  cd "$HERE"
  GIT_DIR="$real/.git" bash -c 'source ./lib/scratch_repo.sh; scratch_repo_sanitize; printf %s "${GIT_DIR:-clean}"'
)"
[ "$leaked" = "clean" ] || fail "scratch_repo_sanitize did not clear GIT_DIR (got '$leaked')"
pass "scratch_repo_sanitize clears a leaked GIT_DIR so a caller cannot choose the repository"

echo ""
echo "scratch-repo identity: all expectations hold."
