#!/usr/bin/env bash
# A real application-secret precondition, independent of generated Kafka inputs.
# Reuse an already established namespace and candidate image; never satisfy this
# specimen's secret or apply its workload. The row's normal target owns cleanup.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
sol="$1"; context="$2"; image="$3"; evidence="$4"
private_dir="$(mktemp -d)"
specimen="$private_dir/pluto"
mkdir "$specimen"
trap 'rm -rf "$private_dir"' EXIT
cp -R "$root/internal/qualification/fixtures/application-secret-refusal/." "$specimen/"
mkdir -p "$specimen/sol"
# Context and digest come from the same target/image the application row uses.
python3 - "$context" >"$specimen/sol/environments.yml" <<'PY'
import json, sys
# JSON is valid YAML and avoids interpolating operator input into YAML scalars.
json.dump({"probe":{"targets":{"byo/qualification":{
    "kube_context":sys.argv[1], "shape":"local", "secrets":{
        "payments/secret_probe_fn":{"SOL_API_KEY":{"authority":"sol"}}}}}}},sys.stdout)
PY
rc=0
(cd "$specimen" && "$sol" deploy probe/byo/qualification --registry "${image%/*}" --image-tag secret-refusal --image-ref "secret_probe_fn=$image") >"$evidence" 2>&1 || rc=$?
if [ "$rc" = 0 ] || ! grep -Fq 'does not hold the required non-empty secret key(s): SOL_API_KEY' "$evidence"; then
  printf 'application-secret specimen did not establish the required missing-secret refusal (exit %s)\n' "$rc" >&2
  exit 1
fi
printf 'application_secret_refusal: declared SOL_API_KEY was absent; candidate deploy refused\n'
