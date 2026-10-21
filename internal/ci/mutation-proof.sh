#!/usr/bin/env bash
# Prove a guard or a test can fail, without leaving the tree changed.
#
#   mutation-proof.sh <description> <file> <perl-substitution> <command...>
#
# Applies the mutation to <file>, runs <command>, and requires a non-zero exit: a
# guard that cannot be made to fail is not a guard. The file is then restored from a
# checksummed copy and the checksum is compared, so a proof can never damage the
# tree it proves something about.
set -uo pipefail

if [ "$#" -lt 4 ]; then
  echo "usage: mutation-proof.sh <description> <file> <perl-substitution> <command...>" >&2
  exit 2
fi

description="$1"
target="$2"
substitution="$3"
shift 3

if [ ! -f "$target" ]; then
  echo "mutation-proof: $target does not exist" >&2
  exit 2
fi

backup="$(mktemp)"
before="$(sha256sum "$target" | cut -d' ' -f1)"
cp "$target" "$backup"
restore() {
  cp "$backup" "$target"
  local after
  after="$(sha256sum "$target" | cut -d' ' -f1)"
  rm -f "$backup"
  if [ "$before" != "$after" ]; then
    echo "mutation-proof: RESTORE FAILED for $target ($before -> $after)" >&2
    return 1
  fi
  return 0
}
trap restore EXIT

perl -0pi -e "$substitution" "$target"
if [ "$(sha256sum "$target" | cut -d' ' -f1)" = "$before" ]; then
  echo "  [FAIL] $description: the mutation changed nothing"
  exit 1
fi

rc=0
"$@" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 0 ]; then
  echo "  [FAIL] $description: the guard still passed with the violation in place"
  exit 1
fi

echo "  [OK]   $description (guard exited $rc)"
exit 0
