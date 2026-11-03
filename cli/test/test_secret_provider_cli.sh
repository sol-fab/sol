#!/usr/bin/env bash
# Provider-backed application secrets, offline.
#
# The test drives the real binary against fake `aws` and `gcloud` CLIs. It establishes the
# properties that do not need a cloud: the value reaches the provider store, a repeated
# write does not create a version, deletion removes the authority, status reports the
# provider state, and no provider command line carries the value.
set -euo pipefail

sol="$(realpath "$1")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
note() {
  echo "test_secret_provider_cli: $1" >&2
  fail=1
}

mkdir -p "$tmp/workspace/app/payments/api_svc" "$tmp/workspace/sol" "$tmp/bin" "$tmp/state"

printf 'FROM scratch\n' >"$tmp/workspace/app/payments/api_svc/Dockerfile"
cat >"$tmp/workspace/app/payments/api_svc/sol.toml" <<'EOF'
[infra.env]
secrets = ["API_KEY", "OTHER_KEY"]
EOF

cat >"$tmp/workspace/sol.yml" <<'EOF'
project: provider_secret_test
services:
  api_svc:
    type: http
    path: app/payments/api_svc
    language: ocaml
EOF

cat >"$tmp/workspace/sol/environments.yml" <<'EOF'
prod:
  targets:
    aws/us-east-1:
      shape: durable
      cluster_name: planned
      kube_context: planned
      state_bucket: sol-provider-secret-state
      secrets:
        payments/api_svc:
          API_KEY:
            authority: sol
          OTHER_KEY:
            authority: sol
    gcp/us-central1:
      shape: durable
      cluster_name: planned
      kube_context: planned
      state_bucket: sol-provider-secret-state
      gcp:
        project_id: example-project
      secrets:
        payments/api_svc:
          API_KEY:
            authority: sol
          OTHER_KEY:
            authority: sol
EOF

# The fake providers keep containers and values in $STATE. Every invocation is logged so
# the test can assert that a value never appears on a command line.
cat >"$tmp/bin/aws" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws %s\n' "$*" >>"$PROVIDER_LOG"
command="$1 $2"
shift 2
name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --secret-id|--name) name="$2"; shift 2 ;;
    --tags) shift 2 ;;
    --secret-string) secret_file="${2#file://}"; shift 2 ;;
    *) shift ;;
  esac
done
case "$command" in
  "secretsmanager describe-secret")
    if [ -f "$STATE/$name.tags" ]; then
      printf '{"Name":"%s","Tags":[' "$name"
      first=1
      while IFS='=' read -r k v; do
        [ -z "$k" ] && continue
        [ "$first" = 0 ] && printf ','
        printf '{"Key":"%s","Value":"%s"}' "$k" "$v"
        first=0
      done <"$STATE/$name.tags"
      printf ']}\n'
    else
      printf "An error occurred (ResourceNotFoundException) when calling the DescribeSecret operation: Secrets Manager can't find the specified secret.\n" >&2
      exit 254
    fi
    ;;
  "secretsmanager create-secret")
    if [ -f "$STATE/$name.tags" ]; then
      printf 'An error occurred (ResourceExistsException) when calling the CreateSecret operation\n' >&2
      exit 254
    fi
    mkdir -p "$(dirname "$STATE/$name.tags")"
    : >"$STATE/$name.tags"
    shift 0
    # The tags were consumed above; capture them from the log line instead of re-parsing.
    grep -o -- '--tags Key=[^,]*,Value=[^ ]*' "$PROVIDER_LOG" | tail -n 4 \
      | sed 's/^--tags Key=//; s/,Value=/=/' >"$STATE/$name.tags"
    ;;
  "secretsmanager put-secret-value")
    [ -f "$STATE/$name.tags" ] || { printf 'NotFound\n' >&2; exit 254; }
    mkdir -p "$(dirname "$STATE/$name.value")"
    cp "$secret_file" "$STATE/$name.value"
    ;;
  "secretsmanager get-secret-value")
    if [ -f "$STATE/$name.value" ]; then
      python3 - "$STATE/$name.value" <<'PY'
import json, sys
print(json.dumps({"SecretString": open(sys.argv[1], "r", encoding="utf-8").read()}))
PY
    else
      printf "An error occurred (ResourceNotFoundException) when calling the GetSecretValue operation\n" >&2
      exit 254
    fi
    ;;
  "secretsmanager delete-secret")
    rm -f "$STATE/$name.tags" "$STATE/$name.value"
    ;;
  *)
    printf 'unexpected aws command: %s\n' "$command" >&2
    exit 2
    ;;
esac
FAKE

cat >"$tmp/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'gcloud %s\n' "$*" >>"$PROVIDER_LOG"
case "$1 $2" in
  "secrets describe")
    name="$3"
    if [ -f "$STATE/$name.tags" ]; then
      printf '{"labels":{'
      first=1
      while IFS='=' read -r k v; do
        [ -z "$k" ] && continue
        [ "$first" = 0 ] && printf ','
        printf '"%s":"%s"' "$k" "$v"
        first=0
      done <"$STATE/$name.tags"
      printf '}}\n'
    else
      printf 'ERROR: (gcloud.secrets.describe) NOT_FOUND: Secret [%s] not found.\n' "$name" >&2
      exit 1
    fi
    ;;
  "secrets create")
    name="$3"
    if [ -f "$STATE/$name.tags" ]; then
      printf 'ERROR: ALREADY_EXISTS: Secret [%s] already exists.\n' "$name" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$STATE/$name.tags")"
    for arg in "$@"; do
      case "$arg" in
        --labels=*) printf '%s\n' "${arg#--labels=}" | tr ',' '\n' >"$STATE/$name.tags" ;;
      esac
    done
    ;;
  "secrets versions")
    sub="$3"
    name=""
    data_file=""
    prev=""
    for arg in "$@"; do
      case "$arg" in
        --data-file=*) data_file="${arg#--data-file=}" ;;
      esac
      [ "$prev" = "--secret" ] && name="$arg"
      prev="$arg"
    done
    if [ "$sub" = "access" ]; then
      if [ -f "$STATE/$name.value" ]; then
        cat "$STATE/$name.value"
      else
        printf 'ERROR: (gcloud.secrets.versions.access) NOT_FOUND: version not found.\n' >&2
        exit 1
      fi
    else
      [ -n "$name" ] || name="$4"
      [ -f "$STATE/$name.tags" ] || { printf 'ERROR: NOT_FOUND\n' >&2; exit 1; }
      mkdir -p "$(dirname "$STATE/$name.value")"
      cp "$data_file" "$STATE/$name.value"
    fi
    ;;
  "secrets delete")
    name="$3"
    rm -f "$STATE/$name.tags" "$STATE/$name.value"
    ;;
  *)
    printf 'unexpected gcloud command: %s %s\n' "$1" "$2" >&2
    exit 2
    ;;
esac
FAKE

cat >"$tmp/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$KUBECTL_LOG"
case " $* " in
  *" get secret "*|*" get configmap "*)
    printf 'Error from server (NotFound): not found\n' >&2
    exit 1
    ;;
esac
exit 0
FAKE

chmod +x "$tmp/bin/aws" "$tmp/bin/gcloud" "$tmp/bin/kubectl"

export PROVIDER_LOG="$tmp/provider.log"
export KUBECTL_LOG="$tmp/kubectl.log"
export STATE="$tmp/state"
: >"$PROVIDER_LOG"
: >"$KUBECTL_LOG"

run() {
  PATH="$tmp/bin:$PATH" SOL_HOME="$(dirname "$sol")" "$sol" "$@"
}

cd "$tmp/workspace"

value="provider-secret-value-$RANDOM"
# The value is deliberately unique so a log match proves a disclosure.
set +e
set_output="$(printf '%s\n' "$value" | run secret set prod/aws/us-east-1 payments/api_svc/API_KEY --from-stdin 2>&1)"
set_rc=$?
set -e
[ "$set_rc" -eq 0 ] || note "provider write must succeed; exit was $set_rc: $set_output"
printf '%s\n' "$set_output" | grep -F 'Secret updated for payments/api_svc/API_KEY' >/dev/null \
  || note "the write must report the address: $set_output"
[ "$(cat "$STATE/sol/prod/prod-aws-us-east-1/units/payments/api-svc/API_KEY.value" 2>/dev/null)" = "$value" ] \
  || note "the value must reach the provider store"
if grep -F -- "$value" "$PROVIDER_LOG" >/dev/null; then
  note "the value must never appear on a provider command line"
fi
if [ -s "$KUBECTL_LOG" ]; then
  note "a provider write must not touch Kubernetes: $(cat "$KUBECTL_LOG")"
fi

# A repeated write is not a new rotation.
set +e
same_output="$(printf '%s\n' "$value" | run secret set prod/aws/us-east-1 payments/api_svc/API_KEY --from-stdin 2>&1)"
same_rc=$?
set -e
[ "$same_rc" -eq 0 ] || note "the repeated write must succeed: $same_output"
printf '%s\n' "$same_output" | grep -F 'already had the requested value' >/dev/null \
  || note "a repeated write must not create a version: $same_output"

rotated="provider-secret-value-rotated-$RANDOM"
printf '%s\n' "$rotated" | run secret set prod/aws/us-east-1 payments/api_svc/API_KEY --from-stdin >/dev/null
[ "$(cat "$STATE/sol/prod/prod-aws-us-east-1/units/payments/api-svc/API_KEY.value")" = "$rotated" ] \
  || note "a rotation must replace the current provider version"

status="$(run secret status prod/aws/us-east-1 2>&1)" || note "status failed: $status"
printf '%s\n' "$status" | grep -F 'payments/api_svc/API_KEY owner=sol-provider state=present' >/dev/null \
  || note "status must report the provider authority: $status"
if printf '%s\n' "$status" | grep -F -- "$rotated" >/dev/null; then
  note "status must not print a value"
fi

rm -f "$STATE/sol/prod/prod-aws-us-east-1/units/payments/api-svc/API_KEY.tags" "$STATE/sol/prod/prod-aws-us-east-1/units/payments/api-svc/API_KEY.value"
status="$(run secret status prod/aws/us-east-1 2>&1)"
printf '%s\n' "$status" | grep -F 'payments/api_svc/API_KEY owner=sol-provider state=missing' >/dev/null \
  || note "status must report a missing authority: $status"

# GCP address and lifecycle.
gcp_value="gcp-provider-secret-value-$RANDOM"
printf '%s\n' "$gcp_value" | run secret set prod/gcp/us-central1 payments/api_svc/API_KEY --from-stdin >/dev/null \
  || note "the GCP write must succeed"
[ "$(cat "$STATE/sol-prod-prod-gcp-us-central1-units-payments-api-svc-API_KEY.value" 2>/dev/null)" = "$gcp_value" ] \
  || note "the GCP value must reach Secret Manager"
if grep -F -- "$gcp_value" "$PROVIDER_LOG" >/dev/null; then
  note "the GCP value must never appear on a command line"
fi
status="$(run secret status prod/gcp/us-central1 2>&1)"
printf '%s\n' "$status" | grep -F 'payments/api_svc/API_KEY owner=sol-provider state=present' >/dev/null \
  || note "GCP status must report the provider authority: $status"

# Deletion is refused while the unit declares the key, and removes the authority once it
# does not.
set +e
run secret delete prod/gcp/us-central1 payments/api_svc/API_KEY >/dev/null 2>&1
refused_rc=$?
set -e
[ "$refused_rc" -ne 0 ] || note "deleting a currently declared key must be refused"

python3 - "$tmp/workspace/app/payments/api_svc/sol.toml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace('secrets = ["API_KEY", "OTHER_KEY"]', 'secrets = ["API_KEY"]')
open(path, "w", encoding="utf-8").write(text)
PY
run secret delete prod/gcp/us-central1 payments/api_svc/OTHER_KEY >/dev/null \
  || note "deleting an unused provider key must succeed"
[ ! -f "$STATE/sol-prod-prod-gcp-us-central1-units-payments-api-svc-OTHER_KEY.tags" ] \
  || note "deletion must remove the provider container"

[ "$fail" -eq 0 ] || exit 1
echo "provider secret CLI writes, rotates, reports and deletes without a Kubernetes Secret"
