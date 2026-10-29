#!/usr/bin/env bash
# The framework setup script must derive one package set from the root *.opam
# contracts, exclude the CLI package, and fail closed when there are no package
# contracts. Use a fake opam so this test never touches the developer's switch.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="$root/platform/local/scripts/prepare-framework-deps.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/bin"
cat >"$scratch/bin/opam" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_OPAM_LOG"
if [ "${1:-} ${2:-}" = "var prefix" ]; then
  printf '/fake-switch\n'
fi
exit 0
SH
chmod +x "$scratch/bin/opam"

make_checkout() {
  local checkout="$1"
  mkdir -p "$checkout/platform/local/scripts"
  cp "$script" "$checkout/platform/local/scripts/prepare-framework-deps.sh"
}

run_script() {
  local checkout="$1" log="$2" out="$3" err="$4"
  PATH="$scratch/bin:$PATH" FAKE_OPAM_LOG="$log" \
    bash "$checkout/platform/local/scripts/prepare-framework-deps.sh" >"$out" 2>"$err"
}

checkout="$scratch/checkout"
make_checkout "$checkout"
for package in sol-svc sol-task kafka-eio-service sol; do
  : >"$checkout/$package.opam"
done
log="$scratch/opam.log"
run_script "$checkout" "$log" "$scratch/out" "$scratch/err"

python3 - "$log" <<'PY'
import sys

log = sys.argv[1]
pin = []
install = []
for raw in open(log):
    args = raw.split()
    if not args:
        continue
    if args[:2] == ["pin", "add"]:
        # pin add -y --kind=path <package> <path>
        pin.append(args[4])
    elif args[0] == "install":
        # install -y <package>...
        install.extend(args[2:])

expected = {"kafka-eio-service", "sol-svc", "sol-task"}
if set(pin) != expected:
    raise SystemExit(f"unexpected pinned set: {sorted(pin)}; expected {sorted(expected)}")
if set(install) != expected:
    raise SystemExit(f"unexpected installed set: {sorted(install)}; expected {sorted(expected)}")
if set(pin) != set(install):
    raise SystemExit(f"pin and install sets differ: {sorted(pin)} vs {sorted(install)}")
if "sol" in pin or "sol" in install:
    raise SystemExit("the CLI package sol must be excluded")
print("framework dependency selection: expected packages pinned and installed; sol excluded")
PY

empty="$scratch/empty"
make_checkout "$empty"
empty_log="$scratch/empty-opam.log"
if run_script "$empty" "$empty_log" "$scratch/empty.out" "$scratch/empty.err"; then
  echo "FAIL: an empty package set was accepted" >&2
  exit 1
fi
if ! grep -q 'no package \.opam files' "$scratch/empty.err"; then
  echo "FAIL: the empty package set did not explain the failure" >&2
  cat "$scratch/empty.err" >&2
  exit 1
fi
if [ -s "$empty_log" ]; then
  echo "FAIL: an empty package set reached opam" >&2
  cat "$empty_log" >&2
  exit 1
fi
echo "framework dependency selection: empty package set fails closed before opam"
