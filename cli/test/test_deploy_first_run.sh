#!/usr/bin/env bash
set -euo pipefail

sol="$(realpath "${1:-}")"
tmp="$(mktemp -d)"
export SOL_WHOAMI_RETRY_INTERVAL_S=0
export SOL_PLATFORM_READINESS_TIMEOUT_S=0
# This fixture tests installation observations after deterministic image preflight.
export SOL_SETUP_POSTGRES_IMAGE="postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "test_deploy_first_run: $what: expected $expected, got $actual" >&2
    fail=1
  fi
}
check_contains() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *)
      echo "test_deploy_first_run: $what: expected to find '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}
check_absent() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "test_deploy_first_run: $what: did not expect '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}

mkdir -p "$tmp/work/sol" "$tmp/work/app/payments/charge_svc" "$tmp/data"
cat >"$tmp/work/sol.yml" <<'EOF'
project: first-run-test
resources:
  app_db:
    type: postgres
services:
  charge_svc:
    language: ocaml
EOF
cat >"$tmp/work/app/payments/charge_svc/sol.toml" <<'EOF'
[infra.scale]
replicas = 1
EOF
cat >"$tmp/work/app/payments/charge_svc/Dockerfile" <<'EOF'
FROM scratch
EOF
cat >"$tmp/work/sol/environments.yml" <<'EOF'
prod:
  base_domain: prod.example.test
  shape: local
  dns_zone_ownership: sol
  targets:
    aws/us-east-1:
      cluster_name: first-run-prod
      letsencrypt_email: ops@example.test
      cluster_endpoint_cidr: 203.0.113.0/24
      state_bucket: first-run-tfstate
      secrets:
        payments/charge_svc:
          POSTGRES_URL:
            authority: sol
          SOL_API_KEY:
            authority: sol
          KAFKA_SASL_PASSWORD:
            authority: sol
          KAFKA_SSL_CA_CERT:
            authority: sol
      aws:
        state_lock_table: first-run-tflock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
stale:
  base_domain: stale.example.test
  shape: local
  dns_zone_ownership: sol
  targets:
    aws/us-east-1:
      cluster_name: first-run-stale
      letsencrypt_email: ops@example.test
      cluster_endpoint_cidr: 203.0.113.0/24
      kube_context: first-run-stale
      state_bucket: first-run-tfstate
      secrets:
        payments/charge_svc:
          POSTGRES_URL:
            authority: sol
          SOL_API_KEY:
            authority: sol
          KAFKA_SASL_PASSWORD:
            authority: sol
          KAFKA_SSL_CA_CERT:
            authority: sol
      aws:
        state_lock_table: first-run-tflock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
EOF

mkdir -p "$tmp/bin-absent" "$tmp/bin-partial" "$tmp/bin-denied" "$tmp/bin-unresolvable" "$tmp/bin-installed" "$tmp/bin-first" "$tmp/bin-no-identity" "$tmp/bin-tf"

cat >"$tmp/bin-absent/aws" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/aws.log"
case "\$1 \$2" in
  "s3api head-bucket")
    printf '%s\n' 'An error occurred (404) when calling the HeadBucket operation: Not Found' >&2
    exit 254
    ;;
  "dynamodb describe-table")
    printf '%s\n' 'An error occurred (ResourceNotFoundException) when calling the DescribeTable operation: Requested resource not found' >&2
    exit 254
    ;;
  "iam get-role")
    printf '%s\n' 'An error occurred (NoSuchEntity) when calling the GetRole operation: The role cannot be found.' >&2
    exit 254
    ;;
  "route53 list-hosted-zones-by-name")
    printf '%s\n' '{"HostedZones":[]}'
    ;;
esac
exit 0
EOF

cat >"$tmp/bin-partial/aws" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/aws.log"
case "\$1 \$2" in
  "configure export-credentials")
    printf 'export AWS_ACCESS_KEY_ID=AKIAEXAMPLE\n'
    printf 'export AWS_SECRET_ACCESS_KEY=example-secret\n'
    ;;
  "s3api head-bucket")
    printf '%s\n' 'An error occurred (404) when calling the HeadBucket operation: Not Found' >&2
    exit 254
    ;;
  "iam get-role")
    printf '%s\n' '{"Role":{"Arn":"arn:aws:iam::111122223333:role/sol-deploy"}}'
    ;;
  "route53 list-hosted-zones-by-name")
    printf '%s\n' '{"HostedZones":[]}'
    ;;
esac
exit 0
EOF

cat >"$tmp/bin-no-identity/aws" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/aws.log"
case "\$1 \$2" in
  "configure export-credentials")
    printf 'export AWS_ACCESS_KEY_ID=AKIAEXAMPLE\n'
    printf 'export AWS_SECRET_ACCESS_KEY=example-secret\n'
    ;;
  "s3api head-bucket")
    printf '%s\n' 'An error occurred (404) when calling the HeadBucket operation: Not Found' >&2
    exit 254
    ;;
  "dynamodb describe-table")
    printf '%s\n' 'An error occurred (ResourceNotFoundException) when calling the DescribeTable operation: Requested resource not found' >&2
    exit 254
    ;;
  "iam get-role")
    printf '%s\n' 'An error occurred (NoSuchEntity) when calling the GetRole operation: The role cannot be found.' >&2
    exit 254
    ;;
  "route53 list-hosted-zones-by-name")
    zone=""
    previous=""
    for argument in "\$@"; do
      if [ "\$previous" = "--dns-name" ]; then zone="\$argument"; fi
      previous="\$argument"
    done
    printf '{"HostedZones":[{"Id":"/hostedzone/Z0123","Name":"%s.","Config":{"PrivateZone":false}}]}\n' "\$zone"
    ;;
esac
exit 0
EOF

cat >"$tmp/bin-denied/aws" <<'EOF'
#!/bin/sh
printf '%s\n' 'An error occurred (AccessDenied) when calling the operation: User is not authorized to perform this action' >&2
exit 255
EOF
cat >"$tmp/bin-denied/dig" <<'EOF'
#!/bin/sh
printf '%s\n' 'ns-1.awsdns-08.org.'
printf '%s\n' 'ns-2.awsdns-08.org.'
exit 0
EOF

cat >"$tmp/bin-unresolvable/dig" <<'EOF'
#!/bin/sh
exit 0
EOF

cat >"$tmp/bin-installed/aws" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/aws.log"
case "\$1 \$2" in
  "configure export-credentials")
    printf 'export AWS_ACCESS_KEY_ID=AKIAEXAMPLE\n'
    printf 'export AWS_SECRET_ACCESS_KEY=example-secret\n'
    ;;
  "eks describe-cluster")
    case " \$* " in
      *" --query cluster.identity.oidc.issuer "*)
        printf 'https://oidc.eks.us-east-1.amazonaws.com/id/FIRST-RUN\n'
        ;;
      *) printf 'ACTIVE\n' ;;
    esac
    ;;
  "eks describe-addon")
    printf 'ACTIVE\n'
    ;;
  "iam get-role")
    printf '%s\n' '{"Role":{"Arn":"arn:aws:iam::111122223333:role/sol-deploy"}}'
    ;;
  "route53 list-hosted-zones-by-name")
    zone=""
    previous=""
    for argument in "\$@"; do
      if [ "\$previous" = "--dns-name" ]; then zone="\$argument"; fi
      previous="\$argument"
    done
    printf '{"HostedZones":[{"Id":"/hostedzone/Z0123","Name":"%s.","Config":{"PrivateZone":false}}]}\n' "\$zone"
    ;;
esac
exit 0
EOF

mkdir -p "$tmp/bin-kubectl"
cat >"$tmp/bin-kubectl/kubectl" <<'EOF'
#!/bin/sh
printf '%s\n' 'error: no context exists with the name "first-run-stale"' >&2
exit 1
EOF

cat >"$tmp/bin-installed/dig" <<'EOF'
#!/bin/sh
printf '%s\n' 'ns-1.awsdns-08.org.'
printf '%s\n' 'ns-2.awsdns-08.org.'
exit 0
EOF
cp "$tmp/bin-installed/dig" "$tmp/bin-first/dig" 2>/dev/null || true

mkdir -p "$tmp/bin-stuck"
cat >"$tmp/bin-stuck/dig" <<'EOF'
#!/bin/sh
printf '%s\n' 'ns-1.awsdns-08.org.'
printf '%s\n' 'ns-2.awsdns-08.org.'
exit 0
EOF
cat >"$tmp/bin-stuck/aws" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/aws.log"
case "\$1 \$2" in
  "configure export-credentials")
    printf 'export AWS_ACCESS_KEY_ID=AKIAEXAMPLE\n'
    printf 'export AWS_SECRET_ACCESS_KEY=example-secret\n'
    ;;
  "s3api head-bucket")
    printf '%s\n' 'An error occurred (404) when calling the HeadBucket operation: Not Found' >&2
    exit 254
    ;;
esac
exit 0
EOF

cat >"$tmp/bin-first/aws" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/aws.log"
case "\$1 \$2" in
  "configure export-credentials")
    printf 'export AWS_ACCESS_KEY_ID=AKIAEXAMPLE\n'
    printf 'export AWS_SECRET_ACCESS_KEY=example-secret\n'
    ;;
  "route53 list-hosted-zones-by-name")
    zone=""
    previous=""
    for argument in "\$@"; do
      if [ "\$previous" = "--dns-name" ]; then zone="\$argument"; fi
      previous="\$argument"
    done
    case "\$zone" in
      example.test)
        # The zone that publishes prod.example.test is already in the account.
        printf '%s\n' '{"HostedZones":[{"Id":"/hostedzone/ZPARENT","Name":"example.test.","Config":{"PrivateZone":false}}]}'
        ;;
      *)
        if [ -f "$tmp/applied" ]; then
          printf '{"HostedZones":[{"Id":"/hostedzone/Z0123","Name":"%s.","Config":{"PrivateZone":false}}]}\n' "\$zone"
        else
          printf '%s\n' '{"HostedZones":[]}'
        fi
        ;;
    esac
    exit 0
    ;;
esac
if [ -f "$tmp/applied" ]; then
  case "\$1 \$2" in
    "iam get-role") printf '%s\n' '{"Role":{"Arn":"arn:aws:iam::111122223333:role/sol-deploy"}}' ;;
  esac
  exit 0
fi
case "\$1 \$2" in
  "s3api head-bucket")
    printf '%s\n' 'An error occurred (404) when calling the HeadBucket operation: Not Found' >&2
    exit 254
    ;;
  "dynamodb describe-table")
    printf '%s\n' 'An error occurred (ResourceNotFoundException) when calling the DescribeTable operation: not found' >&2
    exit 254
    ;;
  "iam get-role")
    printf '%s\n' 'An error occurred (NoSuchEntity) when calling the GetRole operation: cannot be found' >&2
    exit 254
    ;;
esac
exit 0
EOF

cat >"$tmp/bin-tf/terraform" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/terraform.log"
tf_chdir=
for argument in "\$@"; do
  case "\$argument" in
    -chdir=*) tf_chdir="\${argument#-chdir=}" ;;
  esac
done
case " \$* " in
  *" state list "*)
    if [ -f "$tmp/unreadable-state" ]; then
      printf '%s\n' 'Error: the backend could not be reached' >&2
      exit 1
    fi
    if [ -f "$tmp/fresh-state" ]; then
      printf '%s\n' 'No state file was found!' >&2
      exit 1
    fi
    case "\$tf_chdir" in
      *cloud/aws/cluster*) printf '%s\n' 'module.eks.aws_eks_cluster.this[0]' ;;
      *) printf '%s\n' 'aws_s3_bucket.state' ;;
    esac
    exit 0
    ;;
  *" state pull "*)
    if [ -f "$tmp/unreadable-state" ]; then
      printf '%s\n' 'Error: the backend could not be reached' >&2
      exit 1
    fi
    exit 0
    ;;
  *" init "*) exit 0 ;;
  *" plan "*)
    for argument in "\$@"; do
      case "\$argument" in
        -out=*) : >"\${argument#-out=}" ;;
      esac
    done
    exit 0
    ;;
  *" show "*) cat "$tmp/plan.json"; exit 0 ;;
  *" output -json "*)
    case "\$tf_chdir" in
      *cloud/aws/cluster*) cat "$tmp/cluster-outputs.json" ;;
      *) cat "$tmp/outputs.json" ;;
    esac
    exit 0
    ;;
  *" apply "*) touch "$tmp/applied"; exit 0 ;;
esac
exit 0
EOF

cat >"$tmp/bin-tf/kubectl" <<'EOF'
#!/bin/sh
case "\$1 \$2" in
  "auth whoami")
    printf '%s\n' '{"status":{"userInfo":{"username":"first-run","extra":{"canonicalArn":"arn:aws:iam::111122223333:role/sol-cluster-access"}}}}'
    ;;
  "auth can-i") printf 'yes\n' ;;
  *) printf 'ok\n' ;;
esac
exit 0
EOF

cp "$tmp/bin-installed/dig" "$tmp/bin-no-identity/dig" 2>/dev/null || true
chmod +x "$tmp"/bin-*/*

printf '%s\n' \
  '{"dns_zone_nameservers":{"sensitive":false,"value":["ns-1.awsdns-08.org","ns-2.awsdns-08.org"]},
    "provisioner_policy_json":{"sensitive":false,"value":{"Version":"2012-10-17","Statement":[{"Sid":"sol-provisioner"}]}},
    "cluster_access_policy_json":{"sensitive":false,"value":{"Version":"2012-10-17","Statement":[{"Sid":"sol-cluster-access"}]}},
    "deploy_policy_json":{"sensitive":false,"value":{"Version":"2012-10-17","Statement":[{"Sid":"sol-deploy"}]}},
    "operator_policy_json":{"sensitive":false,"value":{"Version":"2012-10-17","Statement":[{"Sid":"sol-operator"}]}}}' \
  >"$tmp/outputs.json"
printf '%s\n' \
  '{"resource_changes":[{"address":"aws_s3_bucket.state","type":"aws_s3_bucket","mode":"managed","change":{"actions":["create"]}}]}' \
  >"$tmp/plan.json"

printf '%s\n' \
  '{"cluster_name":{"sensitive":false,"value":"first-run-prod"},"cluster_access_role_arn":{"sensitive":false,"value":"arn:aws:iam::111122223333:role/sol-cluster-access"},"deploy_kube_context":{"sensitive":false,"value":"first-run-prod-deploy"},"deploy_kubeconfig_command":{"sensitive":false,"value":"aws eks update-kubeconfig --region us-east-1 --name first-run-prod --alias first-run-prod-deploy --role-arn arn:aws:iam::111122223333:role/sol-deploy"},"kubeconfig_command":{"sensitive":false,"value":"aws eks update-kubeconfig --region us-east-1 --name first-run-prod"},"kube_context":{"sensitive":false,"value":"first-run-prod"},"cert_manager_irsa_arn":{"sensitive":false,"value":"arn:aws:iam::111122223333:role/cert-manager"},"managed_resource_dashboards":{"sensitive":false,"value":{}},"database_egress_cidrs":{"sensitive":false,"value":[]}}' \
  >"$tmp/cluster-outputs.json"

run_with() {
  local target="$1" path="$2"
  shift 2
  rm -rf "$tmp/data/sol/runs"
  rm -f "$tmp/terraform.log" "$tmp/aws.log"
  set +e
  output="$(
    cd "$tmp/work" &&
      XDG_DATA_HOME="$tmp/data" PATH="$path" POSTGRES_URL=postgresql://user:pass@localhost:5432/db \
        "$sol" deploy "$target" --image-tag deadbeef --registry registry.example.test/first "$@" 2>&1 </dev/null
  )"
  rc=$?
  set -e
}

run() {
  local path="$1"
  shift
  run_with prod/aws/us-east-1 "$path" "$@"
}

run_interactive_with() {
  local path="$1" answer="$2"
  shift 2
  rm -rf "$tmp/data/sol/runs"
  rm -f "$tmp/terraform.log" "$tmp/aws.log" "$tmp/applied"
  local command
  command="cd '$tmp/work' && XDG_DATA_HOME='$tmp/data' PATH='$path' POSTGRES_URL=postgresql://user:pass@localhost:5432/db SOL_API_KEY=first-run-key '$sol' deploy prod/aws/us-east-1 --image-tag deadbeef --registry registry.example.test/first $*"
  set +e
  output="$(printf '%s\n' "$answer" | script -qec "$command" /dev/null 2>&1 | tr -d '\r')"
  rc=$?
  set -e
}

run_interactive() {
  local answer="$1"
  shift
  run_interactive_with "$tmp/bin-first:$tmp/bin-tf:/usr/bin:/bin" "$answer" "$@"
}

terraform_log() {
  cat "$tmp/terraform.log" 2>/dev/null || true
}

run "$tmp/bin-absent:/usr/bin:/bin"
check "an uninstalled account with no interactive terminal exits 1" 1 "$rc"
check_contains \
  "the report says the installation is not there" \
  "Sol is not installed for prod/aws/us-east-1" \
  "$output"
check_contains "the report names the state backend as missing" "terraform state backend" "$output"
check_contains "the report names the target's declared installation" "state bucket" "$output"
check_contains \
  "the report separates Sol's automated work" \
  "Sol does this for you:" \
  "$output"
check_contains \
  "the report separates the external action" \
  "One action may be required from you:" \
  "$output"
check_contains \
  "the refusal names the command that establishes the installation" \
  "sol deploy prod/aws/us-east-1" \
  "$output"
check_absent "a non-interactive run never prompts" "[Y/n]" "$output"
check_absent "a non-interactive run changes nothing" " apply " "$(terraform_log)"
check_absent "a non-interactive run plans nothing" " plan " "$(terraform_log)"
run "$tmp/bin-absent:/usr/bin:/bin" --dry-run
check "a dry run against an uninstalled account exits 1" 1 "$rc"
check_contains \
  "a dry run explains why it will not set installation up" \
  "this run is \`--dry-run\`" \
  "$output"
check_absent "a dry run never prompts" "[Y/n]" "$output"
check_absent "a dry run changes nothing" " apply " "$(terraform_log)"

run "$tmp/bin-partial:/usr/bin:/bin"
check "a partly installed account exits 1" 1 "$rc"
check_contains \
  "a partly present installation is reported as such" \
  "Sol is only partly installed for prod/aws/us-east-1" \
  "$output"
check_contains \
  "the missing prerequisite is named" \
  "terraform state backend      Unmet" \
  "$output"
check_absent \
  "an established prerequisite is not listed as missing" \
  "provisioning identity        Unmet" \
  "$output"
check_absent "a partly installed account is not set up non-interactively" " apply " "$(terraform_log)"

run "$tmp/bin-denied:/usr/bin:/bin"
check "an unobservable installation exits 1" 1 "$rc"
check_contains \
  "a denied probe is UNKNOWN, not a missing prerequisite" \
  "UNKNOWN: An error occurred (AccessDenied)" \
  "$output"
check_contains \
  "an unobservable installation is reported neither established nor absent" \
  "reports it neither established nor absent" \
  "$output"
check_absent \
  "a denied probe is never reported as an absent prerequisite" \
  "Sol is not installed" \
  "$output"
check_contains \
  "the report says how to observe the installation" \
  "sol plan prod/aws/us-east-1" \
  "$output"
check_absent "an unobservable installation is not set up" " apply " "$(terraform_log)"

run "$tmp/bin-unresolvable:$tmp/bin-denied:/usr/bin:/bin"
check "a denied provider beside a decisive observation exits 1" 1 "$rc"
check_contains \
  "the one prerequisite the provider did not answer for stays UNKNOWN" \
  "UNKNOWN: An error occurred (AccessDenied)" \
  "$output"
check_contains \
  "a delegation that does not resolve is decisive even beside seven UNKNOWNs" \
  "Sol is not installed for prod/aws/us-east-1" \
  "$output"
check_absent "the refused run is not set up" " apply " "$(terraform_log)"

run "$tmp/bin-installed:$tmp/bin-tf:/usr/bin:/bin"
check "an installed account with no environment exits 1" 1 "$rc"
check_contains \
  "an established installation is reported observed" \
  "every durable prerequisite is established" \
  "$output"
check_contains \
  "the environment stage is named as Sol's own work" \
  "Reconciling the whole target prod/aws/us-east-1" \
  "$output"
check_contains \
  "the run provisions the environment rather than naming a separate command" \
  "cloud/aws/cluster" \
  "$(terraform_log)"
check_contains \
  "and applies it" \
  " apply " \
  "$(terraform_log)"
check_absent "an installed account is not prompted" "[Y/n]" "$output"
check_absent \
  "an installed account repeats no installation work" \
  "aws-bootstrap" \
  "$(terraform_log)"

: >"$tmp/fresh-state"
run "$tmp/bin-installed:$tmp/bin-tf:/usr/bin:/bin"
check_absent \
  "an environment with no state file yet is not reported as an unreadable one" \
  "terraform state list failed" \
  "$output"
check_contains \
  "a never-applied environment is provisioned anyway" \
  " apply " \
  "$(terraform_log)"
rm -f "$tmp/fresh-state"

: >"$tmp/unreadable-state"
run "$tmp/bin-installed:$tmp/bin-tf:/usr/bin:/bin"
check "a state that cannot be read at all still fails closed" 1 "$rc"
check_contains \
  "and the run names the read that failed" \
  "terraform state list failed" \
  "$output"
check_absent \
  "a genuinely unreadable state does not provision" \
  " apply " \
  "$(terraform_log)"
rm -f "$tmp/unreadable-state"

run_with stale/aws/us-east-1 "$tmp/bin-installed:$tmp/bin-tf:$tmp/bin-kubectl:/usr/bin:/bin" --confirm-group-change
check "a target whose cluster is unreachable exits 1" 1 "$rc"
check_contains \
  "an unreachable cluster observes the installation" \
  "every durable prerequisite is established" \
  "$output"
check_contains \
  "the environment stage is named for the unreachable target" \
  "Reconciling the whole target stale/aws/us-east-1" \
  "$output"
check_absent "an installed account is not prompted for its unreachable cluster" "[Y/n]" "$output"
check_contains \
  "whole-target deploy plans the unreachable cluster's infrastructure root" \
  " plan " \
  "$(terraform_log)"
check_contains \
  "whole-target deploy reconciles the unreachable cluster's infrastructure root" \
  " apply " \
  "$(terraform_log)"

if ! command -v script >/dev/null 2>&1; then
  echo "test_deploy_first_run: 'script' is unavailable, so the interactive paths cannot be driven" >&2
  fail=1
else
  run_interactive "y" --await-delegation=5
  check "accepting the setup runs on into the environment stage" 1 "$rc"
  check_contains \
    "Sol offers to set the installation up" \
    "Set up Sol for prod/aws/us-east-1 now? [Y/n]" \
    "$output"
  check_contains \
    "the accepted setup reconciles the durable root" \
    " apply " \
    "$(terraform_log)"
  check_contains \
    "the accepted setup initializes the durable root's own state" \
    "aws-bootstrap" \
    "$(terraform_log)"
  check_contains \
    "the accepted setup writes the durable root's identity policy contract" \
    '"Sid": "sol-provisioner"' \
    "$(cat "$(find "$tmp/data" -name 'provisioner_policy_json.json' -print -quit)" 2>/dev/null)"
  check_contains \
    "the setup prints the one external action" \
    "the zone that publishes prod.example.test is in this account" \
    "$output"
  check_contains \
    "the setup reports the installation established" \
    "The installation for prod/aws/us-east-1 is established" \
    "$output"
  check_contains \
    "the setup re-observes rather than assuming" \
    "every durable prerequisite is established" \
    "$output"
  check_contains \
    "the run continues into the environment stage" \
    "Reconciling the whole target prod/aws/us-east-1" \
    "$output"
  check_contains \
    "and provisions the environment's cluster root" \
    "cloud/aws/cluster" \
    "$(terraform_log)"


  run_interactive_with "$tmp/bin-stuck:$tmp/bin-tf:/usr/bin:/bin" "y" --await-delegation=5
  check "a setup that does not establish the installation exits 1" 1 "$rc"
  check_contains \
    "the run says the installation is still not established" \
    "is still not established after reconciling the durable root" \
    "$output"
  check_contains \
    "the run names what it could not establish" \
    "terraform state backend" \
    "$output"

  run_interactive "n" --await-delegation=5
  check "declining the setup exits 1" 1 "$rc"
  check_contains \
    "declining is reported" \
    "you chose not to set it up" \
    "$output"
  check_absent "declining does not set the installation up" " apply " "$(terraform_log)"
fi

exit "$fail"
