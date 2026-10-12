#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
export TMP
export ATTEMPT="${ATTEMPT:-aws-self-test}"
# The workspace whose repositories the target declares; it matches the "pluto"
# image path the harness publishes under.
export WORKSPACE_NAME=pluto
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  [OK]   %s\n' "$1"; pass=$((pass + 1)); }
no() {
  printf '  [FAIL] %s\n           expected: %s\n           actual:   %s\n' "$1" "$2" "$3"
  fail=$((fail + 1))
}
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else no "$1" "contains: $2" "$(tr '\n' '|' <"$3" 2>/dev/null | cut -c1-200)"; fi; }
lacks() { if grep -qF -- "$2" "$3" 2>/dev/null; then no "$1" "absent: $2" "present"; else ok "$1"; fi; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$3" "$2"; fi; }
exists() { if [ -f "$2" ]; then ok "$1"; else no "$1" "file exists: $2" "missing"; fi; }
refused() { if [ "$(cat "$TMP/$1.rc" 2>/dev/null)" != "0" ]; then ok "$2"; else no "$2" "non-zero" "0"; fi; }

ROOT="$TMP/root"
WORKSPACE="$TMP/workspace"
INSTALL="$TMP/install"
VERSION="v0.1.0-alpha.7"
DIGEST64="$(printf 'a%.0s' $(seq 1 64))"
RUNNER="ghcr.io/example/sol-migration-runner:$VERSION@sha256:$DIGEST64"
NO_RUNNER_INSTALL="$TMP/install-no-runner"
TAG_RUNNER_INSTALL="$TMP/install-tag-runner"
NO_REVISION_INSTALL="$TMP/install-no-revision"

mkdir -p "$ROOT/internal/qualification/aws" "$ROOT/internal/qualification/transport" \
  "$WORKSPACE/sol" "$TMP/bin"
cp "$REPO/internal/qualification/aws/live-row.sh" "$ROOT/internal/qualification/aws/"
cp "$REPO/internal/qualification/aws/absence.py" "$ROOT/internal/qualification/aws/"
cp "$REPO/internal/qualification/sol-under-test.sh" "$ROOT/internal/qualification/"
cp "$REPO/internal/qualification/candidate-binding.sh" "$ROOT/internal/qualification/"
cp "$REPO/internal/qualification/attempt.sh" "$ROOT/internal/qualification/"

bundle() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/share/sol/$VERSION/platform/shared" \
    "$dir/share/sol/$VERSION/platform/cloud/aws/bootstrap"
  printf '{\n  "components": {}\n}\n' >"$dir/share/sol/$VERSION/platform/shared/components.json"
  cat >"$dir/bin/sol" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' "${STUB_SOL_VERSION:-v0.1.0-alpha.7}"
  exit 0
fi
printf 'sol %s [runner=%s] [home=%s]\n' "$*" "${SOL_MIGRATION_RUNNER_IMAGE:-unset}" "${SOL_HOME:-unset}" >>"$SOL_LOG"
# A cold target has no reachable release to inherit workload images from; the real `sol plan`
# refuses, and the harness records the skip and continues (issue #1408).
if [ "${1:-}" = "plan" ]; then
  if [ "${STUB_COLD_PLAN:-0}" = "1" ]; then
    printf 'error: cannot inherit workload images from the current release (exited with code 1: error: context "sol-qual-aws-2b-deploy" does not exist); supply --image-ref for every workload\n'
    exit 1
  fi
  exit 0
fi
# The whole-target deploy reconciles the durable installation inline, so an installation
# that cannot be established and a first deploy that reaches the substrate both surface
# here. A fresh account's installation offer is interactive in the real command; the stub
# accepts it and reports the reconciled environment `sol deploy` prints before workloads.
if [ "${1:-}" = "deploy" ]; then
  if [ "${STUB_INSTALL_REFUSED:-0}" = "1" ]; then
    printf 'the durable installation for %s could not be established with positive evidence\n' "${2:-}"
    exit 1
  fi
  printf 'lifecycle phase: CloudBootstrap\n'
  if [ -n "${STUB_SOL_SLEEP:-}" ]; then sleep "$STUB_SOL_SLEEP"; fi
  if [ "${STUB_APPLY_CREDENTIAL_MISSING:-0}" = "1" ] \
    && [ ! -f "${TMP:-/tmp}/credential-supplied" ]; then
    printf 'the platform install cannot start: the operator-supplied Secret redpanda-users is absent from namespace redpanda.\n'
    printf 'Resolve that, then re-run the whole-target deploy to resume the install.\n'
    exit 1
  fi
  printf 'The environment for %s is reconciled.\n' "${2:-}"
  exit 0
fi
if [ -n "${STUB_SOL_SLEEP:-}" ]; then sleep "$STUB_SOL_SLEEP"; fi
exit 0
STUB
  chmod +x "$dir/bin/sol"
}

bundle "$INSTALL"
printf '%s\n' "$RUNNER" >"$INSTALL/share/sol/$VERSION/migration-runner-image"

bundle "$NO_RUNNER_INSTALL"

bundle "$TAG_RUNNER_INSTALL"
printf 'ghcr.io/example/sol-migration-runner:%s\n' "$VERSION" >"$TAG_RUNNER_INSTALL/share/sol/$VERSION/migration-runner-image"

# A release that names a runner but no source revision: the run cannot bind the
# application it builds to the candidate, so it must refuse rather than qualify
# whatever the checkout happens to hold.
bundle "$NO_REVISION_INSTALL"
printf '%s\n' "$RUNNER" >"$NO_REVISION_INSTALL/share/sol/$VERSION/migration-runner-image"

cat >"$ROOT/internal/qualification/aws/app-transaction.sh" <<'STUB'
#!/usr/bin/env bash
printf 'health: ok\ncharge: ch_qual01\nnotification: ch_qual01\nthe worker consumed the charge\n' \
  >"$1/app-transaction.txt"
exit 0
STUB
chmod +x "$ROOT/internal/qualification/aws/app-transaction.sh"

cat >"$ROOT/internal/qualification/aws/transport-transaction.sh" <<'STUB'
#!/usr/bin/env bash
printf 'KUBECONFIG_TRANSPORT=%s APP_NS=%s APP_SERVICE=%s SCENARIO=%s\n' \
  "${KUBECONFIG_TRANSPORT:-unset}" "${APP_NS:-unset}" "${APP_SERVICE:-unset}" "${SCENARIO:-unset}" \
  >>"$TRANSPORT_LOG"
printf 'health: ok\norder: ord_qual01\nread-back: the worker effect is visible to the service\n'
exit 0
STUB
chmod +x "$ROOT/internal/qualification/aws/transport-transaction.sh"

cat >"$ROOT/internal/qualification/transport/establish.sh" <<'STUB'
#!/usr/bin/env bash
printf 'establish %s\n' "$*" >>"$ESTABLISH_LOG"
if [ -n "${STUB_ESTABLISH_FAILS:-}" ]; then printf 'establish: refused\n' >&2; exit 1; fi
[ -n "${KUBECONFIG:-}" ] && : >"$KUBECONFIG"
exit 0
STUB
chmod +x "$ROOT/internal/qualification/transport/establish.sh"

printf 'project: scratch\n' >"$WORKSPACE/sol.yml"
# The app phase publishes every selected unit, so the workspace must carry a
# Dockerfile for each (the docker stub answers the build and push).
mkdir -p "$WORKSPACE/app/checkout/checkout_svc" "$WORKSPACE/app/payments/charge_svc" \
  "$WORKSPACE/app/comms/notify_worker" "$WORKSPACE/app/payments/orders_svc" \
  "$WORKSPACE/app/comms/fulfilment_worker"
for unit in checkout_svc charge_svc notify_worker orders_svc fulfilment_worker; do
  dir="$(find "$WORKSPACE/app" -maxdepth 2 -type d -name "$unit")"
  printf 'FROM scratch\n' >"$dir/Dockerfile"
done
cat >"$WORKSPACE/sol/environments.local.yml" <<'YAML'
qualreg:
  targets:
    aws/us-east-1:
      cluster_name: test-cluster
      state_bucket: sol-qual-test-tfstate
      # `sol deploy` takes no --var-file; the row's roots read this file.
      terraform_var_file: /tmp/qual-aws-row.tfvars
YAML

# The workspace is the candidate's tree, and every bundle names it: a live run
# builds the application it qualifies from this revision and no other.
cat >"$WORKSPACE/pluto.opam" <<'OPAM'
opam-version: "2.0"
pin-depends: [
  [ "sol-svc.dev"           "git+https://github.com/sol-fab/sol.git#main" ]
  [ "kafka-eio-service.dev" "git+https://github.com/sol-fab/sol.git#main" ]
]
OPAM
git -C "$WORKSPACE" init -q
git -C "$WORKSPACE" add -A
git -c user.name=qualification -c user.email=qualification@example.invalid \
  -C "$WORKSPACE" commit -qm "the candidate revision"
CANDIDATE_REVISION="$(git -C "$WORKSPACE" rev-parse HEAD)"

for install in "$INSTALL" "$NO_RUNNER_INSTALL" "$TAG_RUNNER_INSTALL"; do
  printf '%s\n' "$CANDIDATE_REVISION" >"$install/share/sol/$VERSION/REVISION"
done

# The candidate document each install prefix belongs to. A release prefix alone
# cannot say which candidate it holds, so the run is told and verifies it
# (sol-fab/sol#1287).
candidate_document() {
  local install="$1" version="$2" revision="$3" runner="$4" out="$5"
  printf '{"version":"%s","revision":"%s","runner_image":"%s"}\n' \
    "$version" "$revision" "$runner" >"$out"
}
for install in "$INSTALL" "$NO_RUNNER_INSTALL" "$TAG_RUNNER_INSTALL"; do
  candidate_document "$install" "$VERSION" "$CANDIDATE_REVISION" "$RUNNER" "$install/candidate.json"
done
# A candidate document that names a different revision: the run must refuse it
# rather than qualify the prefix under a name it does not belong to.
candidate_document "$INSTALL" "$VERSION" "0000000000000000000000000000000000000000" "$RUNNER" \
  "$TMP/candidate-other-revision.json"
# And one that names a different version.
candidate_document "$INSTALL" "v0.1.0-alpha.6" "$CANDIDATE_REVISION" "$RUNNER" \
  "$TMP/candidate-other-version.json"

ECR="123456789012.dkr.ecr.us-east-1.amazonaws.com"

cat >"$TMP/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >>"$AWS_LOG"
class_read() {
  case "$1 $2" in
    "eks list-clusters" | "rds describe-db-instances" | "rds describe-db-subnet-groups" | \
      "rds describe-db-snapshots" | "ec2 describe-instances" | "ec2 describe-vpcs" | \
      "ec2 describe-nat-gateways" | "ec2 describe-addresses" | "ec2 describe-volumes" | \
      "elbv2 describe-load-balancers" | "elbv2 describe-tags" | "ecr describe-repositories" | \
      "iam list-roles" | "iam list-policies" | "s3api list-buckets" | \
      "cloudwatch list-dashboards" | "logs describe-log-groups")
      return 0
      ;;
    *) return 1 ;;
  esac
}
if [ "${STUB_INVENTORY_UNREADABLE:-0}" = "1" ] && class_read "$1" "$2"; then
  printf 'Unable to locate credentials\n' >&2
  exit 255
fi
case "$1 $2" in
  "sts get-caller-identity")
    case " $* " in
      *"--output json"*) printf '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/qualifier"}\n' ;;
      *) printf '123456789012\n' ;;
    esac
    ;;
  "s3api head-object")
    if [ "${STUB_STATE_PRESENT:-0}" = "1" ]; then exit 0; fi
    printf 'An error occurred (404) when calling the HeadObject operation: Not Found\n' >&2
    exit 1
    ;;
  "s3 cp")
    dest="${@: -1}"
    mkdir -p "$(dirname "$dest")"
    printf '{"outputs":{"postgres_url":{"value":"postgres://user:qual-secret@db.example.test:5432/pluto"}}}\n' >"$dest"
    ;;
  "eks list-clusters")
    if [ "${STUB_LIVE_EKS:-0}" = "1" ]; then printf '{"clusters":["test-cluster"]}\n'; else printf '{"clusters":[]}\n'; fi
    ;;
  "rds describe-db-instances")
    if [ "${STUB_MALFORMED_RDS:-0}" = "1" ]; then
      printf '{"DBInstances":{}}\n'
    elif [ "${STUB_LIVE_RDS:-0}" = "1" ]; then
      printf '{"DBInstances":[{"DBInstanceIdentifier":"test-cluster-postgres"}]}\n'
    else
      printf '{"DBInstances":[]}\n'
    fi
    ;;
  "rds describe-db-snapshots")
    if [ "${STUB_LIVE_RDS_SNAPSHOT:-0}" = "1" ]; then
      printf '{"DBSnapshots":[{"DBSnapshotIdentifier":"test-cluster-postgres-final"}]}\n'
    else
      printf '{"DBSnapshots":[]}\n'
    fi
    ;;
  "ec2 describe-instances")
    if [ "${STUB_LIVE_INSTANCE:-0}" = "1" ]; then
      printf '{"Reservations":[{"Instances":[{"InstanceId":"i-live","State":{"Name":"running"},"Tags":[{"Key":"kubernetes.io/cluster/test-cluster","Value":"owned"}]}]}]}\n'
    elif [ "${STUB_TERMINATED_INSTANCE:-0}" = "1" ]; then
      printf '{"Reservations":[{"Instances":[{"InstanceId":"i-dead","State":{"Name":"terminated"},"Tags":[{"Key":"kubernetes.io/cluster/test-cluster","Value":"owned"}]}]}]}\n'
    elif [ "${STUB_FOREIGN_INSTANCE:-0}" = "1" ]; then
      printf '{"Reservations":[{"Instances":[{"InstanceId":"i-other","State":{"Name":"running"},"Tags":[{"Key":"kubernetes.io/cluster/another-cluster","Value":"owned"}]}]}]}\n'
    else
      printf '{"Reservations":[]}\n'
    fi
    ;;
  "ec2 describe-vpcs")
    if [ "${STUB_LIVE_VPC:-0}" = "1" ]; then
      printf '{"Vpcs":[{"VpcId":"vpc-live","Tags":[{"Key":"kubernetes.io/cluster/test-cluster","Value":"owned"}]}]}\n'
    else
      printf '{"Vpcs":[]}\n'
    fi
    ;;
  "ec2 describe-nat-gateways")
    if [ "${STUB_LIVE_NAT:-0}" = "1" ]; then
      printf '{"NatGateways":[{"NatGatewayId":"nat-live","State":"available","Tags":[{"Key":"kubernetes.io/cluster/test-cluster","Value":"owned"}]}]}\n'
    elif [ "${STUB_DELETED_NAT:-0}" = "1" ]; then
      printf '{"NatGateways":[{"NatGatewayId":"nat-dead","State":"deleted","Tags":[{"Key":"kubernetes.io/cluster/test-cluster","Value":"owned"}]}]}\n'
    else
      printf '{"NatGateways":[]}\n'
    fi
    ;;
  "ec2 describe-addresses")
    if [ "${STUB_LIVE_EIP:-0}" = "1" ]; then
      printf '{"Addresses":[{"PublicIp":"198.51.100.5","Tags":[{"Key":"kubernetes.io/cluster/test-cluster","Value":"owned"}]}]}\n'
    else
      printf '{"Addresses":[]}\n'
    fi
    ;;
  "ec2 describe-volumes")
    if [ "${STUB_LIVE_VOLUME:-0}" = "1" ]; then
      printf '{"Volumes":[{"VolumeId":"vol-live","State":"available","Tags":[{"Key":"kubernetes.io/cluster/test-cluster","Value":"owned"}]}]}\n'
    else
      printf '{"Volumes":[]}\n'
    fi
    ;;
  "elbv2 describe-load-balancers")
    if [ "${STUB_LIVE_LB:-0}" = "1" ]; then
      printf '{"LoadBalancers":[{"LoadBalancerArn":"arn:aws:elbv2:us-east-1:123456789012:loadbalancer/app/k8s-live/1","LoadBalancerName":"k8s-live"}]}\n'
    else
      printf '{"LoadBalancers":[]}\n'
    fi
    ;;
  "elbv2 describe-tags")
    printf '{"TagDescriptions":[{"ResourceArn":"arn:aws:elbv2:us-east-1:123456789012:loadbalancer/app/k8s-live/1","Tags":[{"Key":"kubernetes.io/cluster/test-cluster","Value":"owned"}]}]}\n'
    ;;
  "ecr describe-repositories")
    if [ "${STUB_LIVE_ECR:-0}" = "1" ]; then
      printf '{"repositories":[{"repositoryName":"pluto/charge-svc"}]}\n'
    else
      printf '{"repositories":[]}\n'
    fi
    ;;
  "rds describe-db-subnet-groups")
    if [ "${STUB_LIVE_RDS_SUBNET_GROUP:-0}" = "1" ]; then
      printf '{"DBSubnetGroups":[{"DBSubnetGroupName":"test-cluster-postgres"}]}\n'
    else
      printf '{"DBSubnetGroups":[]}\n'
    fi
    ;;
  "iam list-roles")
    if [ "${STUB_LIVE_IAM_ROLE:-0}" = "1" ]; then
      printf '{"Roles":[{"RoleName":"test-cluster-ebs-csi"}]}\n'
    else
      printf '{"Roles":[]}\n'
    fi
    ;;
  "iam list-policies")
    printf '{"Policies":[]}\n'
    ;;
  "s3api list-buckets")
    if [ "${STUB_LIVE_S3_BUCKET:-0}" = "1" ]; then
      printf '{"Buckets":[{"Name":"test-cluster-loki-logs"}]}\n'
    else
      printf '{"Buckets":[]}\n'
    fi
    ;;
  "cloudwatch list-dashboards")
    if [ "${STUB_LIVE_DASHBOARD:-0}" = "1" ]; then
      printf '{"DashboardEntries":[{"DashboardName":"test-cluster-postgres"}]}\n'
    else
      printf '{"DashboardEntries":[]}\n'
    fi
    ;;
  "logs describe-log-groups")
    if [ "${STUB_LIVE_LOG_GROUP:-0}" = "1" ]; then
      printf '{"logGroups":[{"logGroupName":"/aws/eks/test-cluster/cluster"}]}\n'
    else
      printf '{"logGroups":[]}\n'
    fi
    ;;
  "route53 list-hosted-zones")
    printf '{"HostedZones":[{"Name":"qual-aws.sol-fab.dev.","Id":"/hostedzone/Z123"}]}\n'
    ;;
  "eks describe-cluster")
    case " $* " in
      *" cluster.endpoint "*) printf '%s\n' "${STUB_CLUSTER_ENDPOINT:-https://10.0.0.1}" ;;
    esac
    ;;
  "eks update-kubeconfig")
    if [ -n "${KUBECONFIG:-}" ]; then
      if [ "${STUB_KUBECONFIG_STALE:-0}" = "1" ]; then
        printf 'apiVersion: v1\nclusters:\n- cluster:\n    server: https://9.9.9.9\n  name: c\n' >"$KUBECONFIG"
      else
        printf 'apiVersion: v1\nclusters:\n- cluster:\n    server: %s\n  name: c\n' \
          "${STUB_CLUSTER_ENDPOINT:-https://10.0.0.1}" >"$KUBECONFIG"
      fi
    fi
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/aws"

cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$KUBECTL_LOG"
case " $* " in
  *" create secret generic "*)
    if [ "${STUB_SECRET_CREATE_FAILS:-0}" = "1" ]; then
      printf 'Error from server (Forbidden): secrets "redpanda-users" is forbidden\n' >&2
      exit 1
    fi
    : >"${TMP:-/tmp}/credential-supplied"
    printf 'secret/redpanda-users created\n'
    exit 0
    ;;
  *" get secret redpanda-users "*)
    printf '%s' 'sol-workloads:testpass:SCRAM-SHA-256' | base64
    exit 0
    ;;
  *" get secret redpanda-default-cert "*)
    printf '%s' 'ca-certificate-for-tests' | base64
    exit 0
    ;;
  # 2b: the deploy delivers the database as class Secrets. The row lists them across
  # namespaces and checks the consumer's own Secret for the master copy it no longer
  # carries.
  *" get secret -A "*)
    printf '%s\n' \
      "${STUB_DML_NAMESPACE:-pluto-payments} ${STUB_CLASS_PREFIX:-qualreg-aws-us-east-1}-dml-creds" \
      "${STUB_DDL_NAMESPACE:-pluto-comms} ${STUB_CLASS_PREFIX:-qualreg-aws-us-east-1}-ddl-creds"
    exit 0
    ;;
  *" get secret charge-svc-secrets "*)
    exit 0
    ;;
  *" config view "*)
    kubeconfig="${KUBECONFIG:-}"
    while [ $# -gt 0 ]; do
      case "$1" in
        --kubeconfig)
          kubeconfig="$2"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    grep -m1 'server:' "$kubeconfig" 2>/dev/null | awk '{print $2}'
    exit 0
    ;;
  *" port-forward "*)
    if [ -n "${STUB_PF_NO_PORT:-}" ]; then
      sleep 5
      exit 0
    fi
    printf 'Forwarding from 127.0.0.1:54321 -> 80\n'
    while true; do sleep 1; done
    ;;
  *" auth whoami "*)
    case " $* " in
      *kubeconfig-qualifier.yaml*)
        printf '{"status":{"userInfo":{"username":"arn:aws:sts::123456789012:assumed-role/%s/session","groups":["sol:qualifiers"]}}}\n' \
          "${STUB_QUALIFIER_ROLE:-qualifier}"
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  *" auth can-i create pods --subresource=portforward "*)
    case " $* " in
      *kubeconfig-access.yaml*) printf '%s\n' "${STUB_ACCESS_FORWARD:-no}" ;;
      *kubeconfig-deploy.yaml*) printf '%s\n' "${STUB_DEPLOY_FORWARD:-no}" ;;
      *kubeconfig-operator.yaml*) printf '%s\n' "${STUB_OPERATOR_FORWARD:-no}" ;;
      *kubeconfig-qualifier.yaml*) printf '%s\n' "${STUB_QUALIFIER_FORWARD:-yes}" ;;
      *) printf 'no\n' ;;
    esac
    exit 0
    ;;
  *" auth can-i "*)
    case " $* " in
      *kubeconfig-access.yaml*) exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/kubectl"

cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$CURL_LOG"
case "$*" in
  *"/healthz"*) printf 'ok\n' ;;
  *"-X POST"*"/charges"*) printf '{"id":"ch_qual01"}\n' ;;
  *"/notifications"*) printf '[{"charge_id":"ch_qual01"}]\n' ;;
  *"-X POST"*"/orders"*)
    body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -d)
          body="$2"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    id="$(printf '%s' "$body" | sed -n 's/.*"order_id":"\([^"]*\)".*/\1/p')"
    printf '{"order_id":"%s","status":"accepted"}\n' "$id"
    ;;
  *"/orders/"*)
    url="${!#}"
    id="${url##*/}"
    if [ "${STUB_ORDER_STATUS:-fulfilled}" = accepted ]; then
      printf '{"order_id":"%s","status":"accepted"}\n' "$id"
    else
      printf '{"order_id":"%s","status":"fulfilled"}\n' "$id"
    fi
    ;;
  *) printf '{}\n' ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/curl"

cat >"$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$DOCKER_LOG"
case " $* " in
  *" inspect "*)
    ref="${!#}"
    printf '%s@sha256:%s\n' "${ref%:*}" "$(printf 'b%.0s' $(seq 1 64))"
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/docker"

cat >"$TMP/bin/terraform" <<'STUB'
#!/usr/bin/env bash
printf 'terraform %s\n' "$*" >>"$TERRAFORM_LOG"
exit 0
STUB
chmod +x "$TMP/bin/terraform"

run_row() {
  local name="$1"
  shift
  export AWS_LOG="$TMP/$name.aws"
  export KUBECTL_LOG="$TMP/$name.kubectl"
  export DOCKER_LOG="$TMP/$name.docker"
  export SOL_LOG="$TMP/$name.sol"
  export TRANSPORT_LOG="$TMP/$name.transport"
  export ESTABLISH_LOG="$TMP/$name.establish"
  export TERRAFORM_LOG="$TMP/$name.terraform"
  export LOG_DIR="$TMP/$name.logs"
  : >"$AWS_LOG"
  : >"$KUBECTL_LOG"
  : >"$DOCKER_LOG"
  : >"$SOL_LOG"
  : >"$TRANSPORT_LOG"
  : >"$ESTABLISH_LOG"
  : >"$TERRAFORM_LOG"
  rm -rf "$LOG_DIR"
  env PATH="$TMP/bin:$PATH" \
    WORKSPACE="$WORKSPACE" TARGET=qualreg/aws/us-east-1 ECR_REGISTRY="$ECR" \
    CLUSTER=test-cluster DEPLOY_ROLE_ARN=arn:aws:iam::1:role/deploy \
    CLUSTER_ACCESS_ROLE_ARN=arn:aws:iam::1:role/access \
    SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" PHASE_TIMEOUT=60 "$@" \
    "$ROOT/internal/qualification/aws/live-row.sh" app >"$TMP/$name.out" 2>&1
  echo "$?" >"$TMP/$name.rc"
}

run_phase() {
  local name="$1" phase="$2"
  shift 2
  export AWS_LOG="$TMP/$name.aws"
  export KUBECTL_LOG="$TMP/$name.kubectl"
  export DOCKER_LOG="$TMP/$name.docker"
  export SOL_LOG="$TMP/$name.sol"
  export TRANSPORT_LOG="$TMP/$name.transport"
  export ESTABLISH_LOG="$TMP/$name.establish"
  export TERRAFORM_LOG="$TMP/$name.terraform"
  export LOG_DIR="$TMP/$name.logs"
  : >"$AWS_LOG"
  : >"$KUBECTL_LOG"
  : >"$DOCKER_LOG"
  : >"$SOL_LOG"
  : >"$TRANSPORT_LOG"
  : >"$ESTABLISH_LOG"
  : >"$TERRAFORM_LOG"
  rm -rf "$LOG_DIR"
  rm -f "$TMP/credential-supplied"
  if [ -n "${PRESEED_FOREIGN_ATTEMPT:-}" ]; then
    mkdir -p "$LOG_DIR"
    printf 'attempt=%s\n' "$PRESEED_FOREIGN_ATTEMPT" >"$LOG_DIR/attempt.txt"
  fi
  env PATH="$TMP/bin:$PATH" \
    WORKSPACE="$WORKSPACE" TARGET=qualreg/aws/us-east-1 ECR_REGISTRY="$ECR" \
    CLUSTER=test-cluster DEPLOY_ROLE_ARN=arn:aws:iam::1:role/deploy \
    CLUSTER_ACCESS_ROLE_ARN=arn:aws:iam::1:role/access \
    OPERATOR_ROLE_ARN=arn:aws:iam::1:role/operator QUALIFIER_ROLE=qualifier \
    SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" PHASE_TIMEOUT=60 "$@" \
    "$ROOT/internal/qualification/aws/live-row.sh" "$phase" >"$TMP/$name.out" 2>&1
  echo "$?" >"$TMP/$name.rc"
}

run_phase_closed_stdout() {
  local name="$1" phase="$2"
  shift 2
  export AWS_LOG="$TMP/$name.aws"
  export KUBECTL_LOG="$TMP/$name.kubectl"
  export DOCKER_LOG="$TMP/$name.docker"
  export SOL_LOG="$TMP/$name.sol"
  export TRANSPORT_LOG="$TMP/$name.transport"
  export ESTABLISH_LOG="$TMP/$name.establish"
  export TERRAFORM_LOG="$TMP/$name.terraform"
  export LOG_DIR="$TMP/$name.logs"
  : >"$AWS_LOG"
  : >"$KUBECTL_LOG"
  : >"$DOCKER_LOG"
  : >"$SOL_LOG"
  : >"$TRANSPORT_LOG"
  : >"$ESTABLISH_LOG"
  : >"$TERRAFORM_LOG"
  rm -rf "$LOG_DIR"
  env PATH="$TMP/bin:$PATH" \
    WORKSPACE="$WORKSPACE" TARGET=qualreg/aws/us-east-1 ECR_REGISTRY="$ECR" \
    CLUSTER=test-cluster DEPLOY_ROLE_ARN=arn:aws:iam::1:role/deploy \
    CLUSTER_ACCESS_ROLE_ARN=arn:aws:iam::1:role/access \
    OPERATOR_ROLE_ARN=arn:aws:iam::1:role/operator QUALIFIER_ROLE=qualifier \
    SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" PHASE_TIMEOUT=60 "$@" \
    "$ROOT/internal/qualification/aws/live-row.sh" "$phase" 2>"$TMP/$name.err" | true
  local -a codes=("${PIPESTATUS[@]}")
  printf '%s\n' "${codes[0]}" >"$TMP/$name.rc"
}

run_phase_sigterm() {
  local name="$1" signal="$2" phase="$3"
  shift 3
  export AWS_LOG="$TMP/$name.aws"
  export KUBECTL_LOG="$TMP/$name.kubectl"
  export DOCKER_LOG="$TMP/$name.docker"
  export SOL_LOG="$TMP/$name.sol"
  export TRANSPORT_LOG="$TMP/$name.transport"
  export ESTABLISH_LOG="$TMP/$name.establish"
  export TERRAFORM_LOG="$TMP/$name.terraform"
  export LOG_DIR="$TMP/$name.logs"
  : >"$AWS_LOG"
  : >"$KUBECTL_LOG"
  : >"$DOCKER_LOG"
  : >"$SOL_LOG"
  : >"$TRANSPORT_LOG"
  : >"$ESTABLISH_LOG"
  : >"$TERRAFORM_LOG"
  rm -rf "$LOG_DIR"
  env PATH="$TMP/bin:$PATH" \
    WORKSPACE="$WORKSPACE" TARGET=qualreg/aws/us-east-1 ECR_REGISTRY="$ECR" \
    CLUSTER=test-cluster DEPLOY_ROLE_ARN=arn:aws:iam::1:role/deploy \
    CLUSTER_ACCESS_ROLE_ARN=arn:aws:iam::1:role/access \
    OPERATOR_ROLE_ARN=arn:aws:iam::1:role/operator QUALIFIER_ROLE=qualifier \
    SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" PHASE_TIMEOUT=60 "$@" \
    "$ROOT/internal/qualification/aws/live-row.sh" "$phase" >"$TMP/$name.out" 2>&1 &
  local harness_pid=$! waited=0
  while [ ! -e "$LOG_DIR/cloud-apply.log" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -"$signal" "$harness_pid" 2>/dev/null || true
  wait "$harness_pid"
  printf '%s\n' "$?" >"$TMP/$name.rc"
}

run_transaction() {
  local name="$1" scenario="$2"
  shift 2
  export KUBECTL_LOG="$TMP/$name.kubectl"
  export CURL_LOG="$TMP/$name.curl"
  local dir="$TMP/$name.logs"
  : >"$KUBECTL_LOG"
  : >"$CURL_LOG"
  rm -rf "$dir"
  mkdir -p "$dir"
  env PATH="$TMP/bin:$PATH" \
    KUBECONFIG_TRANSPORT="$TMP/qualifier.yaml" APP_NS=pluto-payments \
    APP_SERVICE=charge-svc APP_PORT=80 SCENARIO="$scenario" \
    PF_TIMEOUT=3 READBACK_ATTEMPTS=2 READBACK_INTERVAL=1 "$@" \
    bash "$REPO/internal/qualification/aws/transport-transaction.sh" "$dir" >"$TMP/$name.out" 2>&1
  echo "$?" >"$TMP/$name.rc"
}

printf '\nscenario: installation failure stops cloud lifecycle at the supported interface\n'
run_phase bootstrap-refused cloud STUB_INSTALL_REFUSED=1
refused bootstrap-refused "an unresolved installation refuses the cloud phase"
has "the whole-target preview runs first" \
  "sol plan qualreg/aws/us-east-1 --var-file $ROOT/internal/qualification/aws/qual-aws-row.tfvars" \
  "$TMP/bootstrap-refused.sol"
has "and Sol owns durable reconciliation through the whole-target deploy" \
  "sol deploy qualreg/aws/us-east-1 --registry $ECR --image-tag row-" "$TMP/bootstrap-refused.sol"
lacks "no removed cloud subcommand is invoked" "cloud bootstrap" "$TMP/bootstrap-refused.sol"
lacks "and neither is the removed partial apply" "cloud apply" "$TMP/bootstrap-refused.sol"
[ ! -s "$TMP/bootstrap-refused.terraform" ] && ok "no direct Terraform operation runs" \
  || no "no direct Terraform operation runs" absent present

printf '\nscenario: the app phase runs the installed release bundle and hands Sol no runner\n'
run_row ok TRANSPORT=0
is "exit 0" "$(cat "$TMP/ok.rc")" "0"
has "the installed bundle is named in the transcript" \
  "sol-under-test: release $VERSION at $INSTALL" "$TMP/ok.out"
has "the application images are still built and pushed by the harness" \
  "docker push $ECR/pluto/charge-svc:row-" "$TMP/ok.docker"
lacks "but the harness publishes no migration runner" \
  "sol-migration-runner" "$TMP/ok.docker"
has "Sol applies the workspace's migrations" \
  "sol migrate apply qualreg/aws/us-east-1 [runner=unset] [home=unset]" "$TMP/ok.sol"
lacks "without being asked to publish or name a runner" \
  "migrate apply qualreg/aws/us-east-1 --registry" "$TMP/ok.sol"
has "the deploy resolves the workspace's own images from the target's registry" \
  "deploy qualreg/aws/us-east-1 --registry $ECR --image-ref checkout_svc=$ECR/pluto/checkout-svc@sha256:" "$TMP/ok.sol"
has "and pins every selected workload by digest, not a mutable tag" \
  "image-ref charge_svc=$ECR/pluto/charge-svc@sha256:" "$TMP/ok.sol"
lacks "no mutable tag is passed to a profile that requires immutable artifacts" \
  "--image-tag" "$TMP/ok.sol"
lacks "no operator POSTGRES_URL is set for the migration path" \
  "secret set POSTGRES_URL" "$TMP/ok.sol"
has "the workload API key is supplied through sol secret set" \
  "secret set SOL_API_KEY --target qualreg/aws/us-east-1 --domain payments" "$TMP/ok.sol"
has "and the Kafka credential and CA" \
  "secret set KAFKA_SSL_CA_CERT --target qualreg/aws/us-east-1 --domain comms" "$TMP/ok.sol"
lacks "no secret value is passed on a command line" \
  "testpass" "$TMP/ok.sol"
has "the supplied keys are recorded without their values" \
  "secret_values: never recorded" "$TMP/ok.logs/prerequisites.txt"
has "the deploy's class-Secret delivery is asserted, not the operator's copy" \
  "database_delivery: qualreg-aws-us-east-1-ddl-creds (migration Job), qualreg-aws-us-east-1-dml-creds@pluto-payments (unit consumer)" \
  "$TMP/ok.logs/prerequisites.txt"
has "the run identity records the bundle version" \
  "sol_version: $VERSION" "$TMP/ok.logs/sol-identity.txt"
has "and the bundle's digest-pinned migration runner" \
  "migration_runner_image: $RUNNER" "$TMP/ok.logs/sol-identity.txt"

printf '\nscenario: a dev build, a missing bundle and an unpinned runner are refused before Sol moves anything\n'
run_row dev TRANSPORT=0 STUB_SOL_VERSION=Sol-ed3f041f
refused dev "a development build is refused"
lacks "Sol is never asked to migrate" "migrate apply" "$TMP/dev.sol"
has "and the refusal names the installed-bundle rule" \
  "which is a development build" "$TMP/dev.out"

run_row missing TRANSPORT=0 SOL_INSTALL=
refused missing "a missing SOL_INSTALL is refused"
lacks "Sol is never invoked at all" "sol " "$TMP/missing.sol"
has "and the refusal says what to set" "set SOL_INSTALL" "$TMP/missing.out"

run_row norunner TRANSPORT=0 SOL_INSTALL="$NO_RUNNER_INSTALL"
refused norunner "a bundle with no runner reference is refused"
lacks "Sol is never asked to migrate" "migrate apply" "$TMP/norunner.sol"
has "and the refusal names the missing file" "records no migration runner" "$TMP/norunner.out"

run_row tagrunner TRANSPORT=0 SOL_INSTALL="$TAG_RUNNER_INSTALL"
refused tagrunner "a bundle whose runner is a tag is refused"
lacks "Sol is never invoked with it" "migrate apply" "$TMP/tagrunner.sol"
has "and the refusal names the digest boundary" "not a digest reference" "$TMP/tagrunner.out"

run_row norevision TRANSPORT=0 SOL_INSTALL="$NO_REVISION_INSTALL"
refused norevision "a bundle that names no source revision is refused"
lacks "Sol is never invoked with it" "migrate apply" "$TMP/norevision.sol"
has "and the refusal says why the run cannot bind the application" \
  "records no source revision" "$TMP/norevision.out"

printf '\nscenario: adversarial — a run cannot qualify a prefix that is not the candidate it names\n'
run_row nocandidate TRANSPORT=0 SOL_CANDIDATE=
refused nocandidate "a run that names no candidate document is refused"
has "and the refusal says an install prefix cannot name a candidate" \
  "an install prefix alone cannot say which candidate it holds" "$TMP/nocandidate.out"
lacks "nothing is provisioned" "terraform" "$TMP/nocandidate.terraform"

run_row otherrevision TRANSPORT=0 SOL_CANDIDATE="$TMP/candidate-other-revision.json"
refused otherrevision "a candidate naming another revision is refused"
has "and the refusal names both revisions" \
  "candidate $VERSION is revision 0000000000000000000000000000000000000000" "$TMP/otherrevision.out"
lacks "nothing is provisioned" "terraform" "$TMP/otherrevision.terraform"

run_row otherversion TRANSPORT=0 SOL_CANDIDATE="$TMP/candidate-other-version.json"
refused otherversion "a candidate naming another version is refused"
has "and the refusal names both versions" \
  "SOL_INSTALL holds release $VERSION but the candidate is v0.1.0-alpha.6" "$TMP/otherversion.out"
lacks "nothing is provisioned" "terraform" "$TMP/otherversion.terraform"

printf '\nscenario: the qualification transport is established and the identity split holds\n'
run_phase transport transport
is "exit 0" "$(cat "$TMP/transport.rc")" "0"
has "the transport principal is the one the harness names" \
  "establish test-cluster qualifier us-east-1 pluto-payments" "$TMP/transport.establish"
has "the qualifier's own assumed-role session is recorded" \
  "assumed-role/qualifier/" "$TMP/transport.logs/transport-whoami.json"
has "the cluster-access identity's surface is recorded before establishment" \
  "cluster-access create pods/portforward -n pluto-payments: no" \
  "$TMP/transport.logs/transport-separation-pre.txt"
has "and after it" \
  "cluster-access create pods/portforward -n pluto-payments: no" \
  "$TMP/transport.logs/transport-separation-post.txt"
has "so is the deploy identity's" \
  "deploy create pods/portforward -n pluto-payments: no" \
  "$TMP/transport.logs/transport-separation-post.txt"
has "so is the operator identity's" \
  "operator create pods/portforward -n pluto-payments: no" \
  "$TMP/transport.logs/transport-separation-post.txt"
has "and the qualifier can open the transport" \
  "qualifier create pods/portforward -n pluto-payments: yes" \
  "$TMP/transport.logs/transport-separation-post.txt"

printf '\nscenario: adversarial — a production identity that holds pods/portforward fails the transport\n'
run_phase broad transport STUB_ACCESS_FORWARD=yes
refused broad "a broad production surface fails the transport phase"
has "and the refusal names the separation" \
  "not separated from the identities under qualification" "$TMP/broad.out"
lacks "and no window is opened after the pre-probe fails" "establish " "$TMP/broad.establish"

printf '\nscenario: adversarial — an establishment that refuses stops before the qualifier is trusted\n'
run_phase estab transport STUB_ESTABLISH_FAILS=1
refused estab "a refused establishment fails the phase"
has "and the failure names the establishment log" "FAILED: transport-establish" "$TMP/estab.out"
lacks "and the qualifier identity is never accepted" "auth whoami" "$TMP/estab.kubectl"
lacks "and the run does not proceed to a transaction" "app-transaction" "$TMP/estab.out"

printf '\nscenario: adversarial — the transport cannot be established without naming its principal\n'
run_phase norole transport QUALIFIER_ROLE=
refused norole "a missing transport principal fails the phase"
has "and it names the missing input" "QUALIFIER_ROLE is not set" "$TMP/norole.out"
lacks "and no establishment is attempted" "establish " "$TMP/norole.establish"

printf '\nscenario: the app phase drives its transaction through the qualification transport\n'
run_phase apptransport app TRANSPORT=1
is "exit 0" "$(cat "$TMP/apptransport.rc")" "0"
has "the transport is established before Sol moves the workload" \
  "establish test-cluster qualifier us-east-1 pluto-payments" "$TMP/apptransport.establish"
has "and the transaction uses the qualifier's kubeconfig" \
  "KUBECONFIG_TRANSPORT=$TMP/apptransport.logs/kubeconfig-qualifier.yaml" "$TMP/apptransport.transport"
lacks "never the deploy identity's kubeconfig" \
  "KUBECONFIG_TRANSPORT=$TMP/apptransport.logs/kubeconfig-deploy.yaml" "$TMP/apptransport.transport"
exists "and the application's own logs are captured for the record" "$TMP/apptransport.logs/app-svc.log"
exists "for the worker too" "$TMP/apptransport.logs/app-worker.log"
establish_at="$(grep -n 'transport-establish' "$TMP/apptransport.out" | head -1 | cut -d: -f1)"
transaction_at="$(grep -n 'app-transaction' "$TMP/apptransport.out" | head -1 | cut -d: -f1)"
if [ -n "$establish_at" ] && [ -n "$transaction_at" ] && [ "$establish_at" -lt "$transaction_at" ]; then
  ok "and establishment precedes the transaction"
else
  no "and establishment precedes the transaction" "transport-establish before app-transaction" \
    "establish at ${establish_at:-none}, transaction at ${transaction_at:-none}"
fi

printf '\nscenario: the transport transaction reads the application effect back through a port-forward\n'
run_transaction txchar charges
is "exit 0" "$(cat "$TMP/txchar.rc")" "0"
has "the local endpoint is the port the forward resolved, not an assumed one" \
  "local endpoint: http://127.0.0.1:54321" "$TMP/txchar.logs/transport-transaction.txt"
has "the charge's worker effect is the read-back" \
  "read-back: the worker effect is visible to the service" "$TMP/txchar.logs/transport-transaction.txt"
has "the port-forward was opened as the qualifier kubeconfig" \
  "--kubeconfig $TMP/qualifier.yaml" "$TMP/txchar.kubectl"

run_transaction txord orders
is "exit 0" "$(cat "$TMP/txord.rc")" "0"
has "an order reaches fulfilled through its own read-back" \
  "read-back: the worker effect is visible to the service" "$TMP/txord.logs/transport-transaction.txt"
has "and the order id the service echoed was the submitted one" \
  "\"order_id\":\"ord-" "$TMP/txord.logs/transport-transaction.txt"

printf '\nscenario: adversarial — a worker that never writes is not read as success\n'
run_transaction txstuck orders STUB_ORDER_STATUS=accepted
refused txstuck "an order that never leaves accepted fails the transaction"
has "and the refusal names what was missing" \
  "the order never reached fulfilled or confirmed" "$TMP/txstuck.out"

printf '\nscenario: adversarial — a transport that never opens fails rather than curling nothing\n'
run_transaction txnoopen orders STUB_PF_NO_PORT=1
refused txnoopen "a port-forward with no local port fails the transaction"
has "and the refusal names the transport" \
  "the qualification transport did not open" "$TMP/txnoopen.out"

printf '\nscenario: the cloud phase previews with the row var file and deploys the whole target\n'
run_phase cloudrun cloud
is "exit 0" "$(cat "$TMP/cloudrun.rc")" "0"
has "the preview carries the row's var file" \
  "plan qualreg/aws/us-east-1 --var-file $ROOT/internal/qualification/aws/qual-aws-row.tfvars" \
  "$TMP/cloudrun.sol"
has "and the whole-target deploy reconciles the environment by tag" \
  "deploy qualreg/aws/us-east-1 --registry $ECR --image-tag row-" "$TMP/cloudrun.sol"
lacks "the removed partial cloud apply is never invoked" "cloud apply" "$TMP/cloudrun.sol"

printf '\nscenario: a cold target records the plan skip instead of failing on the missing release\n'
run_phase coldplan cloud STUB_COLD_PLAN=1
is "exit 0" "$(cat "$TMP/coldplan.rc")" "0"
has "the skip names the fresh target and the ordering follow-up" \
  "cloud-plan: skipped (fresh target: no reachable release to inherit images, no digests to supply; harness ordering follow-up: #1408)" \
  "$TMP/coldplan.logs/prerequisites.txt"
has "and the phase still deploys the whole target" \
  "deploy qualreg/aws/us-east-1 --registry $ECR --image-tag row-" "$TMP/coldplan.sol"

printf '\nscenario: the harness supplies the platform credential the install names, then resumes\n'
run_phase credential-boundary cloud STUB_APPLY_CREDENTIAL_MISSING=1
is "exit 0" "$(cat "$TMP/credential-boundary.rc")" "0"
has "the harness creates the documented Secret in the namespace the install named" \
  "create secret generic redpanda-users -n redpanda" "$TMP/credential-boundary.kubectl"
has "with the SASL user the workload renderer names" "sol-workloads:" "$TMP/credential-boundary.kubectl"
has "and the SCRAM mechanism the durable layer declares" "SCRAM-SHA-256" "$TMP/credential-boundary.kubectl"
has "bound to the cluster-access identity, which holds platform authority for a reserved namespace" \
  "kubeconfig-access.yaml" "$TMP/credential-boundary.kubectl"
if [ "$(grep -c 'deploy qualreg/aws/us-east-1' "$TMP/credential-boundary.sol")" -ge 2 ]; then
  ok "and resumes the deploy once the prerequisite exists"
else
  no "and resumes the deploy once the prerequisite exists" "two whole-target deploy invocations" \
    "$(grep -c 'deploy qualreg/aws/us-east-1' "$TMP/credential-boundary.sol")"
fi
has "the run record states the credential was supplied" \
  "platform_credential: redpanda/redpanda-users" "$TMP/credential-boundary.logs/prerequisites.txt"
has "and that this run generated it" "platform_credential_source: generated-for-this-run" \
  "$TMP/credential-boundary.logs/prerequisites.txt"
lacks "and never records the value" "SCRAM-SHA-256" "$TMP/credential-boundary.logs/prerequisites.txt"

printf '\nscenario: a platform credential the harness cannot supply fails the run\n'
run_phase credential-refused cloud STUB_APPLY_CREDENTIAL_MISSING=1 STUB_SECRET_CREATE_FAILS=1
refused credential-refused "the install does not proceed without the prerequisite the harness stands in for"
has "and the failure names the input the harness could not create" "redpanda/redpanda-users" \
  "$TMP/credential-refused.out"
if [ "$(grep -c 'deploy qualreg/aws/us-east-1' "$TMP/credential-refused.sol")" = "1" ]; then
  ok "and the harness does not resume the deploy"
else
  no "and the harness does not resume the deploy" "one whole-target deploy invocation" \
    "$(grep -c 'deploy qualreg/aws/us-east-1' "$TMP/credential-refused.sol")"
fi

run_phase destroyrun destroy
is "exit 0" "$(cat "$TMP/destroyrun.rc")" "0"
has "the destroy carries the same var file, so teardown renders the applied shape" \
  "destroy qualreg/aws/us-east-1 --apply --var-file $ROOT/internal/qualification/aws/qual-aws-row.tfvars" \
  "$TMP/destroyrun.sol"

printf '\nscenario: the app phase publishes exactly the selected units\n'
run_row alphaunits TRANSPORT=0 SVC_UNIT=orders_svc WORKER_UNIT=fulfilment_worker \
  APP_UNITS="orders_svc fulfilment_worker"
is "exit 0" "$(cat "$TMP/alphaunits.rc")" "0"
has "the service image is built from the selected unit" \
  "docker build -f $TMP/alphaunits.logs/app-build-context/app/payments/orders_svc/Dockerfile" \
  "$TMP/alphaunits.docker"
has "and from the candidate revision's context, not the checkout" \
  " $TMP/alphaunits.logs/app-build-context" "$TMP/alphaunits.docker"
exists "the run records the revision it bound the build to" \
  "$TMP/alphaunits.logs/candidate-binding.txt"
has "and that revision is the candidate's" \
  "candidate_revision: $CANDIDATE_REVISION" "$TMP/alphaunits.logs/candidate-binding.txt"
has "and the framework pin names that commit" \
  "github.com/sol-fab/sol.git#$CANDIDATE_REVISION" "$TMP/alphaunits.logs/candidate-binding.txt"
lacks "so no pin reaches the build from a moving ref" \
  "#main" "$TMP/alphaunits.logs/candidate-binding.txt"
has "and pushed under its k8s name" \
  "docker push $ECR/pluto/orders-svc:row-" "$TMP/alphaunits.docker"
has "the worker image too" \
  "docker push $ECR/pluto/fulfilment-worker:row-" "$TMP/alphaunits.docker"
lacks "and no unselected image is built" "charge-svc" "$TMP/alphaunits.docker"
has "and every selected unit is pinned by digest" \
  "image-ref orders_svc=$ECR/pluto/orders-svc@sha256:" "$TMP/alphaunits.sol"

printf '\nscenario: a checkout at another revision cannot qualify as the candidate\n'
git -c user.name=qualification -c user.email=qualification@example.invalid \
  -C "$WORKSPACE" commit -q --allow-empty -m "a revision cut after the candidate"
run_row driftrev TRANSPORT=0 APP_UNITS="orders_svc"
refused driftrev "the run refuses a workspace that is not the candidate revision"
lacks "and builds nothing" "docker build" "$TMP/driftrev.docker"
lacks "and records no candidate binding" "candidate_revision" "$TMP/driftrev.logs/candidate-binding.txt"
has "and the refusal names the candidate it could not bind to" \
  "$CANDIDATE_REVISION" "$TMP/driftrev.out"
git -C "$WORKSPACE" reset -q --hard "$CANDIDATE_REVISION"

printf '\nscenario: the destroy phase survives a closed stdout reader and records the inventory\n'
run_phase_closed_stdout destroyclosed destroy
is "exit 0" "$(cat "$TMP/destroyclosed.rc")" "0"
has "the teardown still ran" "destroy qualreg/aws/us-east-1 --apply" "$TMP/destroyclosed.sol"
exists "the independent inventory is captured" "$TMP/destroyclosed.logs/aws-inventory.txt"
has "the harness writes its own narrative" "destroy returned success" \
  "$TMP/destroyclosed.logs/harness.log"

printf '\nscenario: SIGTERM during cloud tears down and records the independent inventory\n'
run_phase_sigterm cloudterm TERM cloud STUB_SOL_SLEEP=2
if [ "$(cat "$TMP/cloudterm.rc")" = "0" ]; then
  no "a terminated cloud run exits non-zero" "non-zero" "0"
else
  ok "a terminated cloud run exits non-zero"
fi
has "the teardown runs" "destroy qualreg/aws/us-east-1 --apply" "$TMP/cloudterm.sol"
exists "the independent inventory is captured" "$TMP/cloudterm.logs/aws-inventory.txt"
has "the harness records the signal" "received SIGTERM" "$TMP/cloudterm.logs/harness.log"

printf '\nscenario: a repeated invocation cannot reuse an occupied disposable target\n'
run_phase occupied cloud STUB_STATE_PRESENT=1
refused occupied "an occupied state key is refused as a fresh target"
has "the refusal names the occupied state key" "already exists" "$TMP/occupied.out"
lacks "nothing is applied" "deploy qualreg/aws/us-east-1" "$TMP/occupied.sol"

printf '\nscenario: an evidence directory that belongs to another attempt is refused\n'
PRESEED_FOREIGN_ATTEMPT=another-attempt run_phase reused-dir cloud
refused reused-dir "an evidence directory for another attempt is refused"
has "the refusal names the attempt the directory belongs to" "another-attempt" "$TMP/reused-dir.out"
lacks "nothing is applied" "deploy qualreg/aws/us-east-1" "$TMP/reused-dir.sol"

printf '\nscenario: a credential for a replaced same-name cluster is refused\n'
run_phase stale-endpoint cloud STUB_KUBECONFIG_STALE=1
refused stale-endpoint "a credential for a replaced cluster is refused"
has "the refusal names the endpoint binding" "not this cluster's current" "$TMP/stale-endpoint.out"

printf '\nscenario: the run identity reaches the provider inventory\n'
run_phase identitycloud cloud
has "the fresh attempt records its identity" "state_key=sol/qualreg/aws/us-east-1/cloud.tfstate" \
  "$TMP/identitycloud.logs/attempt.txt"
run_phase identitydestroy destroy
has "and the inventory carries the attempt, target and state key" "attempt=$ATTEMPT" \
  "$TMP/identitydestroy.logs/aws-inventory.txt"
has "with the target" "target=qualreg/aws/us-east-1" "$TMP/identitydestroy.logs/aws-inventory.txt"
has "and the state key" "state_key=sol/qualreg/aws/us-east-1/cloud.tfstate" \
  "$TMP/identitydestroy.logs/aws-inventory.txt"

printf '\nscenario: terminal records do not prevent an ABSENT verdict\n'
run_phase terminal-residue verify STUB_TERMINATED_INSTANCE=1 STUB_DELETED_NAT=1
is "exit 0" "$(cat "$TMP/terminal-residue.rc")" "0"
has "a terminated instance reads ABSENT" "ec2-instance: ABSENT" \
  "$TMP/terminal-residue.logs/aws-inventory-verdict.txt"
has "a deleted NAT gateway reads ABSENT" "nat-gateway: ABSENT" \
  "$TMP/terminal-residue.logs/aws-inventory-verdict.txt"
lacks "and nothing is reported PRESENT" "PRESENT" \
  "$TMP/terminal-residue.logs/aws-inventory-verdict.txt"
has "the raw terminal record is retained as evidence" '"Name":"terminated"' \
  "$TMP/terminal-residue.logs/aws-inventory.txt"
has "and the durable zone is recorded but excluded from the residue verdict" \
  "durable-hosted-zone: retained" "$TMP/terminal-residue.logs/aws-inventory-verdict.txt"

printf '\nscenario: any required disposable class can fail the verdict alone\n'
run_phase live-residue verify STUB_LIVE_INSTANCE=1
refused live-residue "a live instance fails the verification"
has "a live instance reads PRESENT" "ec2-instance: PRESENT" \
  "$TMP/live-residue.logs/aws-inventory-verdict.txt"
run_phase live-nat verify STUB_LIVE_NAT=1
refused live-nat "a live NAT gateway fails the verification"
has "a live NAT gateway reads PRESENT" "nat-gateway: PRESENT" \
  "$TMP/live-nat.logs/aws-inventory-verdict.txt"
run_phase live-rds verify STUB_LIVE_RDS=1
refused live-rds "a live RDS instance fails the verification"
has "the database reads PRESENT" "rds-instance: PRESENT" \
  "$TMP/live-rds.logs/aws-inventory-verdict.txt"
has "while the empty classes still read ABSENT, not as a blanket failure" \
  "ec2-instance: ABSENT" "$TMP/live-rds.logs/aws-inventory-verdict.txt"
run_phase live-ecr verify STUB_LIVE_ECR=1
refused live-ecr "a live repository at the target's registry path fails the verification"
has "the registry class reads PRESENT" "ecr-repository: PRESENT" \
  "$TMP/live-ecr.logs/aws-inventory-verdict.txt"
run_phase live-volume verify STUB_LIVE_VOLUME=1
refused live-volume "an orphaned EBS volume fails the verification"
has "the volume class reads PRESENT" "ebs-volume: PRESENT" \
  "$TMP/live-volume.logs/aws-inventory-verdict.txt"
run_phase live-lb verify STUB_LIVE_LB=1
refused live-lb "a load balancer fails the verification"
has "the load balancer class reads PRESENT" "load-balancer: PRESENT" \
  "$TMP/live-lb.logs/aws-inventory-verdict.txt"
run_phase live-iam verify STUB_LIVE_IAM_ROLE=1
refused live-iam "a leftover target-owned IAM role fails the verification"
has "the identity class reads PRESENT" "iam-role: PRESENT" \
  "$TMP/live-iam.logs/aws-inventory-verdict.txt"
run_phase live-bucket verify STUB_LIVE_S3_BUCKET=1
refused live-bucket "a leftover target-owned bucket fails the verification"
has "the bucket class reads PRESENT" "s3-bucket: PRESENT" \
  "$TMP/live-bucket.logs/aws-inventory-verdict.txt"

printf '\nscenario: retained snapshots follow the target declaration\n'
run_phase snapshot-residue verify STUB_LIVE_RDS_SNAPSHOT=1
refused snapshot-residue "a snapshot fails a retention:none target"
has "the snapshot reads PRESENT under retention none" "rds-snapshot: PRESENT" \
  "$TMP/snapshot-residue.logs/aws-inventory-verdict.txt"
run_phase retaining-snapshot verify STUB_LIVE_RDS_SNAPSHOT=1 RETENTION=final-snapshot
is "exit 0" "$(cat "$TMP/retaining-snapshot.rc")" "0"
has "the declared final snapshot is excluded from residue" "rds-snapshot: ABSENT" \
  "$TMP/retaining-snapshot.logs/aws-inventory-verdict.txt"

printf '\nscenario: a failed read is UNKNOWN, never absence\n'
run_phase unreadable-residue verify STUB_INVENTORY_UNREADABLE=1
refused unreadable-residue "an unreadable inventory fails the verification"
has "the unreadable class reads UNKNOWN" "ec2-instance: UNKNOWN" \
  "$TMP/unreadable-residue.logs/aws-inventory-verdict.txt"
lacks "and is never reported ABSENT" "ec2-instance: ABSENT" \
  "$TMP/unreadable-residue.logs/aws-inventory-verdict.txt"
has "and the overall verdict is not ABSENT" "verdict: NOT ABSENT" \
  "$TMP/unreadable-residue.logs/aws-inventory-verdict.txt"

printf '\nscenario: a syntactically valid but wrong-shaped response is UNKNOWN, never absence\n'
run_phase malformed-rds verify STUB_MALFORMED_RDS=1
refused malformed-rds "a wrong-shaped response fails the verification"
has "the malformed class reads UNKNOWN" "rds-instance: UNKNOWN" \
  "$TMP/malformed-rds.logs/aws-inventory-verdict.txt"
lacks "and is never read as ABSENT" "rds-instance: ABSENT" \
  "$TMP/malformed-rds.logs/aws-inventory-verdict.txt"

printf '\nscenario: unrelated account resources are not the target residue\n'
run_phase unrelated-residue verify STUB_FOREIGN_INSTANCE=1
is "exit 0" "$(cat "$TMP/unrelated-residue.rc")" "0"
has "another cluster's instance does not read as residue" "ec2-instance: ABSENT" \
  "$TMP/unrelated-residue.logs/aws-inventory-verdict.txt"

printf '\nscenario: a target that names no var file refuses rather than deploy with defaults\n'
cat >"$WORKSPACE/sol/environments.local.yml" <<'YAML'
qualreg:
  targets:
    aws/us-east-1:
      cluster_name: test-cluster
      state_bucket: sol-qual-test-tfstate
YAML
run_phase no-tfvars cloud
refused no-tfvars "a target that names no terraform_var_file refuses the cloud phase"
has "and the refusal says why" "declares no terraform_var_file" "$TMP/no-tfvars.out"
lacks "and no Sol command runs" "sol " "$TMP/no-tfvars.sol"

printf '\n'
if [ "$fail" -gt 0 ]; then
  printf 'live-row self-test: %s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi
printf 'live-row self-test: %s passed\n' "$pass"
