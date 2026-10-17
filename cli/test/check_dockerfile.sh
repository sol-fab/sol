#!/usr/bin/env bash
set -eu

case "$1" in
  /*) sol="$1" ;;
  *) sol="$(pwd)/$1" ;;
esac
tmp=$(mktemp -d)

cleanup() {
  local check_status=$?
  if [ "$check_status" -ne 0 ]; then
    for capture in present.stdout present.stderr missing.out; do
      if [ -f "$tmp/$capture" ]; then
        printf 'sol check fixture: %s\n' "$capture" >&2
        cat "$tmp/$capture" >&2
      fi
    done
  fi
  rm -rf "$tmp"
  exit "$check_status"
}
trap cleanup EXIT

mkdir -p "$tmp/app/payments/charge_svc"
printf 'FROM scratch\n' > "$tmp/app/payments/charge_svc/Dockerfile"
cd "$tmp"
touch sol.yml
"$sol" check >present.stdout 2>present.stderr
rm app/payments/charge_svc/Dockerfile
if "$sol" check >missing.out 2>&1; then
  echo 'sol check unexpectedly passed without Dockerfile' >&2
  exit 1
fi
grep -F 'Dockerfile is missing' missing.out >/dev/null
