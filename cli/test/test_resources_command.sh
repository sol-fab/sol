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
    echo "test_resources_command: $what: expected [$expected], got [$actual]" >&2
    fail=1
  fi
}

mkdir -p "$tmp/bin" "$tmp/work/sol" "$tmp/xdg"

cat >"$tmp/empty-state.json" <<'EOF'
{"values":{"root_module":{"resources":[]}}}
EOF

cat >"$tmp/platform-state.json" <<'EOF'
{"values":{"root_module":{"resources":[{"address":"kubernetes_namespace.app","mode":"managed","type":"kubernetes_namespace","name":"app","values":{"name":"app"}}]}}}
EOF

cat >"$tmp/bin/terraform" <<'EOF'
#!/bin/sh
printf 'terraform %s\n' "$*" >>"$LIFECYCLE_LOG"
case " $* " in
  *" show -json"*)
    case "$*" in
      *"/aws/platform"*) cat "$PLATFORM_STATE" ;;
      *) cat "$EMPTY_STATE" ;;
    esac
    ;;
esac
exit 0
EOF

cat >"$tmp/bin/aws" <<'EOF'
#!/bin/sh
printf 'aws %s\n' "$*" >>"$LIFECYCLE_LOG"
case "$1 $2" in
  "configure export-credentials")
    printf 'export AWS_ACCESS_KEY_ID=test\nexport AWS_SECRET_ACCESS_KEY=test\nexport AWS_SESSION_TOKEN=test\n'
    ;;
  "sts get-caller-identity")
    case " $* " in
      *" --query Arn "*) printf 'arn:aws:iam::111122223333:role/test\n' ;;
      *) printf '{"UserId":"test","Account":"111122223333","Arn":"arn:aws:iam::111122223333:role/test"}\n' ;;
    esac
    ;;
esac
exit 0
EOF

chmod +x "$tmp/bin/terraform" "$tmp/bin/aws"

cat >"$tmp/work/sol.yml" <<'EOF'
project: resources-test
EOF

cat >"$tmp/work/sol/environments.yml" <<'EOF'
qual:
  base_domain: qual.example.test
  dns_zone_ownership: user
  shape: local
  letsencrypt_email: ops@qual.example.test
  targets:
    aws/us-east-1:
      cluster_name: inv-cluster
      state_bucket: inv-state
      aws:
        state_lock_table: inv-lock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
EOF

export SOL_HOME="$root"
export LIFECYCLE_LOG="$tmp/lifecycle.log"
export PLATFORM_STATE="$tmp/platform-state.json"
export EMPTY_STATE="$tmp/empty-state.json"

run() {
  rm -f "$tmp/lifecycle.log"
  set +e
  output="$(
    cd "$tmp/work" &&
      XDG_DATA_HOME="$tmp/xdg" PATH="$tmp/bin:/usr/bin:/bin" \
        AWS_PROFILE=test "$sol" resources qual/aws/us-east-1 --state-only "$@" 2>"$tmp/err"
  )"
  rc=$?
  set -e
}

run --json --all
check "state-only exits 1" 1 "$rc"
if ! printf '%s' "$output" | jq -e '.verdict == "unverified"' >/dev/null 2>&1; then
  echo "test_resources_command: expected verdict unverified" >&2
  printf '%s\n' "$output" | head -40 >&2
  fail=1
fi
if ! printf '%s' "$output" | jq -e '.coverage.inventory.complete == true' >/dev/null 2>&1; then
  echo "test_resources_command: inventory should be complete" >&2
  fail=1
fi
if ! printf '%s' "$output" | jq -e '.coverage.verification.complete == false' >/dev/null 2>&1; then
  echo "test_resources_command: state-only must not claim verification" >&2
  fail=1
fi
if ! printf '%s' "$output" | jq -e '.resources[] | select(.layer == "platform") | .status == "in_cluster"' >/dev/null 2>&1; then
  echo "test_resources_command: expected a platform in_cluster row" >&2
  fail=1
fi
if printf '%s' "$output" | jq -e '.resources[] | select(.address == "kubernetes_namespace.app") | .status == "owned"' >/dev/null 2>&1; then
  echo "test_resources_command: a by-contract row was claimed owned" >&2
  fail=1
fi
if grep -E 'aws (ec2|eks|rds|iam|s3api|elbv2|cloudwatch|logs)' "$tmp/lifecycle.log" >/dev/null 2>&1; then
  echo "test_resources_command: --state-only ran a provider probe" >&2
  fail=1
fi

run
check "state-only text exits 1" 1 "$rc"
case "$output" in
  *"Verdict   unverified"*) ;;
  *)
    echo "test_resources_command: text output omitted the unverified verdict" >&2
    printf '%s\n' "$output" >&2
    fail=1
    ;;
esac

run --json --all --class=kubernetes_namespace
if ! printf '%s' "$output" | jq -e '.resources | length == 1 and .[0].resource_class == "kubernetes_namespace"' >/dev/null 2>&1; then
  echo "test_resources_command: --class did not filter the inventory" >&2
  fail=1
fi

run --json --all --status=in_cluster
if ! printf '%s' "$output" | jq -e '.resources | length == 1' >/dev/null 2>&1; then
  echo "test_resources_command: --status did not filter the inventory" >&2
  fail=1
fi

exit "$fail"
