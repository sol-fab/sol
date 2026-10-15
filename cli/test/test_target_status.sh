#!/usr/bin/env bash
set -euo pipefail

sol="$(realpath "${1:-}")"
root="$(cd "$(dirname "$sol")" && git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$root" ] || root="$(cd "$(dirname "$sol")/../../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "test_target_status: $what: expected [$expected], got [$actual]" >&2
    fail=1
  fi
}
check_contains() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *)
      echo "test_target_status: $what: expected to find '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}
check_absent() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "test_target_status: $what: did not expect '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}
row() {
  local label="$1" text="$2"
  printf '%s\n' "$text" | sed -n "s/^${label} *//p" | head -n1
}

mkdir -p "$tmp/bin" "$tmp/work/sol" "$tmp/xdg"

cat >"$tmp/bin/terraform" <<'EOF'
#!/bin/sh
printf 'terraform %s\n' "$*" >>"$LIFECYCLE_LOG"
case " $* " in
  *" init "*) exit 0 ;;
  *"-refresh-only"*) exit "${DRIFT_EXIT:-0}" ;;
  *) exit 0 ;;
esac
EOF

cat >"$tmp/bin/aws" <<'EOF'
#!/bin/sh
printf 'aws %s\n' "$*" >>"$LIFECYCLE_LOG"
if [ "${CLOUD_HEALTH:-ok}" = unknown ]; then
  printf 'An error occurred (AccessDenied) when calling the operation: not authorized\n' >&2
  exit 255
fi
case "$1 $2" in
  "s3api head-bucket")
    if [ "${CLOUD_HEALTH:-ok}" = unmet ]; then
      printf 'An error occurred (404) when calling the HeadBucket operation: Not Found\n' >&2
      exit 254
    fi
    printf '{"Bucket":"sol-qual-tfstate"}\n'
    ;;
  "dynamodb describe-table") printf '{"Table":{"TableName":"sol-qual-tflock"}}\n' ;;
  "iam get-role") printf '{"Role":{"Arn":"arn:aws:iam::111122223333:role/sol"}}\n' ;;
  "route53 list-hosted-zones-by-name") printf '{"HostedZones":[{"Name":"qual.example.test."}]}\n' ;;
esac
exit 0
EOF

cat >"$tmp/bin/dig" <<'EOF'
#!/bin/sh
printf 'ns-1.qual.example.test.\n'
EOF

cat >"$tmp/bin/kubectl" <<'EOF'
#!/bin/sh
printf 'kubectl %s\n' "$*" >>"$LIFECYCLE_LOG"
printf 'error: the context does not exist\n' >&2
exit 1
EOF

chmod +x "$tmp/bin/terraform" "$tmp/bin/aws" "$tmp/bin/dig" "$tmp/bin/kubectl"

cat >"$tmp/work/sol.yml" <<'EOF'
project: target-status-test
EOF

cat >"$tmp/work/sol/environments.yml" <<'EOF'
qual:
  base_domain: qual.example.test
  dns_zone_ownership: sol
  shape: local
  letsencrypt_email: ops@qual.example.test
  targets:
    aws/us-east-1:
      cluster_name: sol-qual
      state_bucket: sol-qual-tfstate
      aws:
        state_lock_table: sol-qual-tflock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
    aws/reserved:
      kube_context: k3d-sol-local
    aws/probe:
      kube_context: qual-deploy
EOF

export SOL_HOME="$root"
export LIFECYCLE_LOG="$tmp/lifecycle.log"

run_case() {
  local target="$1" drift_exit="$2" cloud_health="$3"
  shift 3
  rm -f "$tmp/lifecycle.log"
  set +e
  output="$(
    cd "$tmp/work" &&
      XDG_DATA_HOME="$tmp/xdg" PATH="$tmp/bin:/usr/bin:/bin" \
        DRIFT_EXIT="$drift_exit" CLOUD_HEALTH="$cloud_health" \
        "$sol" target show --target "$target" "$@" 2>&1
  )"
  rc=$?
  set -e
}

run() {
  local drift_exit="$1" cloud_health="$2"
  shift 2
  run_case qual/aws/us-east-1 "$drift_exit" "$cloud_health" "$@"
}

run 0 ok --check
check "the run exits 0" 0 "$rc"
check "an established installation reads Healthy" "Healthy" "$(row cloud "$output")"
check_contains "a clean refresh reads None" "None" "$(row drift "$output")"
check_contains "last operation reports unavailability" "unavailable" "$(row 'last operation' "$output")"
check_absent "the status read does not echo the terraform it runs" '$ terraform' "$output"

run_case qual/aws/probe 0 ok --check
check "the probe target run exits 0" 0 "$rc"
check_contains "a refused platform probe reads Unobservable" "Unobservable — " "$(row platform "$output")"
check_contains "and keeps the probe's own detail" "the context does not exist" "$(row platform "$output")"
check_absent "a refused probe is never a confirmed unmet condition" "Unmet" "$(row platform "$output")"

run 0 unmet --check
check_contains "an absent prerequisite reads Unmet" "Unmet — " "$(row cloud "$output")"
check_absent "an absent prerequisite is never Healthy" "Healthy" "$(row cloud "$output")"

run 0 unknown --check
check_contains "a refused provider read reads Unknown" "Unknown — " "$(row cloud "$output")"
check_absent "an unobservable installation is never Healthy" "Healthy" "$(row cloud "$output")"
check_absent "and never Unmet" "Unmet" "$(row cloud "$output")"

run 2 ok --check
check_contains "a changed refresh reads Detected" "Detected" "$(row drift "$output")"
check_absent "drift is never reported as None" "None" "$(row drift "$output")"

run 1 ok --check
check_contains "a failing refresh reads Unknown" "Unknown — " "$(row drift "$output")"
check_absent "a failing refresh is never None" "None" "$(row drift "$output")"

run 0 ok
check "the offline summary omits the cloud row" "" "$(row cloud "$output")"
check "the offline summary omits the drift row" "" "$(row drift "$output")"
check_contains "the offline summary still reports last operation" "unavailable" "$(row 'last operation' "$output")"
check "the offline invocation runs no cloud tool" "" "$(cat "$tmp/lifecycle.log" 2>/dev/null)"

run 0 ok --check --json
if printf '%s' "$output" | jq -e 'has("cloud") and has("drift") and has("last operation")' >/dev/null 2>&1; then
  :
else
  echo "test_target_status: --json did not emit parseable JSON with the live state fields:" >&2
  echo "$output" >&2
  fail=1
fi
check_absent "the json run does not echo terraform either" '$ terraform' "$output"

run_case qual/aws/reserved 0 ok
check_contains "a reserved local destination is reported as a refusal" "reserved execution mode" "$(row kubernetes "$output")"
check_absent "a reserved local destination is never reported as an unset kube_context" "names no kube_context" "$(row kubernetes "$output")"
check_absent "the reserved context is hidden by default" "k3d-sol-local" "$output"

mv "$tmp/work/sol/environments.yml" "$tmp/work/sol/environments.yml.readable"
printf 'qual:\n  targets: [\n' >"$tmp/work/sol/environments.yml"
run_case qual/aws/us-east-1 0 ok
mv "$tmp/work/sol/environments.yml.readable" "$tmp/work/sol/environments.yml"
check "an unreadable workspace fails" 1 "$rc"
check_contains "an unreadable workspace names the read failure" "could not be read" "$output"
check_absent "an unreadable workspace does not claim no targets are declared" "no targets found" "$output"

exit "$fail"
