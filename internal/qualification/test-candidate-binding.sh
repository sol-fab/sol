#!/usr/bin/env bash
# Regression for sol-fab/sol#1280.
#
# The application and framework a live qualification exercises must be built from
# the exact candidate revision, never from whatever a checkout or a moving ref
# happens to hold. This drives candidate-binding.sh against real git trees and
# refuses to accept a context that is not the candidate's.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BINDING="$HERE/candidate-binding.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  [OK]   %s\n' "$1"; pass=$((pass + 1)); }
no() {
  printf '  [FAIL] %s\n           expected: %s\n           actual:   %s\n' "$1" "$2" "$3"
  fail=$((fail + 1))
}
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else no "$1" "contains: $2" "$(tr '\n' '|' <"$3" 2>/dev/null | cut -c1-240)"; fi; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$3" "$2"; fi; }
GIT="git -c user.name=qualification -c user.email=qualification@example.invalid -c commit.gpgsign=false -c init.defaultBranch=main"

workspace="$TMP/workspace"
mkdir -p "$workspace/app/payments/orders_svc"
cat >"$workspace/pluto.opam" <<'OPAM'
opam-version: "2.0"
depends: [ "sol-svc" "kafka-eio-service" ]
pin-depends: [
  [ "sol-svc.dev"           "git+https://github.com/sol-fab/sol.git#main" ]
  [ "kafka-eio-service.dev" "git+https://github.com/sol-fab/sol.git#main" ]
]
OPAM
printf 'FROM scratch\n' >"$workspace/app/payments/orders_svc/Dockerfile"
printf 'project: scratch\n' >"$workspace/sol.yml"
$GIT -C "$workspace" init -q
$GIT -C "$workspace" add -A
$GIT -C "$workspace" commit -qm "the candidate revision"
CANDIDATE="$($GIT -C "$workspace" rev-parse HEAD)"

# A later revision, so "the checkout is not the candidate" is a real tree.
printf 'project: scratch\n# later\n' >"$workspace/sol.yml"
$GIT -C "$workspace" add -A
$GIT -C "$workspace" commit -qm "a later revision"
LATER="$($GIT -C "$workspace" rev-parse HEAD)"
$GIT -C "$workspace" checkout -q "$CANDIDATE"

# shellcheck source=candidate-binding.sh
source "$BINDING"

printf '\nthe bound context is the candidate revision\n'
context="$TMP/context"
if pins="$(umask 077; sol_candidate_bind_context "$workspace" "$CANDIDATE" "$context" 2>"$TMP/bind.err")"; then
  ok "a workspace at the candidate revision binds"
else
  no "a workspace at the candidate revision binds" "exit 0" "$(cat "$TMP/bind.err")"
fi
is "the framework pin names the candidate commit, not main" \
  "$(printf '%s\n' "$pins" | sort -u)" "github.com/sol-fab/sol.git#$CANDIDATE"
is "the context's opam pins the candidate commit" \
  "$(grep -o "github\.com/sol-fab/sol\.git#[^\"[:space:]]*" "$context/pluto.opam" | sort -u)" \
  "github.com/sol-fab/sol.git#$CANDIDATE"
is "and no pin still names a moving ref" \
  "$(grep -c '#main' "$context/pluto.opam")" "0"
is "the context carries the revision's application code" \
  "$(cat "$context/sol.yml")" "project: scratch"
is "the context is readable by a non-root build stage" \
  "$(stat -c %a "$context/sol.yml" | grep -Eq '^[4-7][4-7][4-7]$' && echo yes || echo no)" "yes"

printf '\nuntracked and modified working-tree state cannot enter the context\n'
printf 'FROM scratch\n# local edit that is not the revision\n' >"$workspace/app/payments/orders_svc/Dockerfile"
printf 'secret: local-only\n' >"$workspace/local-only.yml"
context2="$TMP/context2"
if sol_candidate_bind_context "$workspace" "$CANDIDATE" "$context2" 2>"$TMP/dirty.err"; then
  no "a modified tracked file is refused" "non-zero" "0"
else
  ok "a modified tracked file is refused"
fi
has "and the refusal names the tree, not a merge hint" "modified tracked files" "$TMP/dirty.err"
$GIT -C "$workspace" checkout -q -- app/payments/orders_svc/Dockerfile
context3="$TMP/context3"
sol_candidate_bind_context "$workspace" "$CANDIDATE" "$context3" >/dev/null 2>&1
is "an untracked file is not in the context" \
  "$([ -e "$context3/local-only.yml" ] && echo present || echo absent)" "absent"

printf '\na non-candidate checkout is refused, and nothing is built\n'
context4="$TMP/context4"
if sol_candidate_bind_context "$workspace" "$LATER" "$context4" 2>"$TMP/behind.err"; then
  no "a checkout at another revision is refused" "non-zero" "0"
else
  ok "a checkout at another revision is refused"
fi
has "and the refusal names both revisions" "$CANDIDATE" "$TMP/behind.err"
has "and the candidate revision" "$LATER" "$TMP/behind.err"
is "and no build context is left behind" \
  "$([ -e "$context4" ] && echo present || echo absent)" "absent"

printf '\nthe harness may run from a descendant of the candidate, and the application still comes from the candidate\n'
$GIT -C "$workspace" checkout -q "$LATER"
context7="$TMP/context7"
if pins7="$(sol_candidate_bind_context "$workspace" "$CANDIDATE" "$context7" 2>"$TMP/ahead.err")"; then
  ok "a harness ahead of the candidate binds the candidate"
else
  no "a harness ahead of the candidate binds the candidate" "exit 0" "$(cat "$TMP/ahead.err")"
fi
is "the context carries the candidate revision's application code, not the harness's" \
  "$(cat "$context7/sol.yml")" "project: scratch"
is "and the framework is pinned to the candidate, not to the harness revision" \
  "$(printf '%s\n' "$pins7" | sort -u)" "github.com/sol-fab/sol.git#$CANDIDATE"

printf '\nthe binding names the harness revision, so two providers can be compared\n'
sol_candidate_record_binding "$TMP/binding" "$CANDIDATE" "$workspace" "$context7" "$pins7" "$($GIT -C "$workspace" rev-parse HEAD)"
is "the record names the candidate revision" \
  "$(sed -n 's/^candidate_revision: //p' "$TMP/binding/candidate-binding.txt")" "$CANDIDATE"
is "the record names the harness revision it actually ran from" \
  "$(sed -n 's/^harness_revision: //p' "$TMP/binding/candidate-binding.txt")" "$LATER"
if sol_candidate_bind_context "$workspace" "not-a-revision" "$TMP/context5" 2>"$TMP/badrev.err"; then
  no "a release that names no revision is refused" "non-zero" "0"
else
  ok "a release that names no revision is refused"
fi
has "and the refusal says what a revision is" "40-hex commit" "$TMP/badrev.err"

printf '\na workspace that pins no framework revision is refused\n'
nopin="$TMP/nopin"
mkdir -p "$nopin"
printf 'opam-version: "2.0"\ndepends: [ "dune" ]\n' >"$nopin/pluto.opam"
printf 'x\n' >"$nopin/sol.yml"
$GIT -C "$nopin" init -q
$GIT -C "$nopin" add -A
$GIT -C "$nopin" commit -qm "no framework pin"
nopin_rev="$($GIT -C "$nopin" rev-parse HEAD)"
if sol_candidate_bind_context "$nopin" "$nopin_rev" "$TMP/context6" 2>"$TMP/nopin.err"; then
  no "a workspace with no framework pin is refused" "non-zero" "0"
else
  ok "a workspace with no framework pin is refused"
fi
has "and the refusal says the framework cannot be shown to be the candidate's" \
  "pins no Sol framework revision" "$TMP/nopin.err"

# The pin rewrite is the mechanism, so it is mutation-tested: with it removed the
# binding must not hand a moving ref to a build.
printf '\nmutation: dropping the pin rewrite cannot yield a candidate-bound context\n'
mutant_dir="$TMP/mutant"
mkdir -p "$mutant_dir"
sed 's|^    sed -i -E .*$|    :|' "$BINDING" >"$mutant_dir/candidate-binding.sh"
diff -q "$BINDING" "$mutant_dir/candidate-binding.sh" >/dev/null &&
  no "the mutation changed the script" "a different script" "identical"
(
  # shellcheck disable=SC1091
  source "$mutant_dir/candidate-binding.sh"
  sol_candidate_bind_context "$workspace" "$CANDIDATE" "$TMP/context7" >/dev/null 2>"$TMP/mutant.err"
)
if [ "$?" = "0" ]; then
  no "an unrewritten moving ref is refused" "non-zero" "0"
else
  ok "an unrewritten moving ref is refused"
fi
has "and the mutant names the ref it would have fetched" "main" "$TMP/mutant.err"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
