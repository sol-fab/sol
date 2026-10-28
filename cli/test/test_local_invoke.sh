#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/app/billing/price_fn/bin" "$work/sol/secrets.local/billing/price_fn"
cat > "$work/sol.yml" <<'YAML'
project: local-invoke-test
services:
  price_fn:
    language: ocaml
YAML
printf 'FROM scratch\n' > "$work/app/billing/price_fn/Dockerfile"
: > "$work/app/billing/price_fn/sol.toml"
cat > "$work/app/billing/price_fn/bin/dune" <<'DUNE'
(executable (name main))
DUNE
cat > "$work/app/billing/price_fn/bin/main.ml" <<'ML'
let () =
  let input = In_channel.input_all stdin in
  print_string input;
  if input = "fail" then exit 7
ML
cat > "$work/dune-project" <<'DUNE'
(lang dune 3.0)
DUNE
printf 'first line\nsecond line\n' > "$work/event.txt"
cd "$work"

# Exact bytes go to stdin; stdout is unmodified and scriptable.
"$sol" local invoke billing/price_fn --event event.txt > "$work/out" 2> "$work/err"
cmp "$work/out" "$work/event.txt"
grep -q 'Building' "$work/err"

# Omitted event is empty stdin.
"$sol" local invoke billing/price_fn > "$work/empty-out" 2> "$work/empty-err"
[[ ! -s "$work/empty-out" ]]

# Exit status is propagated exactly.
set +e
"$sol" local invoke billing/price_fn --event <(printf 'fail') > /dev/null 2> "$work/fail-err"
code=$?
set -e
[[ "$code" -eq 7 ]]

# sol local run must not invoke functions, and explicit selection must point to invoke.
set +e
"$sol" local run --scope billing/price_fn > /dev/null 2> "$work/run-err"
run_code=$?
"$sol" local run > /dev/null 2> "$work/run-default-err"
default_code=$?
set -e
[[ "$run_code" -ne 0 ]]
[[ "$default_code" -ne 0 ]]
grep -q 'sol local invoke' "$work/run-err"
grep -q 'only -fn' "$work/run-default-err"
echo "local invoke CLI test passed"
