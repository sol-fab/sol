#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
export TMP
export ATTEMPT="${ATTEMPT:-aws-self-test}"
# A fixed image tag: `prepare` builds under it and `cloud` publishes under it, so the seeding
# helpers and the harness name the same tag. The harness's own default is `row-<timestamp>`.
export APP_TAG="${APP_TAG:-row-self-test}"
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
present() { if [ -s "$1" ]; then ok "$2"; else no "$2" "present and non-empty" "missing: $1"; fi; }
not_exists() { if [ -e "$2" ]; then no "$1" "absent: $2" "present"; else ok "$1"; fi; }
# #1583 removed this helper while keeping its call sites; restore the attempt seed the
# teardown scenarios use so their assertions run instead of printing "command not found".
seed_attempt() {
  local name="$1" issuer="${SEED_ISSUER:-letsencrypt-staging}" claim="${SEED_CLAIM:-mechanism-only}"
  mkdir -p "$TMP/$name.logs"
  {
    printf 'attempt=%s\n' "$ATTEMPT"
    printf 'row=%s\n' qualreg
    printf 'target=%s\n' qualreg/aws/us-east-1
    printf 'state_key=%s\n' sol/qualreg/aws/us-east-1/cloud.tfstate
    printf 'issuer=%s\n' "$issuer"
    printf 'claim=%s\n' "$claim"
    if [ "$claim" = production ]; then printf 'promotion_eligible=yes\n'; else printf 'promotion_eligible=no\n'; fi
  } >"$TMP/$name.logs/attempt.txt"
}
refused() { if [ "$(cat "$TMP/$1.rc" 2>/dev/null)" != "0" ]; then ok "$2"; else no "$2" "non-zero" "0"; fi; }
# A missing helper must fail the suite, not silently skip its assertion. This is the
# defect class #1583 left: the suite exited 0 while six assertions never ran.
# Required-helper inventory: every helper the suite calls must be listed here.
# Adding a helper means adding it to this list; a stale list lets the next
# "command not found" silently skip an assertion.
for helper in ok no has lacks is exists present not_exists seed_attempt refused; do
  if ! declare -F "$helper" >/dev/null; then
    echo "test helper missing: $helper" >&2
    exit 1
  fi
done

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
cp "$REPO/internal/qualification/kafka-delivery.py" "$ROOT/internal/qualification/"
cp "$REPO/internal/qualification/state-evidence.py" "$ROOT/internal/qualification/"
cp "$REPO/internal/qualification/application-secret-refusal.sh" "$ROOT/internal/qualification/"
cp -R "$REPO/internal/qualification/fixtures" "$ROOT/internal/qualification/"
cat >"$ROOT/internal/qualification/database-contract-binding.py" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
# Test stub: the pins recorder keeps the canonical shape, and the delivery assertion
# reads the specimen's consumer set. The default is one consumer; a scenario overrides
# it with STUB_SPECIMEN_CONSUMERS (a JSON list), which is how a partial or foreign
# delivery is modelled.
prefix = os.environ.get("STUB_CLASS_PREFIX", "qualreg-aws-us-east-1")
consumers = json.loads(os.environ.get("STUB_SPECIMEN_CONSUMERS") or "[]")
if not consumers:
    consumers = [{"namespace": "pluto-payments", "name": "orders-svc", "database": "app-db",
                  "credential": {"namespace": "pluto-payments", "name": prefix + "-dml-creds"},
                  "consuming_containers": ["orders-svc"]}]
print(json.dumps({
    "candidate": {"revision": "0" * 40, "bundle_sha256": "0" * 64},
    "definition": {"digest": "0" * 64},
    "specimen": {"digest": "0" * 64,
                 "declaration": {"requested_target": sys.argv[-1], "target": sys.argv[-1],
                                 "workloads": consumers}},
}))
STUB

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
# `kubeconfig=` records the destination Sol inherited: teardown must select this attempt's own
# kubeconfig rather than whatever the calling shell exported.
printf 'sol %s [runner=%s] [home=%s] [kubeconfig=%s]\n' \
  "$*" "${SOL_MIGRATION_RUNNER_IMAGE:-unset}" "${SOL_HOME:-unset}" "${KUBECONFIG:-unset}" >>"$SOL_LOG"
# A cold target has no reachable release to inherit workload images from; the real `sol plan`
# refuses, and the harness records the skip and continues (issue #1408).
if [ "${1:-}" = "plan" ]; then
  if [ "${STUB_COLD_PLAN:-0}" = "1" ]; then
    printf 'error: cannot inherit workload images from the current release (exited with code 1: error: context "sol-qual-aws-2b-deploy" does not exist); supply --image-ref for every workload\n'
    exit 1
  fi
  exit 0
fi
# The app phase's own sequence uses these; each clears the refusal the next deploy checks.
if [ "${1:-}" = "migrate" ]; then
  [ -n "${STUB_APP_MARKER_DIR:-}" ] && : >"$STUB_APP_MARKER_DIR/migrated"
  exit 0
fi
if [ "${1:-}" = "secret" ] && [ "${2:-}" = "set" ]; then
  [ -n "${STUB_APP_MARKER_DIR:-}" ] && : >"$STUB_APP_MARKER_DIR/secrets"
  exit 0
fi
# The whole-target deploy reconciles the durable installation inline, so an installation
# that cannot be established and a first deploy that reaches the substrate both surface
# here. A fresh account's installation offer is interactive in the real command; the stub
# accepts it and reports the reconciled environment `sol deploy` prints before workloads.
if [ "${1:-}" = "deploy" ] && [ "${2:-}" = probe/byo/qualification ]; then
  printf 'error: pluto-payments/secret-probe-secrets does not hold the required non-empty secret key(s): SOL_API_KEY.\n'
  exit "${STUB_SECRET_PROBE_RC:-1}"
fi
if [ "${1:-}" = "deploy" ]; then
  : >"${TMP:-/tmp}/ecr-sol-created"
  # 2b's app-phase ordering on a fresh profiled target: the first deploy refuses at the
  # post-setup migration gate, `sol migrate apply` clears it, the second deploy refuses the
  # absent operator secrets, and `sol secret set` clears that. `STUB_APP_REFUSALS=1` models
  # that sequence, so the phase's own ordering is exercised rather than assumed.
  if [ "${STUB_APP_REFUSALS:-0}" = "1" ]; then
    if [ ! -f "${STUB_APP_MARKER_DIR:-/nonexistent}/migrated" ]; then
      printf 'error: the required migration set is not applied. Missing: 001_notifications\n'
      printf '  Migrations are workspace-wide, so this is the same set for every deploy. Run `sol migrate apply %s`, then deploy again.\n' "${2:-}"
      exit 1
    fi

  fi
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
  # The real deploy prints this from its database setup step: the writer declares where it
  # wrote, so the row reads the location instead of reproducing the naming rule (#1424).
  printf 'sol-database-identity: target=%s resource=app_db namespace=%s ddl-creds=%s authority=%s ca-configmap=%s\n' \
    "${STUB_CLASS_PREFIX:-qualreg-aws-us-east-1}" \
    "${STUB_DDL_NAMESPACE:-pluto-comms}" \
    "${STUB_CLASS_PREFIX:-qualreg-aws-us-east-1}-ddl-creds" \
    "${STUB_CLASS_PREFIX:-qualreg-aws-us-east-1}-db-credentials" \
    "${STUB_CLASS_PREFIX:-qualreg-aws-us-east-1}-db-ca"
  printf 'Kafka: delivered the managed credential to target-kafka-creds in pluto-comms, pluto-payments.\n'
  printf 'The environment for %s is reconciled.\n' "${2:-}"
  # The cold deploy's artifact gate (#1473): with no --image-ref the target is provisioned but
  # its workloads name no immutable image, so the deploy refuses after reconciling the
  # environment. A deploy that names digests continues to the workload stage (and its own
  # refusal sequence, modelled above).
  case " $* " in
    *" --image-ref "*) exit 0 ;;
    *)
      printf 'Deployment incomplete.\n'
      printf 'The environment is reconciled and no workload has moved. Publish the images and re-run: sol deploy %s\n' "${2:-}"
      exit 1
      ;;
  esac
fi
if [ "${1:-}" = "destroy" ]; then rm -f "${TMP:-/tmp}/ecr-sol-created"; fi
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
printf 'health: ok\ncharge id: ch_qual01\nread-back: the worker effect ch_qual01 is visible to the service\n' \
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
printf 'charge id: ord_qual01\nread-back: the worker effect ord_qual01 is visible to the service\n' \
  >"$1/transport-transaction.txt"
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
      cluster_issuer: letsencrypt-staging
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
# The publisher identity the row assumes, and the marker the stub answers its assumed session
# with. Exported because the stubs are separate processes.
PUBLISHER_ROLE_ARN="arn:aws:iam::123456789012:role/sol-qual5-publisher"
PUBLISHER_ACCESS_KEY_STUB="AKIAPUBLISHERSTUB0000000"
export PUBLISHER_ROLE_ARN PUBLISHER_ACCESS_KEY_STUB
PUBLISHER_ROLE_STUB_ARN="$PUBLISHER_ROLE_ARN"
export PUBLISHER_ROLE_STUB_ARN

cat >"$TMP/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >>"$AWS_LOG"
class_read() {
  case "$1 $2" in
    "eks list-clusters" | "rds describe-db-instances" | "rds describe-db-subnet-groups" | \
      "rds describe-db-snapshots" | "ec2 describe-instances" | "ec2 describe-vpcs" | \
      "ec2 describe-nat-gateways" | "ec2 describe-addresses" | "ec2 describe-volumes" | \
      "elbv2 describe-load-balancers" | "elbv2 describe-tags" | "ecr describe-repositories" | \
      "iam list-open-id-connect-providers" | "ec2 describe-security-groups" | \
      "iam list-roles" | "iam list-policies" | "s3api list-buckets" | \
      "cloudwatch list-dashboards" | "logs describe-log-groups")
      return 0
      ;;
    *) return 1 ;;
  esac
}
if [ "${STUB_CREDENTIALS_STALE:-0}" = "1" ] && [ "$1 $2" = "configure export-credentials" ]; then
  printf 'failed to refresh cached credentials, refresh cached SSO token failed, unable to refresh SSO token, operation error SSO OIDC: CreateToken, https response error StatusCode: 400, InvalidGrantException\n' >&2
  exit 255
fi
if [ "${STUB_INVENTORY_UNREADABLE:-0}" = "1" ] && class_read "$1" "$2"; then
  printf 'Unable to locate credentials\n' >&2
  exit 255
fi
case "$1 $2" in
  # The publisher's own assumed session (SEC-011). Only the publisher ARN the run names is
  # assumable: anything else is refused, so a run that published through some other identity
  # would fail here rather than silently publish as the operator.
  "sts assume-role")
    if [ "${STUB_ASSUME_REFUSED:-0}" = "1" ]; then
      printf 'An error occurred (AccessDenied) when calling the AssumeRole operation: User is not authorized to perform: sts:AssumeRole on resource\n' >&2
      exit 255
    fi
    case " $* " in
      *" --role-arn $PUBLISHER_ROLE_STUB_ARN "*)
        printf '{"Credentials":{"AccessKeyId":"%s","SecretAccessKey":"stub-secret","SessionToken":"stub-token","Expiration":"2030-01-01T00:00:00Z"}}\n' \
          "$PUBLISHER_ACCESS_KEY_STUB"
        ;;
      *)
        printf 'An error occurred (AccessDenied) when calling the AssumeRole operation: User is not authorized to perform: sts:AssumeRole on this resource\n' >&2
        exit 255
        ;;
    esac
    ;;
  "sts get-caller-identity")
    case " $* " in
      *"--query Arn"*)
        case "${AWS_ACCESS_KEY_ID:-}" in
          "$PUBLISHER_ACCESS_KEY_STUB")
            if [ "${STUB_PUBLISHER_IMPERSONATES:-}" = "1" ]; then
              printf '%s\n' "arn:aws:sts::123456789012:assumed-role/sol-qual5-operator/elsewhere"
            else
              printf '%s\n' "arn:aws:sts::123456789012:assumed-role/sol-qual5-publisher/sol-qualification-publisher"
            fi
            ;;
          *) printf '%s\n' "arn:aws:iam::123456789012:user/qualifier" ;;
        esac
        ;;
      *"--output json"*)
        case "${AWS_ACCESS_KEY_ID:-}" in
          "$PUBLISHER_ACCESS_KEY_STUB")
            printf '{"Account":"123456789012","Arn":"arn:aws:sts::123456789012:assumed-role/sol-qual5-publisher/sol-qualification-publisher"}\n'
            ;;
          *) printf '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/qualifier"}\n' ;;
        esac
        ;;
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
    [ "$dest" = - ] || mkdir -p "$(dirname "$dest")"
    printf '{"outputs":{"kafka_authority":{"value":{"secret_name":"sol-kafka-test-cluster","reference":"arn:aws:secretsmanager:us-east-1:123456789012:secret:sol-kafka-test-cluster-123456","username":"sol-workloads","mechanism":"SCRAM-SHA-256"}},"postgres_url":{"value":"postgres://user:qual-secret@db.example.test:5432/pluto"}}}\n' | { if [ "$dest" = - ]; then cat; else cat >"$dest"; fi; }
    ;;
  "secretsmanager get-secret-value")
    if [ "${STUB_KAFKA_DELIVERY:-ok}" = denied ]; then printf 'denied' >&2; exit 255; fi
    printf '{"SecretString":"testpass"}\n'; exit 0 ;;
  "secretsmanager describe-secret")
    case "${STUB_KAFKA_SECRET:-absent}" in
      present) printf '{"Name":"sol-kafka-test-cluster"}\n'; exit 0 ;;
      pending) printf '{"Name":"sol-kafka-test-cluster","DeletedDate":1}\n'; exit 0 ;;
      permission) printf 'AccessDeniedException: metadata forbidden\n' >&2; exit 255 ;;
      malformed) printf '{}\n'; exit 0 ;;
      *) printf 'An error occurred (ResourceNotFoundException) when calling the DescribeSecret operation: not found\n' >&2; exit 255 ;;
    esac
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
      printf '{"Addresses":[{"AllocationId":"eipalloc-live","PublicIp":"198.51.100.5","Tags":[{"Key":"kubernetes.io/cluster/test-cluster","Value":"owned"}]}]}\n'
    else
      printf '{"Addresses":[]}\n'
    fi
    ;;
  "iam list-open-id-connect-providers") printf '{"OpenIDConnectProviderList":[]}\n' ;;
  "ec2 describe-security-groups") printf '{"SecurityGroups":[]}\n' ;;
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
    # The lifecycle model is about *the target's own* repositories, which Sol names. The
    # whole-account listing (the inventory's probe) keeps its own fixture.
    case "$*" in
      *--repository-names*)
        if [ "${STUB_ECR_LIFECYCLE:-0}" = "1" ]; then
          # Sol's repositories exist only once its apply created them, and go again with the
          # destroy: the phases read absent -> present -> absent for real.
          if [ -s "${TMP:-/tmp}/ecr-sol-created" ]; then
            printf '{"repositories":[{"repositoryName":"pluto/charge-svc"}]}\n'
            exit 0
          fi
          printf 'An error occurred (RepositoryNotFoundException) when calling the DescribeRepositories operation\n' >&2
          exit 1
        fi
        ;;
    esac
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
    # The destroy phase reads the cluster's existence to decide whether the workload release
    # applies, so the stub models all three answers: present, positively absent, unreadable.
    if [ "${STUB_CLUSTER_ABSENT:-0}" = "1" ]; then
      printf 'An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found for name: %s\n' \
        "${STUB_CLUSTER_ABSENT_NAME:-test-cluster}" >&2
      exit 255
    fi
    if [ "${STUB_CLUSTER_UNREADABLE:-0}" = "1" ]; then
      printf 'Unable to locate credentials. You can configure credentials by running "aws login".\n' >&2
      exit 255
    fi
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
  *"get deployments -n "*" -o json"*)
    ns=""; prev=""
    for word in "$@"; do [ "$prev" != -n ] || ns="$word"; prev="$word"; done
    case "$ns" in
      pluto-payments) names="charge-svc orders-svc" ;;
      pluto-comms) names="notify-worker fulfilment-worker" ;;
      *) printf '{"items":[]}\n'; exit 0 ;;
    esac
    printf '{"items":['
    comma=""
    credential=target-kafka-creds
    [ "${STUB_KAFKA_DELIVERY:-ok}" != missing ] || credential=other-kafka-creds
    for name in $names; do
      case " ${APP_UNITS:-checkout_svc charge_svc notify_worker orders_svc fulfilment_worker} " in
        *" ${name//-/_} "*) ;;
        *) continue ;;
      esac
      printf '%s{"metadata":{"name":"%s"},"spec":{"template":{"spec":{"containers":[{"env":[{"name":"KAFKA_SASL_PASSWORD","valueFrom":{"secretKeyRef":{"name":"%s","key":"KAFKA_SASL_PASSWORD"}}}],"volumeMounts":[{"name":"kafka-ca"}]}],"volumes":[{"name":"kafka-ca","secret":{"secretName":"%s","items":[{"key":"KAFKA_SSL_CA_CERT"}]}}]}}}}' "$comma" "$name" "$credential" "$credential"
      comma=,
    done
    printf ']}\n'
    exit 0 ;;
  *"get secret target-kafka-creds "*"jsonpath={.metadata.name}"*)
    if [ "${STUB_KAFKA_DELIVERY:-ok}" = denied ]; then exit 1; fi
    printf 'target-kafka-creds\n'
    exit 0 ;;
  *"get secret "*" -o json"*)
    case "$*" in
      *"get secret redpanda-users "*)
        if [ "${STUB_NO_BROKER_CRED:-0}" = 1 ] || [ "${STUB_UNREADABLE_BROKER_CRED:-0}" = 1 ]; then exit 1; fi
        printf '{"data":{"users.txt":"%s"}}\n' "$(printf sol-workloads:testpass:SCRAM-SHA-256 | base64 -w0)" ;;
      *"get secret redpanda-default-cert "*)
        printf '{"data":{"ca.crt":"%s"}}\n' "$(printf ca-certificate-for-tests | base64 -w0)" ;;
      *"get secret target-kafka-creds "*)
        value=testpass
        [ "${STUB_KAFKA_DELIVERY:-ok}" != mismatch ] || value=wrongpass
        printf '{"data":{"KAFKA_SASL_PASSWORD":"%s","KAFKA_SSL_CA_CERT":"%s"}}\n' "$(printf %s "$value" | base64 -w0)" "$(printf ca-certificate-for-tests | base64 -w0)" ;;
      *) exit 1 ;;
    esac
    exit 0 ;;
  *" create secret generic redpanda-users "*)
    printf 'qualification must not create the broker credential\n' >&2; exit 1 ;;
  # The database CA mount (#1481): the app phase reads the declared ConfigMap at each consuming
  # namespace, then reads **each** selected workload's pod template for its `db-ca` volume.
  # `STUB_CA_UNMOUNTED` names one workload that mounts a different ConfigMap, so the "one of
  # several" case is modelled rather than the all-or-nothing one.
  *" get deploy "*" -o json "*)
    ca_workload=""
    ca_prev=""
    for ca_arg in $*; do
      [ "$ca_prev" = "deploy" ] && ca_workload="$ca_arg"
      ca_prev="$ca_arg"
    done
    if [ "${STUB_CA_UNMOUNTED:-}" = "$ca_workload" ]; then
      printf '{"spec":{"template":{"spec":{"volumes":[{"name":"db-ca","configMap":{"name":"other-db-ca"}}]}}}}\n'
    else
      printf '{"spec":{"template":{"spec":{"volumes":[{"name":"db-ca","configMap":{"name":"%s-db-ca"}}]}}}}\n' \
        "${STUB_CLASS_PREFIX:-qualreg-aws-us-east-1}"
    fi
    exit 0
    ;;
  *" get configmap "*"-db-ca"*)
    if [ "${STUB_CA_UNREADABLE:-0}" = "1" ]; then
      printf 'Error from server (Forbidden): configmaps is forbidden: User cannot get resource\n' >&2
      exit 1
    fi
    if [ "${STUB_CA_ABSENT:-0}" = "1" ]; then
      printf 'Error from server (NotFound): configmaps "%s-db-ca" not found\n' \
        "${STUB_CLASS_PREFIX:-qualreg-aws-us-east-1}" >&2
      exit 1
    fi
    exit 0
    ;;
  # The cold-start boundary is established from namespace absence (#1488 review, #1492): the
  # observation identity's view is validated first, then each declared namespace is read. The
  # default is "every declared namespace is absent" (the deploy refused before it established
  # the workload namespaces); each flag models one answer the assertion must not read as a pass.
  *" get namespace "*)
    ns=""
    prev=""
    for a in $*; do
      [ "$prev" = "namespace" ] && ns="$a"
      prev="$a"
    done
    case "$ns" in
      kube-system)
        if [ "${STUB_NS_VIEW_UNREADABLE:-0}" = "1" ]; then
          printf 'Error from server (Forbidden): namespaces "kube-system" is forbidden: User cannot get resource\n' >&2
          exit 1
        fi
        printf 'namespace/kube-system\n'
        exit 0
        ;;
      sol-nonexistent-namespace-probe-*)
        if [ "${STUB_NS_VIEW_FILTERED:-0}" = "1" ]; then
          printf 'Error from server (Forbidden): namespaces "%s" is forbidden: User cannot get resource\n' "$ns" >&2
        else
          printf 'Error from server (NotFound): namespaces "%s" not found\n' "$ns" >&2
        fi
        exit 1
        ;;
    esac
    if [ "${STUB_COLD_NAMESPACE_PRESENT:-}" = "$ns" ]; then
      printf 'namespace/%s\n' "$ns"
      exit 0
    fi
    if [ "${STUB_COLD_NAMESPACE_FORBIDDEN:-}" = "$ns" ]; then
      printf 'Error from server (Forbidden): namespaces "%s" is forbidden: User cannot get resource\n' "$ns" >&2
      exit 1
    fi
    if [ "${STUB_COLD_NAMESPACE_TIMEOUT:-}" = "$ns" ]; then
      printf 'Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout\n' >&2
      exit 1
    fi
    printf 'Error from server (NotFound): namespaces "%s" not found\n' "$ns" >&2
    exit 1
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
  # The row now reads the class Secret *by name at the location the deploy declared*, so the
  # stub answers that shape too -- and can model its absence, which the fall-through cannot.
  *" get secret "*"-ddl-creds -n "*)
    if [ "${STUB_DDL_CREDS_ABSENT:-0}" = "1" ]; then
      printf 'Error from server (NotFound): secrets not found\n' >&2
      exit 1
    fi
    exit 0
    ;;
  # The delivery assertion reads the consumer Deployment's rendered routing: which
  # Secret its POSTGRES_URL env reads from. `STUB_POSTGRES_SECRET` models a unit that
  # still reads the master copy; the default is the declared class Secret.
  *" get deployment "*)
    dep_name="" dep_ns="" prev=""
    for a in $*; do
      [ "$prev" = "deployment" ] && dep_name="$a"
      [ "$prev" = "-n" ] && dep_ns="$a"
      prev="$a"
    done
    printf '{"spec":{"template":{"spec":{"containers":[{"name":"%s","env":[{"name":"POSTGRES_URL","valueFrom":{"secretKeyRef":{"name":"%s"}}}]}]}}}}\n' \
      "${STUB_POSTGRES_CONTAINER:-$dep_name}" \
      "${STUB_POSTGRES_SECRET:-${STUB_CLASS_PREFIX:-qualreg-aws-us-east-1}-dml-creds}"
    exit 0
    ;;
  *" get secret "*"-dml-creds -n "*)
    ns=""
    prev=""
    for a in $*; do
      [ "$prev" = "-n" ] && ns="$a"
      prev="$a"
    done
    [ "$ns" = "${STUB_DML_NAMESPACE:-pluto-payments}" ] && exit 0
    printf 'Error from server (NotFound): secrets not found\n' >&2
    exit 1
    ;;
  *" get secret -A "*)
    printf '%s\n' \
      "${STUB_DML_NAMESPACE:-pluto-payments} ${STUB_CLASS_PREFIX:-qualreg-aws-us-east-1}-dml-creds" \
      "${STUB_DDL_NAMESPACE:-pluto-comms} ${STUB_CLASS_PREFIX:-qualreg-aws-us-east-1}-ddl-creds"
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
      *kubeconfig-deploy.yaml*)
        printf '{"status":{"userInfo":{"username":"arn:aws:sts::123456789012:assumed-role/deploy/session"}}}\n'
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

# Stub for the shared CA-family driver. The row calls it at the documented phase
# points; the observer's own semantics are covered by the offline qualification
# suite. This harness checks the wiring, phase ordering and failure propagation.
cat >"$TMP/bin/qualification_database_ca" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
phase="" request=""
while [ $# -gt 0 ]; do
  case "$1" in
    --phase) phase="$2"; shift 2 ;;
    --request) request="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$request" ] || { echo "stub CA driver: no --request" >&2; exit 2; }
if [ "${STUB_REQUIRE_SUBMISSION_AUTHORITY:-0}" = "1" ]; then
  python3 - "$request" <<'PY' || exit 1
import json, sys
request = json.load(open(sys.argv[1]))
authority = request.get("submission_authority")
if not isinstance(authority, dict) or not authority.get("principal"):
    print("stub CA driver: the request carries no submission authority", file=sys.stderr)
    raise SystemExit(1)
if authority == request.get("authority"):
    print("stub CA driver: the submission and observation identities are the same", file=sys.stderr)
    raise SystemExit(1)
PY
fi
[ -n "${LOG_DIR:-}" ] && printf '%s\n' "$phase" >>"$LOG_DIR/ca-phases.txt"
if [ "$phase" = "application" ]; then
  case "${STUB_CA_ABSENT:-0}:${STUB_CA_UNREADABLE:-0}:${STUB_CA_UNMOUNTED:-}" in
    1:*:*) echo "the shared database-CA observer found the declared CA ConfigMap absent from a consuming namespace" >&2; exit 1 ;;
    *:1:*) echo "the shared database-CA observer could not read the CA, so its presence is UNKNOWN" >&2; exit 1 ;;
    *:*:?*) echo "the shared database-CA observer found pluto-payments/$STUB_CA_UNMOUNTED does not mount the CA" >&2; exit 1 ;;
  esac
fi
if [ "$phase" = "migration" ] && [ -n "${STUB_APP_MARKER_DIR:-}" ]; then
  : >"$STUB_APP_MARKER_DIR/migrated"
fi
capture="$(python3 - "$request" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get("capture",""))
PY
)"
report="$(python3 - "$request" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get("report",""))
PY
)"
[ -n "$capture" ] && : >"$capture"
[ -n "$report" ] && : >"$report"
exit 0
STUB
chmod +x "$TMP/bin/qualification_database_ca"


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
# The trailing fields record which AWS identity the invocation ran under: publication must be
# the publisher's own assumed session, so the regression reads it back instead of trusting the
# phase's narration.
printf 'docker %s [aws_access_key_id=%s] [aws_profile=%s]\n' \
  "$*" "${AWS_ACCESS_KEY_ID:-unset}" "${AWS_PROFILE:-unset}" >>"$DOCKER_LOG"
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

# `cloud` publishes what `prepare` built into the repositories Sol's deploy creates. These
# scenarios are about the phases, not the publishing, so the cloud scenarios seed the *built tags*
# and let the publish step (and the fake docker push) produce the digests; an `app`-only scenario
# seeds the published digests directly, because `app` reuses the cloud phase's and never publishes
# its own. SKIP_PREPARE=1 leaves both absent for the refusal scenarios.
stub_prepare() {
  local unit
  mkdir -p "$LOG_DIR"
  # The attempt identity a real prepare writes; without it the cloud run refuses a log dir
  # that holds evidence for no attempt.
  {
    printf 'attempt=%s\n' "$ATTEMPT"
    printf 'row=%s\n' "qualreg"
    printf 'target=%s\n' "qualreg/aws/us-east-1"
    printf 'state_key=%s\n' "sol/qualreg/aws/us-east-1/cloud.tfstate"
    printf 'issuer=letsencrypt-staging\nclaim=mechanism-only\npromotion_eligible=no\n'
  } >"$LOG_DIR/attempt.txt"
  : >"$LOG_DIR/app-built-tags.txt"
  # STUB_NO_BUILT_TAGS models a `prepare` that materialized the candidate-bound contract but
  # produced no image, so the cloud phase has digests to publish only if it is absent.
  if [ "${STUB_NO_BUILT_TAGS:-0}" != 1 ]; then
    for unit in checkout_svc charge_svc notify_worker orders_svc fulfilment_worker; do
      printf '%s=%s/pluto/%s:%s\n' \
        "$unit" "$ECR" "$(printf '%s' "$unit" | tr '_' '-')" "$APP_TAG" >>"$LOG_DIR/app-built-tags.txt"
    done
  fi
}

stub_published_refs() {
  local unit
  mkdir -p "$LOG_DIR"
  {
    printf 'attempt=%s\n' "$ATTEMPT"
    printf 'row=%s\n' "qualreg"
    printf 'target=%s\n' "qualreg/aws/us-east-1"
    printf 'state_key=%s\n' "sol/qualreg/aws/us-east-1/cloud.tfstate"
    printf 'issuer=letsencrypt-staging\nclaim=mechanism-only\npromotion_eligible=no\n'
  } >"$LOG_DIR/attempt.txt"
  : >"$LOG_DIR/app-image-refs.txt"
  for unit in checkout_svc charge_svc notify_worker orders_svc fulfilment_worker; do
    printf '%s=%s/pluto/%s@sha256:%s\n' \
      "$unit" "$ECR" "$(printf '%s' "$unit" | tr '_' '-')" "$(printf 'b%.0s' $(seq 1 64))" >>"$LOG_DIR/app-image-refs.txt"
  done
}

# Bind fixture installs to real archive bytes, including every bundled asset.
python3 - "$TMP" "$INSTALL" <<'PYTHON'
import hashlib, json, pathlib, sys, tarfile
root, install = map(pathlib.Path, sys.argv[1:])
archive = install / "fixture.tar.gz"
with tarfile.open(archive, "w:gz") as bundle:
    bundle.add(install / "bin", arcname="sol-fixture/bin")
    bundle.add(install / "share", arcname="sol-fixture/share")
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
for document in root.rglob("candidate*.json"):
    candidate = json.loads(document.read_text())
    candidate.update(bundle=str(archive), bundle_sha256=digest)
    document.write_text(json.dumps(candidate))
PYTHON

# A scenario that runs `app` alone seeds the specimen the database assertion reads.
# The default is the same single consumer the binding stub emits; the delivery
# scenarios override it with STUB_SPECIMEN_CONSUMERS to model a partial or foreign set.
seed_database_specimen() {
  local consumers="" prefix="qualreg-aws-us-east-1" arg
  for arg in "$@"; do
    case "$arg" in
      STUB_SPECIMEN_CONSUMERS=*) consumers="${arg#*=}" ;;
      STUB_CLASS_PREFIX=*) prefix="${arg#*=}" ;;
    esac
  done
  STUB_SPECIMEN_CONSUMERS="$consumers" STUB_CLASS_PREFIX="$prefix" \
    python3 - "$LOG_DIR/database-contract-specimen.json" <<'PY'
import json, os, sys
prefix = os.environ.get("STUB_CLASS_PREFIX") or "qualreg-aws-us-east-1"
consumers = json.loads(os.environ.get("STUB_SPECIMEN_CONSUMERS") or "[]")
if not consumers:
    consumers = [{"namespace": "pluto-payments", "name": "orders-svc", "database": "app-db",
                  "credential": {"namespace": "pluto-payments", "name": prefix + "-dml-creds"},
                  "consuming_containers": ["orders-svc"]}]
json.dump({"digest": "0" * 64,
           "declaration": {"requested_target": "qualreg/aws/us-east-1",
                           "target": "qualreg/aws/us-east-1",
                           "workloads": consumers}}, open(sys.argv[1], "w"))
PY
}

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
  # The app phase reuses the database-contract pins `prepare` recorded; a scenario
  # that runs `app` alone seeds them exactly as `prepare` would.
  mkdir -p "$LOG_DIR"
  python3 - "$LOG_DIR/database-contract-pins.json" "qualreg/aws/us-east-1" <<'PY'
import json, sys
json.dump({"revision": "0" * 40,
           "bundle_digest": "0" * 64,
           "definition_digest": "0" * 64,
           "specimen_digest": "0" * 64,
           "requested_target": sys.argv[2],
           "target": sys.argv[2]}, open(sys.argv[1], "w"))
PY
  seed_database_specimen "$@"
  # The app phase reuses the digests `cloud` published into Sol's repositories; a scenario that
  # runs `app` alone seeds them exactly as a publish would have.
  stub_published_refs
  # The app phase runs against the real refusal sequence: the first deploy refuses at the
  # migration gate, `sol migrate apply` clears it, the second refuses the absent operator
  # secrets, and `sol secret set` clears that. Fresh markers per scenario keep one row's
  # progress from satisfying the next. Scoped to this invocation only -- a global export
  # would make later cloud/destroy scenarios refuse their deploys too.
  STUB_APP_MARKER_DIR="$TMP/$name.markers"
  rm -rf "$STUB_APP_MARKER_DIR"
  mkdir -p "$STUB_APP_MARKER_DIR"
  env PATH="$TMP/bin:$PATH" \
    WORKSPACE="$WORKSPACE" TARGET=qualreg/aws/us-east-1 ECR_REGISTRY="$ECR" \
    CLUSTER=test-cluster DEPLOY_ROLE_ARN=arn:aws:iam::1:role/deploy \
    CLUSTER_ACCESS_ROLE_ARN=arn:aws:iam::1:role/access \
    PUBLISHER_ROLE_ARN="$PUBLISHER_ROLE_ARN" \
    STUB_APP_REFUSALS=1 STUB_APP_MARKER_DIR="$STUB_APP_MARKER_DIR" \
    SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" \
    SOL_QUALIFICATION_CA="$TMP/bin/qualification_database_ca" PHASE_TIMEOUT=60 "$@" \
    "$ROOT/internal/qualification/aws/live-row.sh" app >"$TMP/$name.out" 2>&1
  echo "$?" >"$TMP/$name.rc"
}

seed_independent_capture() {
  local phase="$1"
  # Standalone observations/destruction represent an existing attempt with captured identities.
  if { [ "$phase" = verify ] || [ "$phase" = destroy ]; } && [ "${STUB_NO_CAPTURE:-0}" != 1 ]; then
    mkdir -p "$LOG_DIR"
    [ -e "$LOG_DIR/attempt.txt" ] ||
      printf 'attempt=%s\nrow=qualreg\ntarget=qualreg/aws/us-east-1\nstate_key=sol/qualreg/aws/us-east-1/cloud.tfstate\nissuer=%s\nclaim=%s\npromotion_eligible=%s\n' \
        "$ATTEMPT" "${SEED_ISSUER:-letsencrypt-staging}" "${SEED_CLAIM:-mechanism-only}" \
        "$(if [ "${SEED_CLAIM:-mechanism-only}" = production ]; then printf yes; else printf no; fi)" >"$LOG_DIR/attempt.txt"
    python3 - "$LOG_DIR/aws-pre-teardown-identities.json" "$INSTALL/candidate.json" "$ATTEMPT" <<'PYTHON'
import json, sys
candidate = json.load(open(sys.argv[2]))
identity = {key: candidate[key] for key in ("version", "revision", "bundle_sha256", "runner_image")}
json.dump({"schema": 1, "scope": {"cluster": "test-cluster", "region": "us-east-1",
    "account": "123456789012", "attempt": sys.argv[3], "target": "qualreg/aws/us-east-1",
    "state_key": "sol/qualreg/aws/us-east-1/cloud.tfstate", "candidate": identity},
    "resources": {key: [] for key in ("ebs-volume", "security-group", "oidc-provider", "elastic-ip", "load-balancer")}}, open(sys.argv[1], "w"))
PYTHON
  fi
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
  # `prepare` and `cloud` share one evidence directory: the built tags `prepare` writes are what
  # `cloud` publishes. KEEP_LOG_DIR keeps it across the two invocations.
  [ "${KEEP_LOG_DIR:-0}" = 1 ] || rm -rf "$LOG_DIR"
  rm -f "$TMP/credential-supplied"
  # Sol's repository marker belongs to the scenario that ran the apply; leaving it makes the
  # next scenario read this one's leftovers (issue #1415).
  rm -f "$TMP/ecr-sol-created"
  if [ "$phase" = cloud ] && [ "${SKIP_PREPARE:-0}" != 1 ]; then stub_prepare "$name"; fi
  # A scenario that runs `app` alone is running after a `cloud` that published the digests, so seed
  # them (the app phase reuses the cloud phase's and never publishes its own).
  if [ "$phase" = app ]; then
    stub_published_refs
    # The app phase reuses the database-contract pins `prepare` recorded.
    mkdir -p "$LOG_DIR"
    python3 - "$LOG_DIR/database-contract-pins.json" "qualreg/aws/us-east-1" <<'PY'
import json, sys
json.dump({"revision": "0" * 40,
           "bundle_digest": "0" * 64,
           "definition_digest": "0" * 64,
           "specimen_digest": "0" * 64,
           "requested_target": sys.argv[2],
           "target": sys.argv[2]}, open(sys.argv[1], "w"))
PY
    seed_database_specimen "$@"
  fi
  case "$phase" in
    prepare | cloud | app | destroy) STUB_ECR_LIFECYCLE=1 ;;
    *) STUB_ECR_LIFECYCLE=0 ;;
  esac
  export STUB_ECR_LIFECYCLE
  seed_independent_capture "$phase"
  if [ -n "${PRESEED_FOREIGN_ATTEMPT:-}" ]; then
    mkdir -p "$LOG_DIR"
    printf 'attempt=%s\n' "$PRESEED_FOREIGN_ATTEMPT" >"$LOG_DIR/attempt.txt"
  fi
  env PATH="$TMP/bin:$PATH" \
    WORKSPACE="$WORKSPACE" TARGET=qualreg/aws/us-east-1 ECR_REGISTRY="$ECR" \
    CLUSTER=test-cluster DEPLOY_ROLE_ARN=arn:aws:iam::1:role/deploy \
    CLUSTER_ACCESS_ROLE_ARN=arn:aws:iam::1:role/access \
    PUBLISHER_ROLE_ARN="$PUBLISHER_ROLE_ARN" \
    OPERATOR_ROLE_ARN=arn:aws:iam::1:role/operator QUALIFIER_ROLE=qualifier \
    SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" \
    SOL_QUALIFICATION_CA="$TMP/bin/qualification_database_ca" PHASE_TIMEOUT=60 "$@" \
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
  seed_independent_capture "$phase"
  env PATH="$TMP/bin:$PATH" \
    WORKSPACE="$WORKSPACE" TARGET=qualreg/aws/us-east-1 ECR_REGISTRY="$ECR" \
    CLUSTER=test-cluster DEPLOY_ROLE_ARN=arn:aws:iam::1:role/deploy \
    CLUSTER_ACCESS_ROLE_ARN=arn:aws:iam::1:role/access \
    PUBLISHER_ROLE_ARN="$PUBLISHER_ROLE_ARN" \
    OPERATOR_ROLE_ARN=arn:aws:iam::1:role/operator QUALIFIER_ROLE=qualifier \
    SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" \
    SOL_QUALIFICATION_CA="$TMP/bin/qualification_database_ca" PHASE_TIMEOUT=60 "$@" \
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
  [ "${KEEP_LOG_DIR:-0}" = 1 ] || rm -rf "$LOG_DIR"
  if [ "$phase" = cloud ] && [ "${SKIP_PREPARE:-0}" != 1 ]; then stub_prepare "$name"; fi
  STUB_ECR_LIFECYCLE=1
  export STUB_ECR_LIFECYCLE
  env PATH="$TMP/bin:$PATH" \
    WORKSPACE="$WORKSPACE" TARGET=qualreg/aws/us-east-1 ECR_REGISTRY="$ECR" \
    CLUSTER=test-cluster DEPLOY_ROLE_ARN=arn:aws:iam::1:role/deploy \
    CLUSTER_ACCESS_ROLE_ARN=arn:aws:iam::1:role/access \
    PUBLISHER_ROLE_ARN="$PUBLISHER_ROLE_ARN" \
    OPERATOR_ROLE_ARN=arn:aws:iam::1:role/operator QUALIFIER_ROLE=qualifier \
    SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" \
    SOL_QUALIFICATION_CA="$TMP/bin/qualification_database_ca" PHASE_TIMEOUT=60 "$@" \
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
KEEP_LOG_DIR=1 run_phase bootstrap-refused prepare
KEEP_LOG_DIR=1 run_phase bootstrap-refused cloud STUB_INSTALL_REFUSED=1
refused bootstrap-refused "an unresolved installation refuses the cloud phase"
has "and Sol owns durable reconciliation through the whole-target deploy" \
  "sol deploy qualreg/aws/us-east-1 --registry $ECR" "$TMP/bootstrap-refused.sol"
lacks "the cold deploy names no image references, because none are published yet" \
  "--image-ref" "$TMP/bootstrap-refused.sol"
lacks "no removed cloud subcommand is invoked" "cloud bootstrap" "$TMP/bootstrap-refused.sol"
lacks "and neither is the removed partial apply" "cloud apply" "$TMP/bootstrap-refused.sol"
[ ! -s "$TMP/bootstrap-refused.terraform" ] && ok "no direct Terraform operation runs" \
  || no "no direct Terraform operation runs" absent present

printf '\nscenario: the app phase runs the installed release bundle and hands Sol no runner\n'
run_row ok TRANSPORT=0
is "exit 0" "$(cat "$TMP/ok.rc")" "0"
has "the installed bundle is named in the transcript" \
  "sol-under-test: release $VERSION at $INSTALL" "$TMP/ok.out"
has "the app deploy names the digests the cloud phase published into Sol's repositories" \
  "--image-ref charge_svc=$ECR/pluto/charge-svc@sha256:" "$TMP/ok.sol"
lacks "and the app phase never builds or pushes an image itself" \
  "docker push" "$TMP/ok.docker"
lacks "but the harness publishes no migration runner" \
  "sol-migration-runner" "$TMP/ok.docker"
lacks "without being asked to publish or name a runner" \
  "migrate apply qualreg/aws/us-east-1 --registry" "$TMP/ok.sol"
has "the deploy resolves the workspace's own images from the target's registry" \
  "deploy qualreg/aws/us-east-1 --registry $ECR --image-ref checkout_svc=$ECR/pluto/checkout-svc@sha256:" "$TMP/ok.sol"
has "and pins every selected workload by digest, not a mutable tag" \
  "image-ref charge_svc=$ECR/pluto/charge-svc@sha256:" "$TMP/ok.sol"
lacks "the main deployment never uses a mutable workload tag" \
  "--image-tag $APP_TAG" "$TMP/ok.sol"
lacks "no operator POSTGRES_URL is set for the migration path" \
  "secret set POSTGRES_URL" "$TMP/ok.sol"
lacks "no undeclared unit secret is invented and supplied" \
  "SOL_API_KEY" "$TMP/ok.sol"
lacks "Kafka delivery never uses the application secret CLI" "secret set" "$TMP/ok.sol"
has "the delivery check is value-free" '"credential_values": "never read"' "$TMP/ok.logs/kafka-delivery.json"
has "and the transaction is its behavioral evidence" '"consumers"' "$TMP/ok.logs/kafka-delivery.json"
has "a real operator application-secret refusal is retained" "application_secret_refusal: declared SOL_API_KEY was absent" "$TMP/ok.logs/prerequisites.txt"
lacks "no removed --target/--domain surface is used" \
  "--domain" "$TMP/ok.sol"
has "the first deploy's migration-gate refusal is recognised, not treated as a failure" \
  "then refused to move workloads against an unapplied migration (expected)" "$TMP/ok.out"
lacks "no secret value is passed on a command line" \
  "testpass" "$TMP/ok.sol"
has "the observation records no credentials" \
  "never read" "$TMP/ok.logs/kafka-delivery.json"
has "the deploy's class-Secret delivery is asserted, not the operator's copy" \
  "database_delivery: qualreg-aws-us-east-1-ddl-creds@pluto-comms (migration Job, as the deploy declared it), qualreg-aws-us-east-1-dml-creds@pluto-payments (unit consumer orders-svc)" \
  "$TMP/ok.logs/prerequisites.txt"
has "the shared CA family owner ran the migration phase at the row's migration step" \
  "migration" "$TMP/ok.logs/ca-phases.txt"
has "and the application phase after the final deploy" \
  "application" "$TMP/ok.logs/ca-phases.txt"
has "and the report phase that re-reads durable evidence" \
  "report" "$TMP/ok.logs/ca-phases.txt"

# ADR 0007 reframed (previously #1604): the claim is causal -- the unit reads
# POSTGRES_URL from its DML class Secret, not the master. The assertion reads the
# Deployment's rendered `secretKeyRef`, so a unit that reads its own Secret is refused
# even when that Secret is otherwise empty. The old shape asserted the absence of the
# master copy in the unit Secret; that is a different claim (residue hygiene) and is
# not what this row checks.
printf '\nscenario: a consumer that reads POSTGRES_URL from its own Secret is refused (ADR 0007)\n'
run_row mastercopy TRANSPORT=0 STUB_POSTGRES_SECRET=orders-svc-secrets
refused mastercopy "an app phase whose consumer reads the master copy fails"
has "and names the Secret the unit actually reads" \
  "reads POSTGRES_URL from 'orders-svc-secrets', not the declared class Secret" "$TMP/mastercopy.out"
lacks "and the transaction never runs on a unit reading the administrative credential" \
  "the application transaction completed" "$TMP/mastercopy.out"

# The candidate's specimen declares the consumers. Here two are declared and only one
# receives its class Secret: the old "any one namespace carries it" loop passed this.
printf '\nscenario: a declared consumer that did not receive its class Secret is refused\n'
run_row partial TRANSPORT=0 STUB_DML_NAMESPACE=pluto-payments \
  STUB_SPECIMEN_CONSUMERS='[{"namespace":"pluto-payments","name":"orders-svc","database":"app-db","credential":{"namespace":"pluto-payments","name":"qualreg-aws-us-east-1-dml-creds"},"consuming_containers":["orders-svc"]},{"namespace":"pluto-comms","name":"fulfilment-worker","database":"app-db","credential":{"namespace":"pluto-comms","name":"qualreg-aws-us-east-1-dml-creds"},"consuming_containers":["fulfilment-worker"]}]'
refused partial "a partial delivery fails the app phase"
has "and names the consumer whose class Secret is absent" \
  "pluto-comms/fulfilment-worker as a database consumer, and qualreg-aws-us-east-1-dml-creds is absent from pluto-comms" \
  "$TMP/partial.out"

# A consumer outside the harness's old namespace map: the map never looked here, so a
# delivery that skipped it passed. The specimen names it, so the assertion reaches it.
printf '\nscenario: a declared consumer outside the old namespace map is still asserted\n'
run_row outside TRANSPORT=0 STUB_DML_NAMESPACE=pluto-payments \
  STUB_SPECIMEN_CONSUMERS='[{"namespace":"pluto-payments","name":"orders-svc","database":"app-db","credential":{"namespace":"pluto-payments","name":"qualreg-aws-us-east-1-dml-creds"},"consuming_containers":["orders-svc"]},{"namespace":"pluto-extra","name":"orders-svc","database":"app-db","credential":{"namespace":"pluto-extra","name":"qualreg-aws-us-east-1-dml-creds"},"consuming_containers":["orders-svc"]}]'
refused outside "a consumer outside the harness's map fails the app phase"
has "and names the namespace the harness map cannot see" \
  "pluto-extra/orders-svc as a database consumer" "$TMP/outside.out"

# The positive half: every declared consumer delivered and reading its class Secret.
printf '\nscenario: every declared consumer is asserted, not just the first\n'
run_row everyconsumer TRANSPORT=0 STUB_DML_NAMESPACE=pluto-payments \
  STUB_SPECIMEN_CONSUMERS='[{"namespace":"pluto-payments","name":"orders-svc","database":"app-db","credential":{"namespace":"pluto-payments","name":"qualreg-aws-us-east-1-dml-creds"},"consuming_containers":["orders-svc"]},{"namespace":"pluto-payments","name":"charge-svc","database":"app-db","credential":{"namespace":"pluto-payments","name":"qualreg-aws-us-east-1-dml-creds"},"consuming_containers":["charge-svc"]}]'
is "both consumers delivered from the class Secret" "$(cat "$TMP/everyconsumer.rc")" "0"
has "and the first consumer is recorded" "unit consumer orders-svc" "$TMP/everyconsumer.logs/prerequisites.txt"
has "and the second consumer too" "unit consumer charge-svc" "$TMP/everyconsumer.logs/prerequisites.txt"

printf '\nscenario: a database CA the deploy declared but did not write to the consumer is caught (#1481)\n'
run_row caabsent TRANSPORT=0 STUB_CA_ABSENT=1
refused caabsent "a CA absent from a consuming namespace fails the app phase"
has "and says the declared CA is absent from a consuming namespace" \
  "absent from a consuming namespace" "$TMP/caabsent.out"

printf '\nscenario: an unreadable CA is UNKNOWN, not absence (#1481)\n'
run_row caunreadable TRANSPORT=0 STUB_CA_UNREADABLE=1
refused caunreadable "an unreadable CA fails the phase rather than passing it"
has "and says the presence is UNKNOWN, not that it is absent" \
  "presence is UNKNOWN" "$TMP/caunreadable.out"
lacks "and never calls an unreadable CA absent" "declared CA ConfigMap absent" "$TMP/caunreadable.out"

printf '\nscenario: one workload of several missing the CA mount is caught (#1481)\n'
# The other selected workloads in the namespace mount the declared CA correctly; only `orders-svc`
# does not. A check that read the namespace's aggregated text would pass here.
run_row caunmounted TRANSPORT=0 STUB_CA_UNMOUNTED=orders-svc
refused caunmounted "a workload missing the mount fails even when its neighbours mount it"
has "and names the workload that does not mount it" \
  "pluto-payments/orders-svc does not mount the CA" "$TMP/caunmounted.out"
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
run_phase apptransport app TRANSPORT=1 STUB_DDL_NAMESPACE=sol-db-qualreg-aws-us-east-1 STUB_REQUIRE_SUBMISSION_AUTHORITY=1
is "exit 0" "$(cat "$TMP/apptransport.rc")" "0"
has "the delivery observation cites the transport transcript" \
  "transport-transaction.txt" "$TMP/apptransport.logs/kafka-delivery.json"
is "the transport is re-established after the final deploy" \
  "$(grep -c '^establish ' "$TMP/apptransport.establish")" "2"
python3 - "$TMP/apptransport.out" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
first = text.index("transport-establish")
second = text.index("transport-establish", first + 1)
deploy = text.index("app-deploy")
if not deploy < second:
    raise SystemExit("the second transport establishment is not after the final deploy")
PY
has "the transport is established before Sol moves the workload" \
  "establish test-cluster qualifier us-east-1 pluto-payments" "$TMP/apptransport.establish"
has "and it observes the database namespace the deploy declared for the migration Job" \
  "sol-db-qualreg-aws-us-east-1" "$TMP/apptransport.establish"
has "and the migration receipt is checked against the deploy identity that submitted it" \
  "assumed-role/deploy/session" "$TMP/apptransport.logs/ca-submission-authority.json"
lacks "never the qualifier that observed it" \
  "assumed-role/qualifier/session" "$TMP/apptransport.logs/ca-submission-authority.json"
has "while the observation authority stays the qualifier" \
  "assumed-role/qualifier/session" "$TMP/apptransport.logs/ca-authority.json"
has "and the transaction uses the qualifier's kubeconfig" \
  "KUBECONFIG_TRANSPORT=$TMP/apptransport.logs/kubeconfig-qualifier.yaml" "$TMP/apptransport.transport"

# #1597: the observer must read the transport's own transcript, not the app-phase
# transcript that the transport run never wrote.
has "the Kafka observer reads the transport transcript" \
  "transport-transaction.txt" "$TMP/apptransport.logs/kafka-delivery.json"
# #1601: the observation transport is re-established after the final deploy; one
# establishment before the migration and one after the deploy moves the workload.
is "the transport is established exactly twice" \
  "$(grep -c 'transport-establish' "$TMP/apptransport.out" 2>/dev/null || true)" "2"

lacks "never the deploy identity's kubeconfig" \
  "KUBECONFIG_TRANSPORT=$TMP/apptransport.logs/kubeconfig-deploy.yaml" "$TMP/apptransport.transport"
exists "and the application's own logs are captured for the record" "$TMP/apptransport.logs/app-svc.log"
exists "for the worker too" "$TMP/apptransport.logs/app-worker.log"
establish_at="$(grep -n 'transport-establish' "$TMP/apptransport.out" | head -1 | cut -d: -f1)"
transaction_at="$(grep -n 'app-transaction' "$TMP/apptransport.out" | head -1 | cut -d: -f1)"
gate_at="$(grep -n 'app-deploy-gate' "$TMP/apptransport.out" | head -1 | cut -d: -f1)"
migrate_at="$(grep -n 'app-deploy-migrate' "$TMP/apptransport.out" | head -1 | cut -d: -f1)"
if [ -n "$gate_at" ] && [ -n "$establish_at" ] && [ "$gate_at" -lt "$establish_at" ]; then
  ok "and establishment follows the deploy that creates the observation namespaces"
else
  no "and establishment follows the deploy that creates the observation namespaces" \
    "app-deploy-gate before transport-establish" \
    "gate at ${gate_at:-none}, establish at ${establish_at:-none}"
fi
if [ -n "$establish_at" ] && [ -n "$migrate_at" ] && [ "$establish_at" -lt "$migrate_at" ]; then
  ok "and establishment precedes the migration observation"
else
  no "and establishment precedes the migration observation" \
    "transport-establish before app-deploy-migrate" \
    "establish at ${establish_at:-none}, migrate at ${migrate_at:-none}"
fi
if [ -n "$establish_at" ] && [ -n "$transaction_at" ] && [ "$establish_at" -lt "$transaction_at" ]; then
  ok "and establishment precedes the transaction"
else
  no "and establishment precedes the transaction" "transport-establish before app-transaction" \
    "establish at ${establish_at:-none}, transaction at ${transaction_at:-none}"
fi

printf '\nscenario: a resumed app phase re-establishes the transport\n'
mkdir -p "$TMP/appresumed.logs"
printf 'stale\n' >"$TMP/appresumed.logs/kubeconfig-qualifier.yaml"
KEEP_LOG_DIR=1 run_phase appresumed app TRANSPORT=1
is "exit 0" "$(cat "$TMP/appresumed.rc")" "0"
has "a kubeconfig left by an earlier attempt does not suppress establishment" \
  "establish test-cluster qualifier us-east-1" "$TMP/appresumed.establish"

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

printf '\nscenario: the cloud phase runs the cold deploy, publishes into Sol'"'"'s repositories, then previews\n'
KEEP_LOG_DIR=1 run_phase cloudrun prepare
KEEP_LOG_DIR=1 run_phase cloudrun cloud
is "exit 0" "$(cat "$TMP/cloudrun.rc")" "0"
has "the cold deploy runs with no image references" \
  "deploy qualreg/aws/us-east-1 --registry $ECR [runner=" "$TMP/cloudrun.sol"
has "it reconciles the environment" \
  "The environment for qualreg/aws/us-east-1 is reconciled." "$TMP/cloudrun.logs/cloud-apply.log"
has "then refuses at the artifact gate, before any workload moves" \
  "Deployment incomplete." "$TMP/cloudrun.logs/cloud-apply.log"
has "the run publishes the built images into the repository Sol's deploy created" \
  "docker push $ECR/pluto/charge-svc:$APP_TAG" "$TMP/cloudrun.docker"
has "records the staging issuer in the attempt identity" \
  "issuer=letsencrypt-staging" "$TMP/cloudrun.logs/attempt.txt"
has "labels the attempt mechanism-only" "claim=mechanism-only" "$TMP/cloudrun.logs/attempt.txt"
has "and marks it not promotion-eligible" "promotion_eligible=no" "$TMP/cloudrun.logs/attempt.txt"
has "and the preview names the published digest and the row's var file" \
  "plan qualreg/aws/us-east-1 --var-file $ROOT/internal/qualification/aws/qual-aws-row.tfvars --image-ref checkout_svc=$ECR/pluto/checkout-svc@sha256:" \
  "$TMP/cloudrun.sol"
lacks "the removed partial cloud apply is never invoked" "cloud apply" "$TMP/cloudrun.sol"
lacks "and an unpublished artifact set prints no missing-file diagnostic" \
  "No such file or directory" "$TMP/cloudrun.out"
has "and it establishes the boundary from the cluster over every declared namespace" \
  "get namespace pluto-comms" "$TMP/cloudrun.kubectl"
has "including the domain of a unit that is neither the app nor the worker namespace" \
  "get namespace pluto-checkout" "$TMP/cloudrun.kubectl"
has "reading namespaces rather than a namespaced workload listing, which this identity cannot make" \
  "boundary_namespaces: pluto-checkout pluto-comms pluto-payments" \
  "$TMP/cloudrun.logs/cold-start-namespaces.txt"
if grep -q '" get deploy -n "' "$TMP/cloudrun.kubectl"; then
  no "and the unobservable deployment listing shape is gone from the phase" \
    "no namespaced deployment listing" "$(tr '\n' '|' <"$TMP/cloudrun.kubectl" | cut -c1-200)"
else
  ok "and the unobservable deployment listing shape is gone from the phase"
fi

printf '\nscenario: a fresh attempt records its staging issuer and mechanism-only claim\n'
KEEP_LOG_DIR=1 run_phase issuerfresh prepare
has "the fresh attempt records the staging issuer" \
  "issuer=letsencrypt-staging" "$TMP/issuerfresh.logs/attempt.txt"
has "and the mechanism-only claim" "claim=mechanism-only" "$TMP/issuerfresh.logs/attempt.txt"
has "and is not promotion-eligible" "promotion_eligible=no" "$TMP/issuerfresh.logs/attempt.txt"
has "from a fresh identity, not a continuation" "started=" "$TMP/issuerfresh.logs/attempt.txt"

printf '\nscenario: the promotion attempt declares production and is labelled accordingly\n'
sed -i 's/cluster_issuer: letsencrypt-staging/cluster_issuer: letsencrypt-production/' "$WORKSPACE/sol/environments.local.yml"
KEEP_LOG_DIR=1 CLUSTER_ISSUER=letsencrypt-production run_phase issuerprod prepare
has "records the production issuer" "issuer=letsencrypt-production" "$TMP/issuerprod.logs/attempt.txt"
has "labels the attempt production" "claim=production" "$TMP/issuerprod.logs/attempt.txt"
has "and marks it promotion-eligible" "promotion_eligible=yes" "$TMP/issuerprod.logs/attempt.txt"
sed -i 's/cluster_issuer: letsencrypt-production/cluster_issuer: letsencrypt-staging/' "$WORKSPACE/sol/environments.local.yml"

printf '\nscenario: a continuation preserves the original attempt labels\n'
SEED_ISSUER=letsencrypt-production SEED_CLAIM=production seed_attempt issuercont
sed -i 's/cluster_issuer: letsencrypt-staging/cluster_issuer: letsencrypt-production/' "$WORKSPACE/sol/environments.local.yml"
KEEP_LOG_DIR=1 CLUSTER_ISSUER=letsencrypt-production run_phase issuercont prepare
has "the continuation keeps the recorded issuer" \
  "issuer=letsencrypt-production" "$TMP/issuercont.logs/attempt.txt"
has "and the recorded claim" "claim=production" "$TMP/issuercont.logs/attempt.txt"
has "and the recorded promotion eligibility" \
  "promotion_eligible=yes" "$TMP/issuercont.logs/attempt.txt"
has "and records that it continued" "continued=" "$TMP/issuercont.logs/attempt.txt"
sed -i 's/cluster_issuer: letsencrypt-production/cluster_issuer: letsencrypt-staging/' "$WORKSPACE/sol/environments.local.yml"

printf '\nscenario: a continuation cannot adopt a different issuer\n'
SEED_ISSUER=letsencrypt-production SEED_CLAIM=production seed_attempt issuerdiff
KEEP_LOG_DIR=1 run_phase issuerdiff prepare
refused issuerdiff "a continuation that declares a different issuer is refused"
has "and names the new-ATTEMPT requirement" \
  "different issuer requires a new ATTEMPT" "$TMP/issuerdiff.out"

printf '\nscenario: an attempt without a declared issuer is refused\n'
sed -i '/^ *cluster_issuer: /d' "$WORKSPACE/sol/environments.local.yml"
KEEP_LOG_DIR=1 run_phase issuermissing prepare
refused issuermissing "an attempt whose target omits cluster_issuer is refused"
has "and says the target does not declare an issuer" \
  "does not declare cluster_issuer" "$TMP/issuermissing.out"
sed -i '/^ *cluster_name: test-cluster$/a\      cluster_issuer: letsencrypt-staging' "$WORKSPACE/sol/environments.local.yml"

printf '\nscenario: publication runs as the publisher identity, never the operator (SEC-011)\n'
KEEP_LOG_DIR=1 run_phase pubrun prepare
KEEP_LOG_DIR=1 run_phase pubrun cloud
is "exit 0" "$(cat "$TMP/pubrun.rc")" "0"
has "the run assumes the publisher role the operator names, on its own session" \
  "aws sts assume-role --role-arn $PUBLISHER_ROLE_ARN --role-session-name sol-qualification-publisher" \
  "$TMP/pubrun.aws"
has "and reads the session's identity back before it publishes" \
  "publisher_session_identity: arn:aws:sts::123456789012:assumed-role/sol-qual5-publisher/sol-qualification-publisher" \
  "$TMP/pubrun.logs/publisher-identity.txt"
has "recording the publisher role the run was given" \
  "publisher_role_arn: $PUBLISHER_ROLE_ARN" "$TMP/pubrun.logs/publisher-identity.txt"
lacks "and never the session's own values" "stub-secret" "$TMP/pubrun.logs/publisher-identity.txt"
has "ECR authentication runs under the publisher session with no operator profile in play" \
  "docker login --username AWS --password-stdin $ECR [aws_access_key_id=$PUBLISHER_ACCESS_KEY_STUB] [aws_profile=unset]" \
  "$TMP/pubrun.docker"
pushes="$(grep -c 'docker push .*pluto/' "$TMP/pubrun.docker")"
assumed="$(grep -c "docker push .*pluto/.* \[aws_access_key_id=$PUBLISHER_ACCESS_KEY_STUB\] \[aws_profile=unset\]" \
  "$TMP/pubrun.docker")"
if [ "$pushes" -ge 1 ] && [ "$pushes" = "$assumed" ]; then
  ok "and every published image is pushed under that session"
else
  no "and every published image is pushed under that session" \
    "each of the $pushes push line(s) carries the publisher session and no AWS_PROFILE" \
    "$(tr '\n' '|' <"$TMP/pubrun.docker" | cut -c1-200)"
fi
has "the digests the later deploys pin are still recorded" \
  "charge_svc=$ECR/pluto/charge-svc@sha256:" "$TMP/pubrun.logs/app-image-refs.txt"

printf '\nscenario: publication refuses rather than fall back to the operator credentials\n'
KEEP_LOG_DIR=1 run_phase nopublisher prepare PUBLISHER_ROLE_ARN=
KEEP_LOG_DIR=1 run_phase nopublisher cloud PUBLISHER_ROLE_ARN=
refused nopublisher "a run that names no publisher identity does not publish"
has "and says which input it needs" "PUBLISHER_ROLE_ARN" "$TMP/nopublisher.out"
if [ ! -s "$TMP/nopublisher.docker" ]; then
  ok "and logs no registry authentication or push at all"
else
  no "and logs no registry authentication or push at all" "an empty docker log" \
    "$(tr '\n' '|' <"$TMP/nopublisher.docker" | cut -c1-200)"
fi
if [ ! -s "$TMP/nopublisher.logs/app-image-refs.txt" ]; then
  ok "and records no published artifact"
else
  no "and records no published artifact" "an empty app-image-refs.txt" \
    "$(tr '\n' '|' <"$TMP/nopublisher.logs/app-image-refs.txt" | cut -c1-200)"
fi

printf '\nscenario: a publisher session that cannot be assumed stops the phase before any push\n'
KEEP_LOG_DIR=1 run_phase assumerefused prepare
KEEP_LOG_DIR=1 run_phase assumerefused cloud STUB_ASSUME_REFUSED=1
refused assumerefused "an unassumable publisher identity fails the phase"
has "and names the identity it could not assume" "$PUBLISHER_ROLE_ARN" "$TMP/assumerefused.out"
lacks "and pushes nothing" "push" "$TMP/assumerefused.docker"

printf '\nscenario: a session that answers as another identity stops the phase before any push\n'
KEEP_LOG_DIR=1 run_phase impersonated prepare
KEEP_LOG_DIR=1 run_phase impersonated cloud STUB_PUBLISHER_IMPERSONATES=1
refused impersonated "a publishing session that is not the publisher fails the phase"
has "and names what it answered as" "assumed-role/sol-qual5-operator/elsewhere" "$TMP/impersonated.out"
lacks "and pushes nothing" "push" "$TMP/impersonated.docker"
lacks "and records no publisher identity" "publisher_session_identity" \
  "$TMP/impersonated.logs/publisher-identity.txt"

printf '\nscenario: a cold deploy that left a declared namespace behind is caught (#1473, #1492)\n'
KEEP_LOG_DIR=1 run_phase coldworkload prepare
KEEP_LOG_DIR=1 run_phase coldworkload cloud STUB_COLD_NAMESPACE_PRESENT=pluto-payments
refused coldworkload "a namespace that exists before its artifacts were published fails the phase"
has "and names it as a namespace the deploy created, not as a workload it moved" \
  "the cold deploy created a declared namespace before its immutable artifacts were published" \
  "$TMP/coldworkload.out"
has "recording it as PRESENT rather than absent" \
  "cold-start-namespace: pluto-payments PRESENT" "$TMP/coldworkload.logs/cold-start-namespaces.txt"
has "and the boundary is UNKNOWN, never a pass" \
  "so the boundary is UNKNOWN, never a pass" "$TMP/coldworkload.out"

printf '\nscenario: a namespace holding a recorded release is caught the same way (#1473, #1492)\n'
KEEP_LOG_DIR=1 run_phase coldrelease prepare
KEEP_LOG_DIR=1 run_phase coldrelease cloud STUB_COLD_NAMESPACE_PRESENT=pluto-comms
refused coldrelease "a namespace that exists before its artifacts were published fails the phase"
has "recording the namespace the release would live in" \
  "cold-start-namespace: pluto-comms PRESENT" "$TMP/coldrelease.logs/cold-start-namespaces.txt"

printf '\nscenario: a namespace that cannot be read is UNKNOWN, never absence (#1492)\n'
KEEP_LOG_DIR=1 run_phase coldforbidden prepare
KEEP_LOG_DIR=1 run_phase coldforbidden cloud STUB_COLD_NAMESPACE_FORBIDDEN=pluto-comms
refused coldforbidden "a refused namespace read fails the phase"
has "recording the namespace as UNKNOWN" \
  "cold-start-namespace: pluto-comms UNKNOWN" "$TMP/coldforbidden.logs/cold-start-namespaces.txt"
lacks "and never as absence" \
  "cold-start-namespace: pluto-comms ABSENT" "$TMP/coldforbidden.logs/cold-start-namespaces.txt"

printf '\nscenario: a namespace read that timed out is UNKNOWN, never absence (#1492)\n'
KEEP_LOG_DIR=1 run_phase coldtimeout prepare
KEEP_LOG_DIR=1 run_phase coldtimeout cloud STUB_COLD_NAMESPACE_TIMEOUT=pluto-payments
refused coldtimeout "a timed-out namespace read fails the phase"
has "recording the timeout as UNKNOWN" \
  "cold-start-namespace: pluto-payments UNKNOWN" "$TMP/coldtimeout.logs/cold-start-namespaces.txt"

printf '\nscenario: an observation identity whose view cannot be established is not an absence (#1492)\n'
KEEP_LOG_DIR=1 run_phase coldnoview prepare
KEEP_LOG_DIR=1 run_phase coldnoview cloud STUB_NS_VIEW_UNREADABLE=1
refused coldnoview "a namespace view that cannot be established fails the phase"
has "and says which view could not be established" \
  "namespace view could not be established" "$TMP/coldnoview.out"
lacks "reading no declared namespace behind an unproven view" \
  "cold-start-namespace: pluto-payments ABSENT" "$TMP/coldnoview.logs/cold-start-namespaces.txt"

printf '\nscenario: a filtered namespace view cannot produce a false absence (#1492)\n'
KEEP_LOG_DIR=1 run_phase coldfiltered prepare
KEEP_LOG_DIR=1 run_phase coldfiltered cloud STUB_NS_VIEW_FILTERED=1
refused coldfiltered "a view that answers Forbidden for an absent name is not a boundary"
has "and says the view is filtered, so an existing namespace could answer the same way" \
  "the namespace view is" "$TMP/coldfiltered.out"
lacks "reading no declared namespace behind a filtered view" \
  "cold-start-namespace: pluto-payments ABSENT" "$TMP/coldfiltered.logs/cold-start-namespaces.txt"

printf '\nscenario: a selection that omits a consumer refuses rather than passing vacuously (#1492)\n'
# `prepare` runs with the row's own unit set, so the candidate-bound contract exists and the
# cloud phase's selection validation is what refuses: this is about the assertion's selection,
# not about a missing contract.
KEEP_LOG_DIR=1 run_phase coldselection prepare
KEEP_LOG_DIR=1 run_phase coldselection cloud APP_UNITS="orders_svc missing_svc"
refused coldselection "a namespace set that omits a selected consumer fails the phase"
has "and says which selection could not be covered" \
  "resolve to a candidate-bound directory" "$TMP/coldselection.out"
lacks "and reads no namespace behind an unvalidated selection" \
  "cold-start-namespace: pluto-payments ABSENT" "$TMP/coldselection.logs/cold-start-namespaces.txt"

printf '\nscenario: a credential that addresses another cluster never reads the boundary (#1492)\n'
KEEP_LOG_DIR=1 run_phase coldwrongcluster prepare
KEEP_LOG_DIR=1 run_phase coldwrongcluster cloud STUB_KUBECONFIG_STALE=1
refused coldwrongcluster "a kubeconfig for a replaced cluster fails the phase"
lacks "and no declared namespace is read through it" \
  "get namespace pluto-payments" "$TMP/coldwrongcluster.kubectl"

printf '\nscenario: the run owns no registry of its own, so the cleanup phase is gone\n'
run_phase cleanuprun cleanup
refused cleanuprun "cleanup is no longer a phase"
lacks "and the usage no longer offers it" "cleanup" "$TMP/cleanuprun.out"

printf '\nscenario: a cloud phase with nothing to publish still refuses at the artifact gate\n'
SKIP_PREPARE=1 run_phase noprep cloud
refused noprep "a run with no built images cannot preview the target"
has "the cold deploy still refuses at the artifact gate" \
  "Deployment incomplete." "$TMP/noprep.logs/cloud-apply.log"
has "and the phase says why it cannot go on: it has no candidate-bound contract to assert against" \
  "no candidate-bound build context" "$TMP/noprep.out"

printf '\nscenario: a run with a contract but nothing built still refuses before the preview\n'
KEEP_LOG_DIR=1 run_phase nodigests prepare
# `stub_prepare` runs in this shell for the cloud phase, so the flag that models a contract with
# no built image has to be in this shell's environment too.
export STUB_NO_BUILT_TAGS=1
KEEP_LOG_DIR=1 run_phase nodigests cloud STUB_NO_BUILT_TAGS=1
unset STUB_NO_BUILT_TAGS
refused nodigests "a run with no built images cannot preview the target"
has "and the phase says why it cannot go on" \
  "the run published no image digests" "$TMP/nodigests.out"

printf '\nscenario: prepare builds the run images and touches no provider state\n'
KEEP_LOG_DIR=1 run_phase prep prepare
is "exit 0" "$(cat "$TMP/prep.rc")" "0"
has "the images are built" "docker build" "$TMP/prep.docker"
has "tagged into the repository the target declares" \
  "$ECR/pluto/charge-svc:$APP_TAG" "$TMP/prep.logs/app-built-tags.txt"
lacks "and prepare creates no repository of its own" \
  "create-repository" "$TMP/prep.aws"
lacks "and prepare pushes nothing" "docker push" "$TMP/prep.docker"

printf '\nscenario: a plan that cannot resolve the run images fails, and is never skipped\n'
KEEP_LOG_DIR=1 run_phase coldplan prepare
KEEP_LOG_DIR=1 run_phase coldplan cloud STUB_COLD_PLAN=1
refused coldplan "a plan that cannot resolve the run images fails the phase"
has "the failure is reported, not skipped" "FAILED: cloud-plan" "$TMP/coldplan.out"
lacks "and the old cold-plan skip is gone" "cloud-plan: skipped" "$TMP/coldplan.out"
has "the cold deploy that provisions the target ran first" \
  "sol deploy qualreg/aws/us-east-1 --registry $ECR [runner=" "$TMP/coldplan.sol"
lacks "and no digest-named deploy runs behind a plan that could not resolve images" \
  "sol deploy qualreg/aws/us-east-1 --registry $ECR --image-ref" "$TMP/coldplan.sol"

printf '\nscenario: a failed managed credential initialization is never repaired by the harness\n'
KEEP_LOG_DIR=1 run_phase credential-boundary prepare
KEEP_LOG_DIR=1 run_phase credential-boundary cloud STUB_APPLY_CREDENTIAL_MISSING=1
refused credential-boundary "the product's credential failure blocks the row"
lacks "the observer never creates a broker Secret" "create secret generic redpanda-users" "$TMP/credential-boundary.kubectl"
lacks "and never supplies credentials through the CLI" "secret set" "$TMP/credential-boundary.sol"
is "the product is invoked once, without a seeding retry" "$(grep -c 'deploy qualreg/aws/us-east-1' "$TMP/credential-boundary.sol")" "1"

printf '\nscenario: teardown selects this attempt'"'"'s kubeconfig, not the calling shell'"'"'s state\n'
seed_attempt destroydest
printf 'apiVersion: v1\nclusters:\n- cluster:\n    server: %s\n  name: c\n' \
  "${STUB_CLUSTER_ENDPOINT:-https://10.0.0.1}" >"$TMP/destroydest.logs/kubeconfig-deploy.yaml"
printf 'apiVersion: v1\nclusters:\n- cluster:\n    server: https://192.0.2.9\n  name: other\n' \
  >"$TMP/someone-elses-cluster.yaml"
export KUBECONFIG="$TMP/someone-elses-cluster.yaml"
KEEP_LOG_DIR=1 run_phase destroydest destroy
unset KUBECONFIG
is "exit 0" "$(cat "$TMP/destroydest.rc")" "0"
has "the release runs against this attempt's own kubeconfig" \
  "[kubeconfig=$TMP/destroydest.logs/kubeconfig-deploy.yaml]" "$TMP/destroydest.sol"
lacks "and never the caller's" "[kubeconfig=$TMP/someone-elses-cluster.yaml]" "$TMP/destroydest.sol"
has "with the cluster present and the kubeconfig verified against its current endpoint" \
  "destroy_cluster: PRESENT" "$TMP/destroydest.logs/destroy-kubeconfig.txt"
has "and the release recorded as attempted" \
  "destroy_release_cleanup: attempted" "$TMP/destroydest.logs/destroy-kubeconfig.txt"

printf '\nscenario: an absent cluster skips the release and hands Sol no context at all\n'
seed_attempt destroydone
printf 'apiVersion: v1\nclusters:\n- cluster:\n    server: https://192.0.2.9\n  name: c\n' \
  >"$TMP/destroydone.logs/kubeconfig-deploy.yaml"
export KUBECONFIG="$TMP/someone-elses-cluster.yaml"
KEEP_LOG_DIR=1 run_phase destroydone destroy STUB_CLUSTER_ABSENT=1
unset KUBECONFIG
is "exit 0" "$(cat "$TMP/destroydone.rc")" "0"
has "the record says the cluster is positively absent" \
  "destroy_cluster: ABSENT" "$TMP/destroydone.logs/destroy-kubeconfig.txt"
has "and that the release was skipped, not blocked" \
  "destroy_release_cleanup: skipped" "$TMP/destroydone.logs/destroy-kubeconfig.txt"
has "so Sol is handed a config in which no context resolves" \
  "[kubeconfig=$TMP/destroydone.logs/kubeconfig-none.yaml]" "$TMP/destroydone.sol"
lacks "never a stale kubeconfig this attempt still holds" \
  "[kubeconfig=$TMP/destroydone.logs/kubeconfig-deploy.yaml]" "$TMP/destroydone.sol"
lacks "and never the caller's" "someone-elses" "$TMP/destroydone.sol"
has "and the destroy still runs" "destroy qualreg/aws/us-east-1 --apply" "$TMP/destroydone.sol"

printf '\nscenario: a cluster that cannot be read is UNKNOWN, never a skipped release\n'
seed_attempt destroyunknown
KEEP_LOG_DIR=1 run_phase destroyunknown destroy STUB_CLUSTER_UNREADABLE=1
is "exit 0" "$(cat "$TMP/destroyunknown.rc")" "0"
has "the record says the cluster read is UNKNOWN" \
  "destroy_cluster: UNKNOWN" "$TMP/destroyunknown.logs/destroy-kubeconfig.txt"
has "and that the release is blocked, not skipped" \
  "destroy_release_cleanup: blocked" "$TMP/destroyunknown.logs/destroy-kubeconfig.txt"
lacks "so it is never recorded as a skipped release" "destroy_release_cleanup: skipped" \
  "$TMP/destroyunknown.logs/destroy-kubeconfig.txt"
has "and Sol still runs the destroy" "destroy qualreg/aws/us-east-1 --apply" "$TMP/destroyunknown.sol"
has "whose verdict the independent inventory still decides" \
  "independent inventory (read-only)" "$TMP/destroyunknown.out"

printf '\nscenario: a kubeconfig that addresses a replaced cluster is rebuilt before the release\n'
seed_attempt destroyregen
printf 'apiVersion: v1\nclusters:\n- cluster:\n    server: https://9.9.9.9\n  name: c\n' \
  >"$TMP/destroyregen.logs/kubeconfig-deploy.yaml"
KEEP_LOG_DIR=1 run_phase destroyregen destroy
is "exit 0" "$(cat "$TMP/destroyregen.rc")" "0"
has "the attempt's kubeconfig is re-established at the cluster's current endpoint" \
  "aws eks update-kubeconfig --region us-east-1 --name test-cluster --alias test-cluster-deploy" \
  "$TMP/destroyregen.aws"
has "and the release is recorded as attempted" \
  "destroy_release_cleanup: attempted" "$TMP/destroyregen.logs/destroy-kubeconfig.txt"

printf '\nscenario: the prepare and cloud phases publish exactly the selected units\n'
KEEP_LOG_DIR=1 run_phase alphaunits prepare APP_UNITS="orders_svc fulfilment_worker"
# `run_phase` truncates the docker log per invocation, so keep the build phase's before the cloud
# phase's publish overwrites it.
cp "$TMP/alphaunits.docker" "$TMP/alphaunits.prepare-docker"
KEEP_LOG_DIR=1 SKIP_PREPARE=1 run_phase alphaunits cloud \
  APP_UNITS="orders_svc fulfilment_worker" SVC_UNIT=orders_svc WORKER_UNIT=fulfilment_worker
is "exit 0" "$(cat "$TMP/alphaunits.rc")" "0"
has "the service image is built from the selected unit" \
  "docker build -f $TMP/alphaunits.logs/app-build-context/app/payments/orders_svc/Dockerfile" \
  "$TMP/alphaunits.prepare-docker"
has "and from the candidate revision's context, not the checkout" \
  " $TMP/alphaunits.logs/app-build-context" "$TMP/alphaunits.prepare-docker"
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
lacks "and no unselected image is built" "charge-svc" "$TMP/alphaunits.prepare-docker"
has "and every selected unit is pinned by digest" \
  "--image-ref orders_svc=$ECR/pluto/orders-svc@sha256:" "$TMP/alphaunits.sol"

printf '\nscenario: a checkout that does not contain the candidate cannot qualify as the candidate\n'
# A divergent tree: the candidate is not in this history at all, so no amount of harness movement
# brings it forward from the candidate.
git -C "$WORKSPACE" checkout -q --orphan divergent
git -c user.name=qualification -c user.email=qualification@example.invalid \
  -C "$WORKSPACE" commit -q -m "a tree that does not contain the candidate"
run_phase divergentrev prepare APP_UNITS="orders_svc"
refused divergentrev "the run refuses a checkout that does not contain the candidate"
lacks "and builds nothing" "docker build" "$TMP/divergentrev.docker"
lacks "and records no candidate binding" "candidate_revision" "$TMP/divergentrev.logs/candidate-binding.txt"
has "and the refusal names the candidate it could not bind to" \
  "$CANDIDATE_REVISION" "$TMP/divergentrev.out"
git -C "$WORKSPACE" checkout -q "$CANDIDATE_REVISION"
git -C "$WORKSPACE" branch -q -D divergent

printf '\nscenario: a harness ahead of the candidate binds the candidate, and the application comes from the candidate\n'
git -c user.name=qualification -c user.email=qualification@example.invalid \
  -C "$WORKSPACE" commit -q --allow-empty -m "a harness fix cut after the candidate"
HARNESS_AHEAD="$(git -C "$WORKSPACE" rev-parse HEAD)"
run_phase aheadoftag prepare APP_UNITS="orders_svc"
is "the run exits 0" "$(cat "$TMP/aheadoftag.rc")" "0"
has "the build context is the candidate revision's, not the harness's" \
  "docker build -f $TMP/aheadoftag.logs/app-build-context/app/payments/orders_svc/Dockerfile" \
  "$TMP/aheadoftag.docker"
has "the binding names the candidate revision" \
  "candidate_revision: $CANDIDATE_REVISION" "$TMP/aheadoftag.logs/candidate-binding.txt"
has "and the harness revision it actually ran from" \
  "harness_revision: $HARNESS_AHEAD" "$TMP/aheadoftag.logs/candidate-binding.txt"
git -C "$WORKSPACE" reset -q --hard "$CANDIDATE_REVISION"

printf '\nscenario: a destroy refuses before touching anything when the credentials cannot be refreshed\n'
# The cheap check answers from cached role credentials and keeps succeeding; the destroy then dies
# at terraform init and leaves the substrate live (#1443).
run_phase stalec destroy STUB_CREDENTIALS_STALE=1
refused stalec "the destroy refuses when its credentials cannot be refreshed"
has "and the refusal names the re-authentication to run" \
  "aws sso login --profile" "$TMP/stalec.out"
lacks "and no Sol command is attempted" "destroy qualreg/aws/us-east-1 --apply" "$TMP/stalec.sol"
lacks "so no inventory is taken, and no teardown is recorded as attempted" \
  "teardown" "$TMP/stalec.logs/harness.log"

printf '\nscenario: the delivery assertion reads the location the deploy declared\n'
# The stub declares its class Secret in one namespace and, with this knob, refuses the read
# there. If the row were still asserting a baked-in namespace this would not be the failure it
# reports; the refusal naming the declared location is what shows it read the declaration.
run_row declaredabsent TRANSPORT=0 APP_UNITS="orders_svc" STUB_DDL_CREDS_ABSENT=1
refused declaredabsent "the row refuses when the class Secret is absent at the declared location"
has "and names the class Secret the deploy declared" \
  "qualreg-aws-us-east-1-ddl-creds" "$TMP/declaredabsent.out"
has "and the namespace the deploy declared" "pluto-comms" "$TMP/declaredabsent.out"

printf '\nscenario: the destroy phase survives a closed stdout reader and records the inventory\n'
run_phase_closed_stdout destroyclosed destroy
is "exit 0" "$(cat "$TMP/destroyclosed.rc")" "0"
has "the teardown still ran" "destroy qualreg/aws/us-east-1 --apply" "$TMP/destroyclosed.sol"
exists "the independent inventory is captured" "$TMP/destroyclosed.logs/aws-inventory.txt"
has "the harness writes its own narrative" "destroy returned success" \
  "$TMP/destroyclosed.logs/harness.log"

printf '\nscenario: SIGTERM during cloud tears down and records the independent inventory\n'
KEEP_LOG_DIR=1 run_phase cloudterm prepare
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
SKIP_PREPARE=1 run_phase occupied cloud STUB_STATE_PRESENT=1
refused occupied "an occupied state key is refused as a fresh target"
has "the refusal names the occupied state key" "already exists" "$TMP/occupied.out"
lacks "nothing is applied" "deploy qualreg/aws/us-east-1" "$TMP/occupied.sol"

printf '\nscenario: an evidence directory that belongs to another attempt is refused\n'
PRESEED_FOREIGN_ATTEMPT=another-attempt run_phase reused-dir cloud
refused reused-dir "an evidence directory for another attempt is refused"
has "the refusal names the attempt the directory belongs to" "another-attempt" "$TMP/reused-dir.out"
lacks "nothing is applied" "deploy qualreg/aws/us-east-1" "$TMP/reused-dir.sol"

printf '\nscenario: a credential for a replaced same-name cluster is refused\n'
KEEP_LOG_DIR=1 run_phase stale-endpoint prepare
KEEP_LOG_DIR=1 run_phase stale-endpoint cloud STUB_KUBECONFIG_STALE=1
refused stale-endpoint "a credential for a replaced cluster is refused"
has "the refusal names the endpoint binding" "not this cluster's current" "$TMP/stale-endpoint.out"

printf '\nscenario: the run identity reaches the provider inventory\n'
KEEP_LOG_DIR=1 run_phase identitycloud prepare
KEEP_LOG_DIR=1 run_phase identitycloud cloud
has "the fresh attempt records its identity" "state_key=sol/qualreg/aws/us-east-1/cloud.tfstate" \
  "$TMP/identitycloud.logs/attempt.txt"
run_phase identitydestroy destroy
has "and the inventory carries the attempt, target and state key" "attempt=$ATTEMPT" \
  "$TMP/identitydestroy.logs/aws-inventory.txt"
has "with the target" "target=qualreg/aws/us-east-1" "$TMP/identitydestroy.logs/aws-inventory.txt"
has "and the state key" "state_key=sol/qualreg/aws/us-east-1/cloud.tfstate" \
  "$TMP/identitydestroy.logs/aws-inventory.txt"

printf '\nscenario: missing history cannot be recreated by a destroy retry\n'
STUB_NO_CAPTURE=1 run_phase missing-capture destroy
refused missing-capture "missing independent history blocks destructive operations"
has "the missing evidence is named" 'identity capture is missing' "$TMP/missing-capture.out"
lacks "Sol destroy never runs" 'destroy qualreg/aws/us-east-1 --apply' "$TMP/missing-capture.sol"
STUB_NO_CAPTURE=1 run_phase missing-capture-verify verify
refused missing-capture-verify "missing history cannot certify final absence"
has "EBS absence remains unknown" 'ebs-volume: UNKNOWN' "$TMP/missing-capture-verify.logs/aws-inventory-verdict.txt"

printf '\nscenario: a failed independent recapture refuses before teardown\n'
run_phase capture-failure destroy STUB_INVENTORY_UNREADABLE=1
refused capture-failure "unreadable capture blocks destructive operations"
has "capture failure is reported" 'independent identity capture failed' "$TMP/capture-failure.out"
lacks "Sol destroy never runs after failed capture" 'destroy qualreg/aws/us-east-1 --apply' "$TMP/capture-failure.sol"

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
      cluster_issuer: letsencrypt-staging
      state_bucket: sol-qual-test-tfstate
YAML
run_phase no-tfvars cloud
refused no-tfvars "a target that names no terraform_var_file refuses the cloud phase"
has "and the refusal says why" "declares no terraform_var_file" "$TMP/no-tfvars.out"
lacks "and no Sol command runs" "sol " "$TMP/no-tfvars.sol"

printf '\nscenario: a spent attempt refuses a second application run\n'
mkdir -p "$TMP/spent.logs"
: >"$TMP/spent.logs/ca-migration.json"
KEEP_LOG_DIR=1 run_phase spent app
is "the second application run is refused" "$(cat "$TMP/spent.rc")" "2"
has "and names the diagnostic continuation" "live-row.sh resume" "$TMP/spent.out"
has "and the promotion-eligible path" "restart the whole row" "$TMP/spent.out"

printf '\nscenario: resume carries provisioning inputs into a diagnostic attempt\n'
mkdir -p "$TMP/resume-src/ca-evidence/members"
printf 'attempt=spent\nrow=qualreg\ntarget=qualreg/aws/us-east-1\nstate_key=sol/qualreg/aws/us-east-1/cloud.tfstate\ncluster=test-cluster\nissuer=letsencrypt-staging\nclaim=mechanism-only\npromotion_eligible=no\n' \
  >"$TMP/resume-src/attempt.txt"
printf 'checkout_svc=example/checkout@sha256:%064d\n' 0 >"$TMP/resume-src/app-image-refs.txt"
printf '{}\n' >"$TMP/resume-src/database-contract-pins.json"
: >"$TMP/resume-src/ca-evidence/members/spent-verdict"
run_phase resumed resume "RESUME_FROM=$TMP/resume-src" ATTEMPT=resumed-attempt
is "resume succeeds" "$(cat "$TMP/resumed.rc")" "0"
has "records the source attempt" "resumed_from=$TMP/resume-src" "$TMP/resumed.logs/attempt.txt"
has "marks the attempt diagnostic" "promotion_eligible=no" "$TMP/resumed.logs/attempt.txt"
has "carries the published images" "checkout_svc=" "$TMP/resumed.logs/app-image-refs.txt"
ls -la "$TMP/resumed.logs" >&2
ls -la "$TMP/resume-src" >&2
present "$TMP/resumed.logs/database-contract-pins.json" "carries the contract pins"
not_exists "never carries the spent CA evidence" "$TMP/resumed.logs/ca-evidence"
has "and says it is diagnostic" "diagnostic only, not promotion-eligible" "$TMP/resumed.out"

printf '\nscenario: promotion eligibility needs every required phase in one attempt\n'
run_phase ledger-missing verify
has "a verify without a phase ledger is not promotable" \
  "promotion_eligible=no" "$TMP/ledger-missing.logs/promotion-eligibility.txt"
has "and says the required phases are incomplete" \
  "required_phases_ok=no" "$TMP/ledger-missing.logs/promotion-eligibility.txt"
mkdir -p "$TMP/ledger-ok.logs"
printf 'phase=prepare exit=0 at=x\nphase=cloud exit=0 at=x\nphase=app exit=0 at=x\nphase=destroy exit=0 at=x\n' \
  >"$TMP/ledger-ok.logs/phase-verdicts.txt"
KEEP_LOG_DIR=1 SEED_ISSUER=letsencrypt-production SEED_CLAIM=production run_phase ledger-ok verify
has "a complete continuous sequence is promotable" \
  "promotion_eligible=yes" "$TMP/ledger-ok.logs/promotion-eligibility.txt"
has "and records the continuity" \
  "attempt_continuity=continuous" "$TMP/ledger-ok.logs/promotion-eligibility.txt"
printf 'phase=prepare exit=0 at=x\nphase=cloud exit=0 at=x\nphase=app exit=0 at=x\nphase=destroy exit=0 at=x\n' \
  >>"$TMP/resumed.logs/phase-verdicts.txt"
KEEP_LOG_DIR=1 run_phase resumed verify
KEEP_LOG_DIR=1 SEED_ISSUER=letsencrypt-staging SEED_CLAIM=mechanism-only run_phase ledger-staging verify
has "a staging attempt with a complete ledger is not promotion-eligible" \
  "promotion_eligible=no" "$TMP/ledger-staging.logs/promotion-eligibility.txt"
has "but its continuity is continuous, not resumed" \
  "attempt_continuity=continuous" "$TMP/ledger-staging.logs/promotion-eligibility.txt"
has "a resumed attempt is never promotable even with a complete ledger" \
  "promotion_eligible=no" "$TMP/resumed.logs/promotion-eligibility.txt"
has "and records the resumed continuity" \
  "attempt_continuity=resumed" "$TMP/resumed.logs/promotion-eligibility.txt"

printf '\nscenario: resume refuses a different specimen\n'
mkdir -p "$TMP/resume-foreign"
printf 'attempt=spent\nrow=qualreg\ntarget=other/aws/us-east-1\nstate_key=sol/other/aws/us-east-1/cloud.tfstate\ncluster=test-cluster\nissuer=letsencrypt-staging\nclaim=mechanism-only\npromotion_eligible=no\n' \
  >"$TMP/resume-foreign/attempt.txt"
printf 'x\n' >"$TMP/resume-foreign/app-image-refs.txt"
printf '{}\n' >"$TMP/resume-foreign/database-contract-pins.json"
run_phase resumed-foreign resume "RESUME_FROM=$TMP/resume-foreign" ATTEMPT=resumed-foreign
is "a different target is refused" "$(cat "$TMP/resumed-foreign.rc")" "2"
has "and names the mismatch" "resume:" "$TMP/resumed-foreign.out"

printf '\nscenario: independent Kafka credential observations fail closed\n'
for mode in denied missing; do
  run_row "kafka-delivery-$mode" TRANSPORT=0 "STUB_KAFKA_DELIVERY=$mode"
  refused "kafka-delivery-$mode" "$mode blocks the application qualification"
  lacks "no authority repair for $mode" "secret set" "$TMP/kafka-delivery-$mode.sol"
done
for mode in present pending permission malformed; do
  run_phase "kafka-secret-$mode" verify "STUB_KAFKA_SECRET=$mode"
  refused "kafka-secret-$mode" "$mode blocks independent verified absence"
done
run_row missing-secret-refusal TRANSPORT=0 STUB_SECRET_PROBE_RC=0
refused missing-secret-refusal "a falsely successful app-secret specimen blocks qualification"
is "the default row observes all four Kafka consumers" \
  "$(jq '.consumers | length' "$TMP/ok.logs/kafka-delivery.json")" "4"
lacks "credential values never enter state evidence" "qual-secret" "$TMP/ok.logs/state/cloud.tfstate"

printf '\n'
printf 'PASSED=%d FAILED=%d EXIT=%d\n' "$pass" "$fail" "$([ "$fail" -gt 0 ] && echo 1 || echo 0)"
if [ "$fail" -gt 0 ]; then
  printf 'live-row self-test: %s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi
printf 'live-row self-test: %s passed\n' "$pass"
