#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
export ATTEMPT="${ATTEMPT:-qual-self-test}"
export TARGET="${TARGET:-qual/gcp/us-central1}"

# Run the harness from a scratch root so the database-contract verifier can be a
# stub, exactly as the AWS row's test does. The harness resolves everything from
# its own location, so a copy of the files it sources is sufficient.
ROOT="$TMP/root"
mkdir -p "$ROOT/internal/qualification/gcp" "$ROOT/internal/qualification"
cp "$HERE/live-qual.sh" "$ROOT/internal/qualification/gcp/"
cp "$HERE/observer.py" "$ROOT/internal/qualification/gcp/"
cp "$HERE/qual-gcp.tfvars" "$ROOT/internal/qualification/gcp/"
cp -R "$HERE/fixtures" "$ROOT/internal/qualification/gcp/"
cp "$REPO/internal/qualification/sol-under-test.sh" "$ROOT/internal/qualification/"
cp "$REPO/internal/qualification/candidate-binding.sh" "$ROOT/internal/qualification/"
cp "$REPO/internal/qualification/attempt.sh" "$ROOT/internal/qualification/"
cp "$REPO/internal/qualification/kafka-delivery.py" "$ROOT/internal/qualification/"
cp "$REPO/internal/qualification/state-evidence.py" "$ROOT/internal/qualification/"
cp "$REPO/internal/qualification/application-secret-refusal.sh" "$ROOT/internal/qualification/"
mkdir -p "$ROOT/internal/qualification/fixtures"
cp -R "$REPO/internal/qualification/fixtures/application-secret-refusal" "$ROOT/internal/qualification/fixtures/"
cp "$REPO/internal/qualification/transaction.py" "$ROOT/internal/qualification/"
cat >"$ROOT/internal/qualification/database-contract-binding.py" <<'STUB'
#!/usr/bin/env python3
import json, sys
# Test stub: the row's pins recorder only needs the canonical shape.
print(json.dumps({
    "candidate": {"revision": "0" * 40, "bundle_sha256": "0" * 64},
    "definition": {"digest": "0" * 64},
    "specimen": {"digest": "0" * 64,
                 "declaration": {"requested_target": sys.argv[-1], "target": sys.argv[-1]}},
}))
STUB
git -C "$ROOT" init -q
git -C "$ROOT" add -A
git -c user.name=qualification -c user.email=qualification@example.invalid \
  -C "$ROOT" commit -qm "scratch qualification root"
HARNESS="$ROOT/internal/qualification/gcp/live-qual.sh"

SCRATCH_WS="$TMP/workspace"
TARGET_FILE="$SCRATCH_WS/sol/environments.local.yml"
mkdir -p "$SCRATCH_WS/sol" "$SCRATCH_WS/app/payments/orders_svc" \
  "$SCRATCH_WS/app/comms/fulfilment_worker" "$SCRATCH_WS/app/demo_ts/order_svc" \
  "$SCRATCH_WS/app/demo_ts/fulfillment_worker"
printf 'project: scratch\n' >"$SCRATCH_WS/sol.yml"
for unit in app/payments/orders_svc app/comms/fulfilment_worker app/demo_ts/order_svc \
  app/demo_ts/fulfillment_worker; do
  printf 'FROM scratch\n' >"$SCRATCH_WS/$unit/Dockerfile"
done
cat >"$SCRATCH_WS/pluto.opam" <<'OPAM'
opam-version: "2.0"
pin-depends: [
  [ "sol-svc.dev"           "git+https://github.com/sol-fab/sol.git#main" ]
  [ "kafka-eio-service.dev" "git+https://github.com/sol-fab/sol.git#main" ]
]
OPAM
# The workspace is the candidate's tree: a live run binds the application it
# builds to the revision the release names, and to no other (sol-fab/sol#1280).
git -C "$SCRATCH_WS" init -q
git -C "$SCRATCH_WS" add -A
git -c user.name=qualification -c user.email=qualification@example.invalid \
  -C "$SCRATCH_WS" commit -qm "the candidate revision"
CANDIDATE_REVISION="$(git -C "$SCRATCH_WS" rev-parse HEAD)"
cleanup() {
  rm -f "$TARGET_FILE"
  rmdir "$(dirname "$TARGET_FILE")" 2>/dev/null || true
  # Mutation copies live beside the harness so the script still resolves the
  # repository root from its own path; they are test artifacts, never tracked.
  rm -f "$HERE"/.live-qual-mutated-*.sh
  [ "${KEEP_TMP:-0}" = "1" ] && { echo "kept: $TMP"; return; }
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0
fail=0
ok() { printf '  [OK]   %s\n' "$1"; pass=$((pass + 1)); }
suite_environment() {
  printf 'suite: bash %s, cwd %s, scratch %s\n' "${BASH_VERSION:-?}" "$PWD" "$TMP"
  printf 'suite: stubs %s, harness %s\n' \
    "$(ls "$TMP"/bin 2>/dev/null | tr '\n' ',' )" "${HARNESS:-unset}"
  printf 'suite: probe channel %s\n' "${API_PROBE_LOG:-unset}"
}

dump_case_output() {
  local case_name="${CURRENT_CASE:-}"
  if [ -n "${DUMPED:-}" ]; then
    case "$DUMPED" in
      *" $case_name "*) return 0 ;;
    esac
  fi
  DUMPED="${DUMPED:-} $case_name "
  if [ -z "$case_name" ]; then
    return 0
  fi
  printf '           --- %s: rc %s, %s bytes of output ---\n' "$case_name" \
    "$(cat "$TMP/$case_name.rc" 2>/dev/null || echo '?')" \
    "$(wc -c <"$TMP/$case_name.out" 2>/dev/null || echo 0)"
  if [ -s "$TMP/$case_name.out" ]; then
    tail -12 "$TMP/$case_name.out" | sed 's/^/           /'
  else
    printf '           (the harness produced no output at all for this case)\n'
  fi
}
no() {
  printf '  [FAIL] %s\n           expected: %s\n           actual:   %s\n' "$1" "$2" "$3"
  fail=$((fail + 1))
  dump_case_output
}
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$3" "$2"; fi; }
has() { if grep -qF -- "$2" "$3"; then ok "$1"; else no "$1" "contains: $2" "$(tr '\n' '|' <"$3" | cut -c1-160)"; fi; }
lacks() { if grep -qF -- "$2" "$3"; then no "$1" "absent: $2" "present"; else ok "$1"; fi; }
present() { if [ -s "$1" ]; then ok "$2"; else no "$2" "present and non-empty" "missing: $1"; fi; }
not_exists() { if [ -e "$2" ]; then no "$1" "absent: $2" "present"; else ok "$1"; fi; }

suite_environment

mkdir -p "$TMP/bin"

VERSION="v0.1.0-alpha.7"
DIGEST64="$(printf 'a%.0s' $(seq 1 64))"
RUNNER="ghcr.io/example/sol-migration-runner:$VERSION@sha256:$DIGEST64"
# The setup image is a public image pinned by digest. It ships *inside* the release bundle
# (share/sol/<version>/setup-image), so the harness must not export SOL_SETUP_POSTGRES_IMAGE:
# an installed release refuses an ambient override (#1427).
SETUP="postgres@sha256:ca0bd484cb98bf4b24eb1010e73fb3fcbd6714d240fbc1a10eea5b7dbecb641d"
INSTALL="$TMP/install"

bundle() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/share/sol/$VERSION/platform/shared" \
    "$dir/share/sol/$VERSION/platform/cloud/gcp/bootstrap"
  printf '{\n  "components": {}\n}\n' >"$dir/share/sol/$VERSION/platform/shared/components.json"
  printf '%s\n' "$SETUP" >"$dir/share/sol/$VERSION/setup-image"
  cat >"$dir/bin/sol" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' "${STUB_SOL_VERSION:-v0.1.0-alpha.7}"
  exit 0
fi
printf 'sol %s [runner=%s] [setup=%s]\n' "$*" "${SOL_MIGRATION_RUNNER_IMAGE:-unset}" "${SOL_SETUP_POSTGRES_IMAGE:-unset}" >>"$ARGV_LOG"
if [ -n "${STUB_SOL_SLEEP:-}" ]; then sleep "$STUB_SOL_SLEEP"; fi
case "$1" in
  deploy)
    if [ "${2:-}" = probe/byo/qualification ]; then
      printf 'error: pluto-payments/secret-probe-secrets does not hold the required non-empty secret key(s): SOL_API_KEY.\n'
      exit "${STUB_SECRET_PROBE_RC:-1}"
    fi
    # The cloud phase's bootstrap deploy names a tag (no digest exists before the Artifact
    # Registry repositories do); the app phase's deploy pins digests.
    if printf '%s\n' "$*" | grep -qF -- '--image-tag'; then
      if [ "${STUB_INSTALL_REFUSED:-0}" = "1" ]; then
        printf 'bootstrap REFUSED: the durable root would be replaced\n'
        exit 1
      fi
      printf "  $ 'terraform' '-chdir=%s/sol/terraform/gcp-cluster-stub/platform/cloud/gcp/cluster' 'apply'\n" \
        "${XDG_DATA_HOME:-/tmp}"
      printf 'lifecycle phase: CloudBootstrap\n[terraform-apply] ok\n'
      if [ "${STUB_APPLY_FAILS_AT:-}" = "bootstrap" ]; then
        printf '[cloud-bootstrap-apply] FAILED (8.0s)\n'
        printf 'Error: the provider refused the bootstrap\n'
        exit "${STUB_APPLY_RC:-1}"
      fi
      printf 'lifecycle phase: PlatformInstalling\n'
      if [ "${STUB_APPLY_CREDENTIAL_MISSING:-0}" = "1" ] && [ ! -f "${TMP:-/tmp}/credential-supplied" ]; then
        printf 'the platform install cannot start: the operator-supplied Secret redpanda-users is absent from namespace redpanda.\n'
        printf 'Resolve that, then re-run the whole-target deploy to resume the install.\n'
        exit 1
      fi
      if [ "${STUB_APPLY_ERROR:-none}" = "already-exists" ]; then
      printf "  $ 'terraform' '-chdir=%s/sol/terraform/gcp-platform-stub/platform/cloud/gcp/platform' 'apply'\n" \
          "${XDG_DATA_HOME:-/tmp}"
        printf '[platform-prerequisites-apply] ok (12.0s)\n'
        printf '[platform-apply] FAILED (31.0s)\n'
        printf 'Error: rolebindings.rbac.authorization.k8s.io "sol-platform-provisioner" already exists\n'
      else
        printf "  $ 'terraform' '-chdir=%s/sol/terraform/gcp-platform-stub/platform/cloud/gcp/platform' 'apply'\\n" \
          "${XDG_DATA_HOME:-/tmp}"
        printf 'platform-apply ok\n'
      fi
      printf 'provisioner-bootstrap-access-remove ok\n'
      printf 'lifecycle phase: Ready\nDone.\n'
      if [ "${STUB_APPLY_RC:-0}" = "0" ] && [ "${STUB_APPLY_ERROR:-none}" != "already-exists" ]; then
        # The real deploy prints this from its database setup step (#1424).
        printf 'sol-database-identity: target=%s resource=app_db namespace=%s ddl-creds=%s authority=%s ca-configmap=%s\n' \
          "${STUB_CLASS_PREFIX:-qual-gcp-us-central1}" \
          "${STUB_DDL_NAMESPACE-pluto-comms}" \
          "${STUB_CLASS_PREFIX:-qual-gcp-us-central1}-ddl-creds" \
          "${STUB_CLASS_PREFIX:-qual-gcp-us-central1}-db-credentials" \
          "${STUB_CLASS_PREFIX:-qual-gcp-us-central1}-db-ca"
        printf 'The environment for %s is reconciled.\n' "$2"
      fi
      [ "${STUB_APPLY_RC:-0}" = "0" ]
    else
      # The app deploy pins digests and prints no terraform transcript, but the real one still
      # runs its database setup step, so it declares where it wrote (#1424).
      printf 'sol-database-identity: target=%s resource=app_db namespace=%s ddl-creds=%s authority=%s ca-configmap=%s\n' \
        "${STUB_CLASS_PREFIX:-qual-gcp-us-central1}" \
        "${STUB_DDL_NAMESPACE-pluto-comms}" \
        "${STUB_CLASS_PREFIX:-qual-gcp-us-central1}-ddl-creds" \
        "${STUB_CLASS_PREFIX:-qual-gcp-us-central1}-db-credentials" \
        "${STUB_CLASS_PREFIX:-qual-gcp-us-central1}-db-ca"
      [ "${STUB_DEPLOY_RC:-0}" = "0" ]
    fi
    ;;
  plan) [ "${STUB_CLOUD_PLAN_RC:-0}" = "0" ] ;;
  cloud)
    case "$2" in
      destroy) [ "${STUB_DESTROY_RC:-0}" = "0" ] ;;
      *) : ;;
    esac
    ;;
  destroy)
    # Keep the target the harness wrote, so a test can assert what `sol destroy`
    # actually read: the harness removes it after a verified teardown.
    if [ -n "${STUB_TARGET_COPY:-}" ] \
      && [ -f "${WORKSPACE:-}/sol/environments.local.yml" ]; then
      cp "${WORKSPACE}/sol/environments.local.yml" "$STUB_TARGET_COPY"
    fi
    [ "${STUB_DESTROY_RC:-0}" = "0" ]
    ;;
  *) : ;;
esac
STUB
  chmod +x "$dir/bin/sol"
}

bundle "$INSTALL"
printf '%s\n' "$RUNNER" >"$INSTALL/share/sol/$VERSION/migration-runner-image"
printf '%s\n' "$CANDIDATE_REVISION" >"$INSTALL/share/sol/$VERSION/REVISION"
# The candidate the install prefix belongs to: an install prefix alone cannot say
# which candidate it holds, so the run is told and verifies it (sol-fab/sol#1287).
printf '{"version":"%s","revision":"%s","runner_image":"%s"}\n' \
  "$VERSION" "$CANDIDATE_REVISION" "$RUNNER" >"$INSTALL/candidate.json"
printf '{"version":"%s","revision":"%s","runner_image":"%s"}\n' \
  "$VERSION" "0000000000000000000000000000000000000000" "$RUNNER" \
  >"$TMP/candidate-other-revision.json"

TAG_RUNNER_INSTALL="$TMP/install-tag-runner"
bundle "$TAG_RUNNER_INSTALL"
printf 'ghcr.io/example/sol-migration-runner:%s\n' "$VERSION" >"$TAG_RUNNER_INSTALL/share/sol/$VERSION/migration-runner-image"

cat >"$TMP/bin/terraform" <<'STUB'
#!/usr/bin/env bash
printf 'terraform %s\n' "$*" >>"$ARGV_LOG"
if [ "${STUB_PLAN_DESTROYS:-0}" = "1" ]; then
  for a in "$@"; do
    [ "$a" = "plan" ] && exit 2
    [ "$a" = "show" ] && { printf '# google_storage_bucket.state must be replaced\n'; exit 0; }
  done
fi
for a in "$@"; do [ "$a" = "plan" ] && exit "${STUB_PLAN_RC:-0}"; done
exit 0
STUB

cat >"$TMP/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "auth configure-docker") exit 0 ;;
esac
if [ "${STUB_DESCRIBE_EMPTY:-0}" = "1" ]; then
  case "$*" in
    *"container clusters describe"*) exit 0 ;;
  esac
fi
gcloud_log_to="$ARGV_LOG"
case " $* " in *"value(endpoint)"*) gcloud_log_to="${API_PROBE_LOG:-$ARGV_LOG}" ;; esac
printf "gcloud %s" "$*" >>"$gcloud_log_to"; printf "\n" >>"$gcloud_log_to"
case "$*" in
  *"auth list"*)
    if [ "${STUB_CALLER_UNKNOWN:-0}" = "1" ]; then
      printf 'ERROR: (gcloud.auth.list) There is no active account\n' >&2
      exit 1
    fi
    printf 'test@example.com\n'; exit 0 ;;
  # A project the run cannot read as itself is a scope failure, not the absence
  # of every resource class inside it.
  *"projects describe"*)
    if [ "${STUB_PROJECT_UNKNOWN:-0}" = "1" ]; then
      printf 'ERROR: (gcloud.projects.describe) NOT_FOUND: Project sol-qualification was not found.\n' >&2
      exit 1
    fi
    printf 'sol-qualification\n'; exit 0 ;;
  *"projects get-iam-policy"*)
    printf '{"bindings":[]}\n'; exit 0 ;;
  *"storage objects describe"*)
    if [ "${STUB_STATE_PRESENT:-0}" = "1" ]; then printf 'gs://sol-qualification-tfstate/state\n'; exit 0; fi
    printf 'ERROR: (gcloud.storage.objects.describe) NOT_FOUND: The specified object was not found.\n' >&2
    exit 1 ;;
  *"storage buckets describe"*)
    [ "${STUB_BUCKET_ABSENT:-0}" = 1 ] && exit 1
    printf "sol-qualification-tfstate\n"; exit 0 ;;
  *"storage cat"*)
    if [ "${STUB_STATE_UNREADABLE:-0}" = "1" ]; then
      printf "ERROR: (gcloud) The caller does not have permission\n" >&2; exit 1
    fi
    if [ "${STUB_STATE_WITH_OUTPUTS:-0}" = "1" ]; then
      printf '{"version":4,"serial":7,"resources":[],"outputs":{"kafka_authority":{"value":{"secret_name":"sol-kafka-test-cluster","reference":"projects/sol-qualification/secrets/sol-kafka-test-cluster","username":"sol-workloads","mechanism":"SCRAM-SHA-256"}},"postgres_url":{"value":"postgresql://postgres:qual-secret@10.172.0.3/app","type":"string","sensitive":true}}}\n'
      exit 0
    fi
    printf '{"version":4,"serial":7,"resources":[]}\n'; exit 0 ;;
  *"compute regions describe"*"value(name)"*|*"value(name)"*"compute regions describe"*)
    if [ "${STUB_REGION_UNKNOWN:-0}" = "1" ]; then
      printf 'ERROR: (gcloud.compute.regions.describe) NOT_FOUND: The resource us-central1 was not found\n' >&2
      exit 1
    fi
    printf 'us-central1\n'; exit 0 ;;
  *"compute regions describe"*"--format=json"*|*"--format=json"*"compute regions describe"*)
    printf '{"name":"us-central1","quotas":[{"metric":"CPUS","limit":200.0,"usage":22.0},'
    printf '{"metric":"DISKS_TOTAL_GB","limit":4096.0,"usage":0.0},'
    printf '{"metric":"SSD_TOTAL_GB","limit":%s,"usage":%s}]}\n' \
      "${STUB_SSD_LIMIT:-500}" "${STUB_SSD_USAGE:-100}"
    exit 0 ;;
  *"dns managed-zones list"*)     printf '[{"name":"qual-gcp-sol-fab-dev","dnsName":"qual-gcp.sol-fab.dev.","visibility":"public"}]\n'; exit 0 ;;
  *"dns managed-zones describe"*) printf "qual-gcp-sol-fab-dev\n"; exit 0 ;;
  *"dns managed-zones"*)        printf "qual-gcp-sol-fab-dev\n"; exit 0 ;;
  *"compute addresses list"*)
    if [ "${STUB_FILTER_WARNING:-0}" = "1" ]; then
      printf "WARNING: The following filter keys were not present in any resource : name\n" >&2
    fi
    if [ "${STUB_ADDRESS_RESIDUE:-0}" = "1" ]; then
      printf '[{"name":"sol-qualification-residue","address":"203.0.113.9"}]\n'; exit 0
    fi
    if [ "${STUB_LB_ADDRESS:-0}" = "1" ]; then
      # GKE names an L4 forwarding rule's address `a<hex>`: it carries no
      # cluster name and is attributable only by the address the run observed.
      printf '[{"name":"a1b2c3d4","address":"34.0.0.1"}]\n'; exit 0
    fi
    printf '[]\n'; exit 0 ;;
  *"compute forwarding-rules list"*)
    if [ "${STUB_FORWARDING_WRONG_SHAPE:-0}" = "1" ]; then
      # A document whose attribution fields are not the ones this class reads.
      # It must not decode to "nothing attributable".
      printf '[{"nickname":"a1b2c3d4"}]\n'; exit 0
    fi
    if [ "${STUB_FORWARDING_RESIDUE:-0}" = "1" ]; then
      printf '[{"name":"k8s2-residue","IPAddress":"34.0.0.1","network":"https://www.googleapis.com/compute/v1/projects/sol-qualification/global/networks/test-cluster"}]\n'; exit 0
    fi
    if [ "${STUB_LB_ADDRESS:-0}" = "1" ]; then
      printf '[{"name":"a1b2c3d4","IPAddress":"34.0.0.1","network":"https://www.googleapis.com/compute/v1/projects/sol-qualification/global/networks/other"}]\n'; exit 0
    fi
    printf '[]\n'; exit 0 ;;
  *"compute routers describe"*)
    if [ "${STUB_ROUTER_PRESENT:-0}" = "1" ]; then
      printf 'test-cluster-router\n'; exit 0
    fi
    printf "ERROR: (gcloud.compute.routers.describe) NOT_FOUND: The resource 'projects/sol-qualification/regions/us-central1/routers/test-cluster-router' was not found\n" >&2
    exit 1 ;;
  *"compute routers nats describe"*)
    if [ "${STUB_NAT_PARENT_MISSING:-0}" = "1" ]; then
      printf "ERROR: (gcloud.compute.routers.nats.describe) NOT_FOUND: The resource 'projects/sol-qualification/regions/us-central1/routers/test-cluster-router' was not found\n" >&2
      exit 1
    fi
    if [ "${STUB_NAT_AMBIGUOUS:-0}" = "1" ]; then
      printf "ERROR: (gcloud.compute.routers.nats.describe) NOT_FOUND: The resource 'projects/sol-qualification/regions/us-central1/routers/test-cluster-router/status' was not found while reading the child\n" >&2
      exit 1
    fi
    printf 'ERROR: (gcloud.compute.routers.nats.describe) NOT_FOUND: The resource test-cluster-nat was not found\n' >&2
    exit 1 ;;
  *"compute networks peerings list"*)
    if [ "${STUB_PEERING_RESIDUE:-0}" = "1" ]; then
      printf '[{"name":"servicenetworking-google","network":"https://www.googleapis.com/compute/v1/projects/sol-qualification/global/networks/test-cluster"}]\n'; exit 0
    fi
    printf '[]\n'; exit 0 ;;
  *"compute regions describe"*)
    if [ "${STUB_QUOTA_GARBAGE:-0}" = "1" ]; then printf "not a quota document\n"; exit 0; fi
    if [ "${STUB_QUOTA_BUSY:-0}" = "1" ]; then printf "CPUS;IN_USE_ADDRESSES;SSD_TOTAL_GB;DISKS_TOTAL_GB;INSTANCES,4;0;0;0;1\n"; exit 0; fi
    printf "CPUS;IN_USE_ADDRESSES;SSD_TOTAL_GB;DISKS_TOTAL_GB;INSTANCES,0;0;0;0;0\n"; exit 0 ;;
  # A GKE CSI disk is named `pvc-<uuid>`, so it is attributable only by the
  # GKE cluster label; the harness enumerates the class and applies the label
  # itself rather than asking the provider to filter.
  *"compute disks list"*)
    if [ -n "${STUB_DISK_NAME:-}" ]; then
      printf '[{"name":"%s","labels":{}}]\n' "$STUB_DISK_NAME"; exit 0
    fi
    if [ "${STUB_DISK_RESIDUE:-0}" = "1" ]; then
      printf '[{"name":"pvc-residue","labels":{"goog-k8s-cluster-name":"%s"}}]\n' "$CLUSTER"; exit 0
    fi
    if [ "${STUB_DISK_HASHED:-0}" = "1" ]; then
      printf '[{"name":"pvc-unrelated","labels":{}}]\n'; exit 0
    fi
    printf '[]\n'; exit 0 ;;
  *"compute instances list"*|*"compute snapshots list"*)
    case "$*" in
      *"--format=json"*)
        if [ "${STUB_RESIDUE_OWNER:-0}" = "1" ]; then
          printf '[{"name":"residue-owner"}]\n'
        else
          printf '[]\n'
        fi
        exit 0 ;;
    esac
    exit 0 ;;
  *"sql instances list"*)
    case "$*" in
      *"--format=json"*) printf '[]\n'; exit 0 ;;
    esac
    exit 0 ;;
  *"compute networks list"*)    printf "default\n"; exit 0 ;;
  *"secrets versions access"*)
    if [ "${STUB_KAFKA_DELIVERY:-ok}" = denied ]; then printf 'denied' >&2; exit 1; fi
    printf testpass; exit 0 ;;
  *"secrets list"*"--format=json"*)
    case "${STUB_KAFKA_SECRET:-absent}" in
      present) printf '[{"name":"projects/123/secrets/sol-kafka-test-cluster"}]\n' ;;
      disabled) printf '[{"name":"projects/123/secrets/sol-kafka-test-cluster","labels":{"version-state":"DISABLED"}}]\n' ;;
      permission) printf 'PERMISSION_DENIED: secret metadata forbidden\n' >&2; exit 1 ;;
      malformed) printf '{}\n' ;;
      wrong-shape) printf '[{"name":null}]\n' ;;
      unrelated) printf '[{"name":"projects/123/secrets/sol-kafka-another-cluster"}]\n' ;;
      *) printf '[]\n' ;;
    esac
    exit 0 ;;
  *"secrets list"*)
    if [ "${STUB_SECRETS_LIST_FAIL:-0}" = "1" ]; then
      printf 'ERROR: (gcloud.secrets.list) PERMISSION_DENIED: Permission denied\n' >&2
      exit 1
    fi
    [ "${STUB_SECRETS_PRESENT:-0}" = "1" ] && printf 'projects/123/secrets/sol-alpha-stripe\n'
    exit 0 ;;
  *"secrets get-iam-policy"*)
    if [ "${STUB_SECRET_POLICY_FAIL:-0}" = "1" ]; then
      printf 'ERROR: (gcloud.secrets.get-iam-policy) PERMISSION_DENIED\n' >&2
      exit 1
    fi
    printf '{"bindings":[{"role":"roles/secretmanager.secretAccessor","members":["serviceAccount:sol-qualification.svc.id.goog[pluto-payments/charge-svc]"]}]}\n'
    exit 0 ;;
esac
case "$*" in
  *"iam service-accounts describe"*)
    case "$*" in
      *"$STUB_PROVISIONER_SA"*)
        if [ "${STUB_SA_ACTIVE_PROVISIONER:-0}" = "1" ]; then
          printf "%s\n" "$STUB_PROVISIONER_SA"; exit 0
        fi
        printf "ERROR: (gcloud.iam.service-accounts.describe) PERMISSION_DENIED: Permission 'iam.serviceAccounts.get' denied on resource (or it may not exist). This command is authenticated as test@example.com which is the active account specified by the [core/account] property.\n" >&2
        exit 1 ;;
    esac ;;
  *"iam service-accounts list"*)
    if [ "${STUB_SA_LIST_FAIL:-0}" = "1" ]; then
      printf "ERROR: (gcloud.iam.service-accounts.list) PERMISSION_DENIED: Permission 'iam.serviceAccounts.list' denied on resource.\n" >&2
      exit 1
    fi
    printf "819835583654-compute@developer.gserviceaccount.com\n"
    [ "${STUB_SA_ACTIVE_PROVISIONER:-0}" = "1" ] && printf "%s\n" "$STUB_PROVISIONER_SA"
    exit 0 ;;
  *"iam service-accounts get-iam-policy"*)
    case "${STUB_SA_POLICY:-denied}" in
      binding) printf '{"bindings":[{"role":"roles/iam.serviceAccountTokenCreator","members":["user:test@example.com"]}]}\n'; exit 0 ;;
      empty)   printf '{"bindings":[]}\n'; exit 0 ;;
      *)
        printf "ERROR: (gcloud.iam.service-accounts.get-iam-policy) PERMISSION_DENIED: Permission 'iam.serviceAccounts.getIamPolicy' denied on resource (or it may not exist). This command is authenticated as test@example.com which is the active account specified by the [core/account] property.\n" >&2
        exit 1 ;;
    esac ;;
  *"iam roles describe"*)
    case "${STUB_ROLE_STATE:-deleted}" in
      deleted)  printf "projects/sol-qualification/roles/sol_test_cluster_access\tTrue\n"; exit 0 ;;
      active)   printf "projects/sol-qualification/roles/sol_test_cluster_access\tFalse\n"; exit 0 ;;
      notfound) printf "ERROR: (gcloud.iam.roles.describe) NOT_FOUND: The role named projects/sol-qualification/roles/sol_test_cluster_access was not found.\n" >&2; exit 1 ;;
      *)        printf "ERROR: (gcloud.iam.roles.describe) PERMISSION_DENIED: The caller does not have permission\n" >&2; exit 1 ;;
    esac ;;
esac
case "$*" in
  *"container clusters get-credentials"*)
    if [ -n "${STUB_GET_CREDENTIALS_RC:-}" ]; then
      printf 'ERROR: (gcloud.container.clusters.get-credentials) ResponseError: code=403\n' >&2
      exit "$STUB_GET_CREDENTIALS_RC"
    fi
    if [ "${STUB_CLUSTER_EXISTS:-0}" != "1" ] && [ "${STUB_TARGET_PRESENT:-0}" != "1" ]; then
      printf 'ERROR: (gcloud.container.clusters.get-credentials) NOT_FOUND: the cluster does not exist\n' >&2
      exit 1
    fi
    kc="${KUBECONFIG:-$HOME/.kube/config}"
    sed "s/sol-qual-gcp-15g/$CLUSTER/g" "$STUB_KUBECONFIG_FIXTURE" >"$kc" 2>/dev/null || true
    printf 'kubeconfig entry generated for %s.\n' "$CLUSTER"
    exit 0 ;;
esac
if [ "${STUB_CLUSTER_EXISTS:-0}" = "1" ]; then
  case "$*" in
  *"value(status)"*)
    if [ -n "${STUB_STATUS_FAILS_N:-}" ]; then
      cnt_file="$TMP/status-polls"
      n="$(cat "$cnt_file" 2>/dev/null || echo 0)"
      n=$((n + 1))
      echo "$n" >"$cnt_file"
      if [ "$n" -le "$STUB_STATUS_FAILS_N" ]; then
        printf 'ERROR: (gcloud.container.clusters.describe) NOT_FOUND: Resource not found\n' >&2
        exit 1
      fi
    fi
    printf "%s\n" "${STUB_CLUSTER_STATUS:-RUNNING}"
    exit 0 ;;
  *"value(endpoint)"*) printf "%s\n" "${STUB_ENDPOINT_REPORTED:-34.0.0.1}"; exit 0 ;;
    *"container clusters describe"*"--format=json"*)
      if [ "${STUB_CLUSTER_JSON_FAIL:-0}" = "1" ]; then
        printf 'ERROR: (gcloud.container.clusters.describe) PERMISSION_DENIED\n' >&2
        exit 1
      fi
      printf '{"secretManagerConfig":{"enabled":%s,"rotationConfig":{"rotationInterval":"%s"}},"workloadIdentityConfig":{"workloadPool":"%s"}}\n' \
        "${STUB_SM_ENABLED:-true}" "${STUB_SM_INTERVAL:-2m}" \
        "${STUB_WORKLOAD_POOL:-sol-qualification.svc.id.goog}"
      exit 0 ;;
    *"container clusters describe"*) printf "test-cluster\n"; exit 0 ;;
    *"container clusters get-credentials"*)
      if [ -n "${STUB_GET_CREDENTIALS_RC:-}" ]; then
        printf 'ERROR: (gcloud.container.clusters.get-credentials) ResponseError: code=403\n' >&2
        exit "$STUB_GET_CREDENTIALS_RC"
      fi
      kc="${KUBECONFIG:-$HOME/.kube/config}"
      sed "s/sol-qual-gcp-15g/$CLUSTER/g" "$STUB_KUBECONFIG_FIXTURE" >"$kc" 2>/dev/null || true
      printf 'kubeconfig entry generated for %s.\n' "$CLUSTER"
      exit 0 ;;
  esac
fi
if [ "${STUB_TARGET_PRESENT:-0}" = "1" ]; then
  case "$*" in *list* | *describe*) printf "test-cluster\n"; exit 0 ;; esac
fi
case "${STUB_PROBE_MODE:-notfound}" in
  permission)
    printf 'ERROR: (gcloud.projects.get-iam-policy) [lbendtlynielsen@gmail.com] does not have permission to access projects instance [cloud-sdk-dev:getIamPolicy] (or it may not exist): The caller does not have permission. This command is authenticated as lbendtlynielsen@gmail.com which is the active account specified by the [core/account] property\n' >&2
    exit 1 ;;
  transport)
    printf "ERROR: gcloud crashed (ConnectionError): HTTPSConnectionPool(host='127.0.0.1', port=1): Max retries exceeded with url: /compute/v1/projects/sol-qualification/global/networks?alt=json&maxResults=500 (Caused by NewConnectionError(\"HTTPSConnection(host='127.0.0.1', port=1): Failed to establish a new connection: [Errno 111] Connection refused\"))\n" >&2
    exit 1 ;;
  invalid)
    printf 'ERROR: (gcloud.iam.roles.describe) INVALID_ARGUMENT: The role name must be in the form "roles/{role}", "organizations/{organization_id}/roles/{role}", or "projects/{project_id}/roles/{role}".\n' >&2
    exit 1 ;;
  permission-not-found)
    # A denied read that happens to contain 404 and "was not found": the
    # resource's own absence is not what this answer establishes.
    printf 'ERROR: (gcloud.compute.networks.describe) PERMISSION_DENIED: Permission denied on resource; 404 or it may not exist: The resource projects/sol-qualification/global/networks/test-cluster was not found\n' >&2
    exit 1 ;;
  compute-notfound)
    printf "ERROR: (gcloud.compute.networks.describe) Could not fetch resource:\n - The resource 'projects/sol-qualification/global/networks/test-cluster' was not found\n" >&2
    exit 1 ;;
  *)
    printf 'ERROR: (gcloud.iam.service-accounts.describe) NOT_FOUND: Unknown service account. This command is authenticated as lbendtlynielsen@gmail.com which is the active account specified by the [core/account] property\n' >&2
    exit 1 ;;
esac
STUB

cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  *" "*)
    printf 'error: unknown command "%s" for "kubectl"\n' "$1" >&2
    exit 1
    ;;
esac
if [ -n "${STUB_KUBE_READ_RC:-}" ]; then
  case " $* " in
    *" get "*)
      printf 'Error from server (Timeout): the server was unable to return a response in the time allotted\n' >&2
      exit "$STUB_KUBE_READ_RC"
      ;;
  esac
fi
kubectl_log_to="$ARGV_LOG"
case " $* " in *"get --raw /readyz"*) kubectl_log_to="${API_PROBE_LOG:-$ARGV_LOG}" ;; esac
printf 'kubectl %s [kubeconfig=%s]\n' "$*" "${KUBECONFIG:-none}" >>"$kubectl_log_to"
case "$*" in
  *"get deployments -n "*" -o json"*)
    ns=""; prev=""
    for word in "$@"; do [ "$prev" != -n ] || ns="$word"; prev="$word"; done
    case "$ns" in
      pluto-payments) name=orders-svc ;;
      pluto-comms) name=fulfilment-worker ;;
      *) printf '{"items":[]}\n'; exit 0 ;;
    esac
    printf '{"items":[{"metadata":{"name":"%s"},"spec":{"template":{"spec":{"containers":[{"env":[{"name":"KAFKA_SASL_PASSWORD","valueFrom":{"secretKeyRef":{"name":"target-kafka-creds","key":"KAFKA_SASL_PASSWORD"}}}],"volumeMounts":[{"name":"kafka-ca"}]}],"volumes":[{"name":"kafka-ca","secret":{"secretName":"target-kafka-creds","items":[{"key":"KAFKA_SSL_CA_CERT"}]}}]}}}}]}\n' "$name"
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
  *" port-forward "*)
    # The application transaction owns a real port-forward's lifecycle, so the
    # stub must stay alive until the harness stops it. A separate mode models a
    # forwarder that exits before any request reaches the service.
    if [ "${STUB_PORT_FORWARD_EXITS:-0}" = "1" ]; then
      printf 'error: lost connection to pod\n' >&2
      exit 1
    fi
    printf '%s\n' "$$" >>"${STUB_PORT_FORWARD_PIDS:-/dev/null}"
    printf 'Forwarding from 127.0.0.1:18080 -> 80\n'
    exec sleep 3600
    ;;
  *"auth whoami"*)
    case " $* " in
      *ca-observer*)
        printf '%s\n' "${STUB_CA_OBSERVER_PRINCIPAL:-gcp:qualifier@sol-qualification.iam.gserviceaccount.com}"
        ;;
      *)
        printf '%s\n' "${STUB_CA_DEPLOY_PRINCIPAL:-gcp:deployer@example.com}"
        ;;
    esac
    exit 0 ;;
  *"get namespace kube-system -o jsonpath"*)
    case " $* " in
      *ca-observer*) printf '%s\n' "${STUB_CA_OBSERVER_CLUSTER_UID:-${STUB_CA_CLUSTER_UID:-cluster-uid-1}}" ;;
      *) printf '%s\n' "${STUB_CA_CLUSTER_UID:-cluster-uid-1}" ;;
    esac
    exit 0 ;;
  *"config current-context"*)
    printf '%s\n' "${STUB_CA_CONTEXT-ca-observer-selected}"
    exit 0 ;;
  *"config view --minify -o jsonpath"*)
    printf '%s\n' "${STUB_CA_ENDPOINT:-https://34.0.0.1}"
    exit 0 ;;
  *"auth can-i"*)
    case " $* " in
      *ca-observer*)
        if [ -n "${STUB_CA_OBSERVER_ALLOW:-}" ]; then
          case " $* " in
            *" ${STUB_CA_OBSERVER_ALLOW} "*) printf 'yes\n'; exit 0 ;;
          esac
        fi
        case " $* " in
          *" secrets "*)
            if [ "${STUB_CA_OBSERVER_ALLOW_SECRETS:-0}" = "1" ]; then printf 'yes\n'; else printf 'no\n'; fi
            ;;
          *)
            printf 'no\n'
            ;;
        esac
        ;;
      *)
        printf 'yes\n'
        ;;
    esac
    exit 0 ;;
  "create secret generic"*)
    if [ "${STUB_SECRET_CREATE_FAILS:-0}" = "1" ]; then
      printf 'Error from server (Forbidden): secrets "redpanda-users" is forbidden\n' >&2
      exit 1
    fi
    : >"${TMP:-/tmp}/credential-supplied"
    printf 'secret/redpanda-users created\n'
    exit 0 ;;
  "get secret redpanda-users"*)
    # A durable target requires the broker credential Secret. `STUB_NO_BROKER_CRED` models an
    # observed absence (NotFound); `STUB_UNREADABLE_BROKER_CRED` models a check that fails
    # without saying not-found (Forbidden), which the harness must not read as absence.
    if [ "${STUB_NO_BROKER_CRED:-0}" = "1" ]; then
      printf 'Error from server (NotFound): secrets "redpanda-users" not found\n' >&2
      exit 1
    fi
    if [ "${STUB_UNREADABLE_BROKER_CRED:-0}" = "1" ]; then
      printf 'Error from server (Forbidden): secrets "redpanda-users" is forbidden: User "sol-qual" cannot get resource "secrets" in API group "" in the namespace "redpanda"\n' >&2
      exit 1
    fi
    printf '%s' 'sol-workloads:testpass:SCRAM-SHA-256' | base64
    exit 0 ;;
  "get secret redpanda-default-cert"*)
    printf '%s' 'ca-certificate-for-tests' | base64
    exit 0 ;;
  # 2b: the deploy delivers the database as class Secrets; the row lists them across
  # namespaces and checks the consumer's own Secret for the master copy it no longer holds.
  "get secret "*"-ddl-creds -n "*)
    if [ "${STUB_DDL_CREDS_ABSENT:-0}" = "1" ]; then
      printf 'Error from server (NotFound): secrets not found\n' >&2
      exit 1
    fi
    exit 0
    ;;
  "get secret "*"-dml-creds -n "*)
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
  "get secret -A"*)
    printf '%s\n' \
      "${STUB_DML_NAMESPACE:-pluto-payments} ${STUB_CLASS_PREFIX:-qual-gcp-us-central1}-dml-creds" \
      "${STUB_DDL_NAMESPACE-pluto-comms} ${STUB_CLASS_PREFIX:-qual-gcp-us-central1}-ddl-creds"
    exit 0 ;;
  "get secret orders-svc-secrets"*)
    exit 0 ;;
  "get pods --all-namespaces -o json")
    if [ "${STUB_PROJECTED_TOKENS:-0}" = "1" ]; then
      printf '{"items":[{"metadata":{"namespace":"pluto-payments","name":"charge-svc-abc123"},"spec":{"volumes":[{"name":"api-token","projected":{"sources":[{"serviceAccountToken":{"audience":"order-svc","expirationSeconds":3600}}]}}]}}]}\n'
    else
      printf '{"items":[]}\n'
    fi
    exit 0 ;;
  "get pods -A -o wide"*)
    printf 'NAMESPACE   NAME          READY   STATUS    RESTARTS   AGE   IP   NODE\n'
    printf 'platform    redpanda-0    0/1     Pending   0          9m    <none>  <none>\n'
    printf 'monitoring  loki-0        0/1     Pending   0          9m    <none>  <none>\n'
    exit 0 ;;
  *jsonpath*containerStatuses*)
    printf 'platform/redpanda-0\tPending\t\tredpanda=waiting{reason=ContainerCreating} restarts=0 \n'
    printf 'monitoring/loki-0\tPending\t\tloki=waiting{reason=ContainerCreating} restarts=0 \n'
    exit 0 ;;
  *jsonpath*resources.requests*)
    printf 'platform/redpanda-0\tPending\t<none>\trequests=map[cpu:1 memory:2Gi]\tlimits=map[cpu:1 memory:2Gi]\tPodScheduled=False(Unschedulable) \n'
    printf 'monitoring/loki-0\tPending\t<none>\trequests=map[cpu:1 memory:1Gi]\tlimits=map[cpu:1 memory:1Gi]\tPodScheduled=False(Unschedulable) \n'
    exit 0 ;;
  "get events -A"*)
    printf 'platform   Warning   FailedScheduling   pod/redpanda-0  0/3 nodes are available: 3 Insufficient cpu.\n'
    exit 0 ;;
  "get pvc -A"*)
    printf 'NAMESPACE   NAME              STATUS   VOLUME                                     CAPACITY\n'
    printf 'platform    data-redpanda-0   Bound    pvc-2120bdaa-3cfd-4873-a04c-cf4fdfa4499d   10Gi\n'
    exit 0 ;;
  "get pv"*)
    printf 'NAME                                       CAPACITY   STATUS   CLAIM\n'
    printf 'pvc-2120bdaa-3cfd-4873-a04c-cf4fdfa4499d   10Gi       Bound    platform/data-redpanda-0\n'
    exit 0 ;;
  "get nodes -o wide"*)
    printf 'NAME                            STATUS   ROLES    AGE   VERSION\n'
    printf 'gke-sol-qual-gcp-15f-nodes-abc  Ready    <none>   12m   v1.29\n'
    exit 0 ;;
  *jsonpath*allocatable*)
    printf 'gke-sol-qual-gcp-15f-nodes-abc\tallocatable=2/8Gi\tReady=True(KubeletReady) \n'
    exit 0 ;;
  *jsonpath*spec.taints*)
    printf 'gke-sol-qual-gcp-15f-nodes-abc\tmap[effect:NoSchedule key:node.kubernetes.io/not-ready]\n'
    exit 0 ;;
  *"get secrets -A -l owner=helm"*)
    printf 'NS          NAME                             TYPE\n'
    printf 'platform    sh.helm.release.v1.redpanda.v1   helm.sh/release.v1\n'
    printf 'monitoring  sh.helm.release.v1.loki.v1        helm.sh/release.v1\n'
    exit 0 ;;
  *"config get-contexts"*)
    case " $* " in
      *ca-observer*)
        printf 'gke_sol-qualification_us-central1_test-cluster-observer\n'
        ;;
      *)
        printf 'gke_old-project_us-central1_sol-qual-gcp-15c\ngke_sol-qualification_us-central1_test-cluster\n'
        ;;
    esac
    exit 0
    ;;
  *"config use-context"*) exit 0 ;;
  *"get --raw /readyz"*)
    if [ "${STUB_API_UNREACHABLE:-0}" = "1" ]; then
      printf 'Unable to connect to the server: dial tcp 136.65.210.170:443: i/o timeout\n' >&2
      exit 1
    fi
    printf 'ok\n'
    exit 0
    ;;
  *"logs job/cert-manager-startupapicheck"*)
    case "${STUB_KUBE_SIGNATURE:-none}" in
      x509)      printf 'error: x509: certificate signed by unknown authority\n' ;;
      discovery) printf 'error: no matches for kind "Certificate" in version "cert-manager.io/v1"\n' ;;
      dial)      printf 'error: context deadline exceeded: dial tcp 10.0.0.1:10250: i/o timeout\n' ;;
      quota)     : ;;
      warden)    : ;;
      *)         : ;;
    esac
    ;;
  *"logs deploy/cert-manager-cainjector"*|*"logs deploy/cert-manager "*|*"logs deploy/cert-manager")
    case "${STUB_COMPONENT_SIGNATURE:-none}" in
      leader)
        printf 'E0926 15:16:38.035149       1 leaderelection.go:336] error initially creating leader election record: leases.coordination.k8s.io is forbidden: User \"system:serviceaccount:cert-manager:cert-manager-cainjector\" cannot create resource \"leases\" in API group \"coordination.k8s.io\" in the namespace \"kube-system\": GKE Warden authz [denied by managed-namespaces-limitation]: the namespace \"kube-system\" is managed and the request verb \"create\" is denied\n'
        ;;
      *) : ;;
    esac
    ;;
  *"get events"*)
    if [ "${STUB_APPLY_ERROR:-none}" = "warden" ]; then
      printf '│ Error: admission webhook "warden-validating.common-webhooks.networking.gke.io" denied'
      printf ' the request: GKE Warden rejected the request because it violates the following'
      printf ' Violations details: {"[denied by autogke-disallow-hostnamespaces]":["enabling'
      printf ' hostNetwork is not allowed in Autopilot."]}\n'
    fi
    if [ "${STUB_KUBE_SIGNATURE:-none}" = "quota" ]; then
      printf 'LAST SEEN   TYPE      REASON               OBJECT               MESSAGE\n'
      printf '5m          Warning   ProvisioningFailed   persistentvolumeclaim/storage-loki-0   rpc error: code = Unavailable desc = CreateVolume failed: failed to insert zonal disk: (QUOTA_EXCEEDED): Quota '"'"'SSD_TOTAL_GB'"'"' exceeded\n'
    fi
    if [ "${STUB_KUBE_SIGNATURE:-none}" = "stale-scheduling" ]; then
      printf 'LAST SEEN   TYPE      REASON             OBJECT                                     MESSAGE\n'
      printf '11m         Warning   FailedScheduling   pod/cert-manager-startupapicheck-xd44b     0/3 nodes are available: 3 Insufficient cpu.\n'
    fi
    ;;
  *"get job cert-manager-startupapicheck -o json"*)
    printf '{"status":{"succeeded":%s}}\n' "${STUB_JOB_SUCCEEDED:-0}" ;;
esac
exit 0
STUB

cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"/.well-known/openid-configuration"*)
    out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ "${STUB_OIDC_FAIL:-0}" = "1" ]; then
      [ -n "$out" ] && : >"$out"
      printf '404'
      exit 0
    fi
    if [ -n "$out" ]; then
      printf '{"issuer":"https://container.googleapis.com/v1/projects/sol-qualification/locations/us-central1/clusters/test-cluster","jwks_uri":"https://container.googleapis.com/v1/projects/sol-qualification/locations/us-central1/clusters/test-cluster/openid/v1/jwks"}\n' >"$out"
    fi
    printf '200'
    exit 0 ;;
esac
printf '{"Answer":[{"data":"ns-cloud-c1.googledomains.com."},{"data":"ns-cloud-c2.googledomains.com."},{"data":"ns-cloud-c3.googledomains.com."},{"data":"ns-cloud-c4.googledomains.com."}]}'
STUB

cat >"$TMP/bin/dig" <<'STUB'
#!/usr/bin/env bash
printf 'qual-gcp.sol-fab.dev.\t3600\tIN\tNS\tns-cloud-c1.googledomains.com.\n'
STUB

cat >"$TMP/bin/gzip" <<'STUB'
#!/usr/bin/env bash
cat
STUB

# Stub for the shared CA-family driver. The row calls it at the documented phase
# points; the observer's own semantics are covered by the offline qualification
# suite. This harness checks the wiring, phase ordering, request authorities and
# failure propagation.
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
[ -n "${LOG_DIR:-}" ] && printf '%s\n' "$phase" >>"$LOG_DIR/ca-phases.txt"
python3 - "$request" <<'PY'
import json, sys
request = json.load(open(sys.argv[1]))
if request.get("scenario") != "gcp":
    print("stub CA driver: the row did not request the gcp scenario", file=sys.stderr)
    raise SystemExit(3)
if request.get("identity_scope") != "qualifier":
    print("stub CA driver: the row did not name an independent observer", file=sys.stderr)
    raise SystemExit(3)
if "submission_authority" not in request:
    print("stub CA driver: the row did not separate submission from observation", file=sys.stderr)
    raise SystemExit(3)
if request["submission_authority"] == request["authority"]:
    print("stub CA driver: submission and observation identities are the same", file=sys.stderr)
    raise SystemExit(3)
PY
if [ "$phase" = "requirements" ]; then
  python3 - <<'PY'
import json, os
namespaces = ["pluto-payments", "pluto-comms", "pluto-demo-ts"]
omit = [name for name in os.environ.get("STUB_CA_REQUIREMENTS_OMIT", "").split(",") if name]
namespaces = [name for name in namespaces if name not in omit]
reads = []
for namespace in namespaces:
    reads.append({"namespace": namespace, "resource": "deployments.apps"})
    reads.append({"namespace": namespace, "resource": "configmaps"})
if "pluto-comms" in namespaces:
    reads.append({"namespace": "pluto-comms", "resource": "jobs.batch"})
print(json.dumps({"phase": "requirements", "scenario": "gcp",
                  "namespaces": namespaces, "reads": reads}))
PY
  exit 0
fi
if [ "${STUB_CA_FAIL:-}" = "$phase" ]; then
  echo "the shared database-CA observer refused the $phase phase" >&2
  exit 1
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
if [ "$phase" = "report" ] && [ -n "${STUB_CA_REPORT:-}" ]; then
  printf '%s\n' "$STUB_CA_REPORT" >"$report"
fi
exit 0
STUB

chmod +x "$TMP"/bin/*

SOL_DATA="$TMP/data/sol"
mkdir -p "$SOL_DATA/runs/cloud-apply-20260925T000000Z-1234"
printf 'lifecycle phase: CloudBootstrap\n' >"$SOL_DATA/runs/cloud-apply-20260925T000000Z-1234/phase.log"
printf 'root=platform/cloud/gcp/cluster\n' >"$SOL_DATA/runs/cloud-apply-20260925T000000Z-1234/meta"
printf 'exited 0\n' >"$SOL_DATA/runs/cloud-apply-20260925T000000Z-1234/exit"

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

run_case() {
  local name="$1" sub="$2"
  shift 2
  export ARGV_LOG="$TMP/$name.argv"
  export TMP
  export API_PROBE_LOG="$TMP/$name.probe.argv"
  CURRENT_CASE="$name"
  export LOG_DIR="$TMP/$name.logs"
  export WORKSPACE="$SCRATCH_WS"
  export XDG_DATA_HOME="$TMP/data"
  export STUB_KUBECONFIG_FIXTURE="$REPO/internal/qualification/gcp/fixtures/kubeconfig-gcloud-real.yaml"
  export STUB_PROVISIONER_SA="test-cluster-provisioner@sol-qualification.iam.gserviceaccount.com"
  : >"$ARGV_LOG"
  : >"$API_PROBE_LOG"
  rm -f "$TARGET_FILE" "$TMP/credential-supplied"
  if [ "${PRESEED_EMPTY_TARGET:-0}" = "1" ]; then
    : >"$TARGET_FILE"
  fi
  if [ "${PRESEED_TARGET:-0}" = "1" ]; then
    printf '# Written by internal/qualification/gcp/live-qual.sh (test preseed)\nqual:\n  targets:\n    gcp/us-central1:\n      cluster_name: test-cluster\n      base_domain: qual-gcp.sol-fab.dev\n' >"$TARGET_FILE"
  fi
  rm -rf "$LOG_DIR"
  if [ -n "${PRESEED_LB_ADDRESS:-}" ]; then
    mkdir -p "$LOG_DIR"
    printf '%s\n' "$PRESEED_LB_ADDRESS" >"$LOG_DIR/app-load-balancer.txt"
    [ -s "$LOG_DIR/attempt.txt" ] || printf 'attempt=%s\n' "$ATTEMPT" >"$LOG_DIR/attempt.txt"
  fi
  if [ -n "${PRESEED_PRIOR_IDENTITIES:-}" ]; then
    mkdir -p "$LOG_DIR"
    printf '# attempt=%s cluster=test-cluster project=sol-qualification region=us-central1\n' \
      "$ATTEMPT" >"$LOG_DIR/inventory-pre.identities.tsv"
    printf '%s\n' "$PRESEED_PRIOR_IDENTITIES" >>"$LOG_DIR/inventory-pre.identities.tsv"
    [ -s "$LOG_DIR/attempt.txt" ] || printf 'attempt=%s\n' "$ATTEMPT" >"$LOG_DIR/attempt.txt"
  fi
  if [ -n "${PRESEED_FOREIGN_PRIOR_IDENTITIES:-}" ]; then
    mkdir -p "$LOG_DIR"
    printf '# attempt=another-attempt cluster=another-cluster project=sol-qualification region=us-central1\n' \
      >"$LOG_DIR/inventory-pre.identities.tsv"
    printf '%s\n' "$PRESEED_FOREIGN_PRIOR_IDENTITIES" >>"$LOG_DIR/inventory-pre.identities.tsv"
    [ -s "$LOG_DIR/attempt.txt" ] || printf 'attempt=%s\n' "$ATTEMPT" >"$LOG_DIR/attempt.txt"
  fi
  if [ -n "${PRESEED_FOREIGN_ATTEMPT:-}" ]; then
    mkdir -p "$LOG_DIR"
    printf 'attempt=%s\n' "$PRESEED_FOREIGN_ATTEMPT" >"$LOG_DIR/attempt.txt"
  fi
  if [ "${PRESEED_CREDENTIALS:-0}" = "1" ]; then
    mkdir -p "$LOG_DIR"
    printf 'apiVersion: v1\n' >"$LOG_DIR/run-kubeconfig.yaml"
    printf 'attempt=%s\n' "$ATTEMPT" >"$LOG_DIR/attempt.txt"
  fi
  if [ "${PRESEED_STALE_KUBECONFIG:-0}" = "1" ]; then
    # A complete kubeconfig naming this cluster, left by an earlier run: the
    # waiter must not read it as this run's credentials.
    mkdir -p "$LOG_DIR"
    sed "s/sol-qual-gcp-15g/test-cluster/g" \
      "$REPO/internal/qualification/gcp/fixtures/kubeconfig-gcloud-real.yaml" \
      >"$LOG_DIR/run-kubeconfig.yaml"
    printf 'attempt=%s\ncandidate_revision=%s\n' "$ATTEMPT" "$CANDIDATE_REVISION" >"$LOG_DIR/attempt.txt"
  fi
  if [ "${PRESEED_INVENTORY:-0}" = "1" ]; then
    mkdir -p "$LOG_DIR"
    : >"$LOG_DIR/inventory-pre.tsv"
    [ -s "$LOG_DIR/attempt.txt" ] || printf 'attempt=%s\n' "$ATTEMPT" >"$LOG_DIR/attempt.txt"
  fi
  local harness="${HARNESS_UNDER_TEST:-$HARNESS}"
  # The install-time ACME contact is not an input to teardown (#1400), so a case can
  # ask for the documented minimal destroy environment by leaving it unset.
  local -a le_env=(LE_EMAIL=test@example.com)
  if [ "${OMIT_LE_EMAIL:-0}" = "1" ]; then le_env=(); fi
  env ALLOW_CANONICAL=1 SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" CLUSTER=test-cluster \
    IMPERSONATOR=user:test@example.com "${le_env[@]}" \
    PROJECT=sol-qualification REGION=us-central1 \
    SOL_QUALIFICATION_CA="$TMP/bin/qualification_database_ca" \
    GCP_CA_OBSERVER_PRINCIPAL=gcp:qualifier@sol-qualification.iam.gserviceaccount.com \
    GCP_CA_OBSERVER_SOURCE_KUBECONFIG="$REPO/internal/qualification/gcp/fixtures/kubeconfig-gcloud-real.yaml" \
    PATH="$TMP/bin:$PATH" "$@" \
    "$harness" "$sub" >"$TMP/$name.out" 2>&1
  echo "$? " >"$TMP/$name.rc"
  sed -i 's/ //' "$TMP/$name.rc"
}

# Run a *mutated* copy of the harness. The copy sits beside the real one so the
# script resolves the repository root from its own path; a copy anywhere else
# would fail its environment check instead of exercising the code under test.
# The mutation is a sed expression, so the regression is demonstrated against
# the shipped control flow rather than against a test-only hook.
run_mutated_case() {
  local name="$1" sub="$2" mutation="$3"
  shift 3
  local mutated="$(dirname "$HARNESS")/.live-qual-mutated-$name.sh"
  sed "$mutation" "$HARNESS" >"$mutated"
  chmod +x "$mutated"
  HARNESS_UNDER_TEST="$mutated"
  run_case "$name" "$sub" "$@"
  local rc=$?
  unset HARNESS_UNDER_TEST
  return "$rc"
}

run_case_without_a_phase() {
  export ARGV_LOG="$TMP/no-phase.argv"
  export TMP
  export API_PROBE_LOG="$TMP/no-phase.probe.argv"
  CURRENT_CASE="no-phase"
  export LOG_DIR="$TMP/no-phase.logs"
  export XDG_DATA_HOME="$TMP/data"
  : >"$ARGV_LOG"
  : >"$API_PROBE_LOG"
  rm -rf "$LOG_DIR"
  if [ "${PRESEED_CREDENTIALS:-0}" = "1" ]; then
    mkdir -p "$LOG_DIR"
    printf 'apiVersion: v1\n' >"$LOG_DIR/run-kubeconfig.yaml"
  fi
  env ALLOW_CANONICAL=1 SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" CLUSTER=test-cluster \
    IMPERSONATOR=user:test@example.com LE_EMAIL=test@example.com \
    PROJECT=sol-qualification REGION=us-central1 \
    SOL_QUALIFICATION_CA="$TMP/bin/qualification_database_ca" \
    GCP_CA_OBSERVER_PRINCIPAL=gcp:qualifier@sol-qualification.iam.gserviceaccount.com \
    GCP_CA_OBSERVER_SOURCE_KUBECONFIG="$REPO/internal/qualification/gcp/fixtures/kubeconfig-gcloud-real.yaml" \
    PATH="$TMP/bin:$PATH" "$HARNESS" >"$TMP/no-phase.out" 2>&1
  echo "$? " >"$TMP/no-phase.rc"
  sed -i 's/ //' "$TMP/no-phase.rc"
}

printf '\nscenario: planning skips durable reconciliation and cleanup\n'
for scenario in absent drift failure; do
  plan_rc=0
  [ "$scenario" = failure ] && plan_rc=1
  run_case "plan-$scenario" cloud PLAN_ONLY=1 STUB_PLAN_RC=2 STUB_CLOUD_PLAN_RC="$plan_rc" STUB_BUCKET_ABSENT=1
  is "$scenario: plan exit status is preserved" "$(cat "$TMP/plan-$scenario.rc")" "$plan_rc"
  has "$scenario: supported cloud planning runs" "sol plan" "$TMP/plan-$scenario.argv"
  lacks "$scenario: no durable Terraform operation runs" "terraform " "$TMP/plan-$scenario.argv"
  lacks "$scenario: planning runs no whole-target deploy" "sol deploy" "$TMP/plan-$scenario.argv"
  lacks "$scenario: no destroy runs on exit" "sol destroy" "$TMP/plan-$scenario.argv"
  [ ! -e "$TARGET_FILE" ] && ok "$scenario: scratch target is removed" \
    || no "$scenario: scratch target is removed" absent present
  if [ "$plan_rc" = 1 ]; then
    lacks "a failed plan makes no success claim" "no infrastructure mutation requested" "$TMP/plan-$scenario.out"
  fi
done

printf '\nscenario: cloud succeeds\n'
run_case cloud-ok cloud
is "exit 0" "$(cat "$TMP/cloud-ok.rc")" "0"
lacks "no destroy on the success path (the delegation boundary keeps the substrate)" "sol destroy" "$TMP/cloud-ok.argv"
lacks "the cloud phase never runs an application deploy" "migrate apply" "$TMP/cloud-ok.argv"
has "the target is written for the run" "cluster_name" "$TARGET_FILE"
has "the generated target asks for TLS, which DEC-055 made installable on GCP" "cluster_issuer: letsencrypt-staging" "$TARGET_FILE"
lacks "the cloud target selects no profile, so this row makes no profile claim" "profile:" "$TARGET_FILE"
has "the cloud target declares the durable shape it does not derive from a profile" "shape: durable" "$TARGET_FILE"
has "the cloud target declares the app database the enabled units use" "app_db:" "$TARGET_FILE"
has "and the events resource" "events: {}" "$TARGET_FILE"
has "and the OCaml units the alpha scenario runs" "orders_svc: {}" "$TARGET_FILE"
has "and the TypeScript units" "order_svc: {}" "$TARGET_FILE"
# A durable target requires an authority for every key its units need; the durable shape's
# authenticated Kafka makes KAFKA_SASL_PASSWORD/KAFKA_SSL_CA_CERT required for each included
# unit, so the written target must declare them or `sol check` refuses.
lacks "the durable target delegates Kafka credentials to the resource binding" \
  "payments/orders_svc:" "$TARGET_FILE"
lacks "no worker Kafka authority mapping remains" "comms/fulfilment_worker:" "$TARGET_FILE"
lacks "no TypeScript Kafka authority mapping remains" "demo_ts/order_svc:" "$TARGET_FILE"
lacks "no TypeScript worker Kafka authority mapping remains" "demo_ts/fulfillment_worker:" "$TARGET_FILE"
lacks "no competing operator authority remains" "authority: sol" "$TARGET_FILE"
lacks "but does not map a unit the target omits" "payments/charge_svc:" "$TARGET_FILE"
has "Sol validates the declarations in this phase" "sol check" "$TMP/cloud-ok.argv"
has "installation lifecycle is exercised through Sol" "sol deploy $TARGET --registry" "$TMP/cloud-ok.argv"
lacks "and the bootstrap deploy pins no digest that does not exist yet" "--image-ref" "$TMP/cloud-ok.argv"
lacks "the harness never mutates the durable Terraform root directly" "terraform apply" "$TMP/cloud-ok.argv"

if [ "$(awk '/sol check/{c=NR} /sol deploy/{a=NR} END{print (c && a && c<a) ? "yes" : "no"}' \
    "$TMP/cloud-ok.argv")" = "yes" ]; then
  ok "before it mutates the provider"
else
  no "before it mutates the provider" "check before apply" "wrong order"
fi
present "$TMP/cloud-ok.logs/state/cloud.tfstate" "the cloud state snapshot is in the bundle (H3)"
present "$TMP/cloud-ok.logs/state/platform.tfstate" "the platform state snapshot is in the bundle (H3)"
if [ -s "$TMP/cloud-ok.logs/sol-runs/cloud-apply-20260925T000000Z-1234/phase.log" ]; then
  ok "Sol's own run artifacts are copied into the bundle (H4)"
else
  no "Sol's own run artifacts are copied into the bundle (H4)" "copied" "missing"
fi
present "$TMP/cloud-ok.logs/inventory-pre.tsv" "a pre-teardown provider inventory is captured (H6)"
present "$TMP/cloud-ok.logs/ready-phases.txt" "the Ready-path phase lines are captured"
has "the harness's own narrative is part of the bundle" "phase: cloud-apply" \
  "$TMP/cloud-ok.logs/harness.log"
has "and it opens with the revision the attempt ran from" "environment: work tree" \
  "$TMP/cloud-ok.logs/harness.log"
has "the run identity and state key are in the manifest" \
  "state_key: sol/qual/gcp/us-central1/cloud.tfstate/default.tfstate" \
  "$TMP/cloud-ok.logs/evidence-manifest.txt"
has "and the attempt identity too" "attempt: $ATTEMPT" "$TMP/cloud-ok.logs/evidence-manifest.txt"
present "$TMP/cloud-ok.logs/inventory-pre.identity" \
  "the provider inventory carries the attempt, target and state key"

printf '\nscenario: managed credential failure is never repaired by qualification\n'
run_case credential-boundary cloud STUB_APPLY_CREDENTIAL_MISSING=1
is "credential initialization failure blocks the row" "$(cat "$TMP/credential-boundary.rc")" "1"
lacks "the harness never creates the broker credential" "create secret generic redpanda-users" "$TMP/credential-boundary.argv"
lacks "the harness never uses application secret writes" "secret set" "$TMP/credential-boundary.argv"

printf '\nscenario: a state object that cannot be read is recorded, not demanded\n'
run_case credential-boundary-nostate cloud STUB_STATE_UNREADABLE=1
lacks "an unreadable state object does not by itself make the bundle incomplete" \
  "bundle member missing or empty: state/platform.tfstate" "$TMP/credential-boundary-nostate.out"
has "the manifest reports what the run holds" "terraform state (platform)  MISSING" \
  "$TMP/credential-boundary-nostate.logs/evidence-manifest.txt"
has "and the read that could not establish it is kept" "COULD NOT READ" "$TMP/credential-boundary-nostate.out"

printf '\nscenario: a repeated invocation cannot reuse an occupied disposable target\n'
run_case occupied cloud STUB_STATE_PRESENT=1
is "exit 2" "$(cat "$TMP/occupied.rc")" "2"
has "the refusal names the occupied state key" "already exists" "$TMP/occupied.out"
lacks "nothing is applied" "sol deploy" "$TMP/occupied.argv"
lacks "and nothing is torn down" "sol destroy" "$TMP/occupied.argv"

printf '\nscenario: an evidence directory that belongs to another attempt is refused\n'
PRESEED_FOREIGN_ATTEMPT=another-attempt run_case reused-dir cloud
is "exit 2" "$(cat "$TMP/reused-dir.rc")" "2"
has "the refusal names the attempt the directory belongs to" "another-attempt" "$TMP/reused-dir.out"
lacks "nothing is applied" "sol deploy" "$TMP/reused-dir.argv"

printf '\nscenario: a credential for a replaced same-name cluster is not this run'"'"'s\n'
run_case stale-endpoint cloud STUB_CLUSTER_EXISTS=1 STUB_ENDPOINT_REPORTED=10.9.9.9 \
  STUB_APPLY_RC=1 CLUSTER_WAIT_TIMEOUT_S=1 CLUSTER_KUBECONFIG_POLL_S=1
has "the capture is taken with no credentials, not the replaced cluster's" \
  "credentials for test-cluster: no" \
  "$TMP/stale-endpoint.logs/platform-failure/capture-summary.txt"
has "and the reason names the endpoint binding" "not the current endpoint" \
  "$TMP/stale-endpoint.logs/platform-failure/capture-summary.txt"

printf '\nscenario: a kubeconfig an earlier run left behind is not this run'"'"'s credential\n'
PRESEED_STALE_KUBECONFIG=1 run_case stale-artifact cloud STUB_APPLY_RC=1 \
  CLUSTER_WAIT_TIMEOUT_S=1 CLUSTER_KUBECONFIG_POLL_S=1
lacks "the waiter never reads the leftover file as this run's credential" \
  "run kubeconfig: ready" "$TMP/stale-artifact.logs/harness.log"
lacks "and never reports credentials it did not establish" \
  "run kubeconfig: established" "$TMP/stale-artifact.logs/harness.log"

cat >"$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"${DOCKER_LOG:-/dev/null}"
case " $* " in
  *" inspect "*)
    ref="${!#}"
    printf '%s@sha256:%s\n' "${ref%:*}" "$(printf 'c%.0s' $(seq 1 64))"
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/docker"

printf '\nscenario: the application rows build, push, deploy and verify the transaction\n'
mv "$TMP/bin/curl" "$TMP/bin/curl.delegation"
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${CURL_LOG:-/dev/null}"

submitted_id() {
  local body="" prev=""
  for arg in "$@"; do
    [ "$prev" = "-d" ] && body="$arg"
    prev="$arg"
  done
  printf '%s' "$body" | sed -n 's/.*"order_id":"\([^"]*\)".*/\1/p'
}

readback_sequence() {
  # A per-case counter lets a case model "pending, then confirmed" without
  # making the server's answer depend on wall-clock time.
  local counter="${STUB_TX_COUNTER:-}" n=1
  if [ -n "$counter" ]; then
    n="$(cat "$counter" 2>/dev/null || echo 0)"
    n=$((n + 1))
    printf '%s\n' "$n" >"$counter"
  fi
  printf '%s' "$n"
}

case " $* " in
  *"/healthz"*)
    if [ "${STUB_TX_HEALTH:-ok}" = fail ]; then
      printf 'unhealthy\n' >&2
      exit 22
    fi
    printf '%s\n' "${STUB_TX_HEALTH:-ok}"
    ;;
  *"/orders/"*)
    url="${!#}"
    id="${url##*/}"
    mode="${STUB_TX_READBACK:-confirmed}"
    if [ "$mode" = eventually ]; then
      if [ "$(readback_sequence)" -ge 2 ]; then mode=confirmed; else mode=pending; fi
    fi
    case "$mode" in
      confirmed) printf '{"order_id":"%s","status":"confirmed"}\n' "$id" ;;
      fulfilled) printf '{"order_id":"%s","status":"fulfilled"}\n' "$id" ;;
      whitespace) printf '{ "status" : "confirmed" , "order_id" : "%s" }\n' "$id" ;;
      field-order) printf '{"status":"confirmed","order_id":"%s"}\n' "$id" ;;
      pending) printf '{"order_id":"%s","status":"pending"}\n' "$id" ;;
      wrong-id) printf '{"order_id":"ord-somebody-else","status":"fulfilled"}\n' ;;
      status-only) printf '{"status":"fulfilled"}\n' ;;
      missing-status) printf '{"order_id":"%s"}\n' "$id" ;;
      invalid-json) printf '{"order_id":\n' ;;
      http-error)
        # Worst case: an HTTP error body that would satisfy a textual status
        # predicate. curl's exit status must keep it from being evaluated.
        printf '{"order_id":"%s","status":"fulfilled"}\n' "$id"
        exit 22
        ;;
      *) printf '{"order_id":"%s","status":"pending"}\n' "$id" ;;
    esac
    ;;
  *"/orders"*)
    id="$(submitted_id "$@")"
    mode="${STUB_TX_SUBMIT:-accepted}"
    case "$mode" in
      accepted) printf '{"order_id":"%s","status":"accepted"}\n' "$id" ;;
      whitespace) printf '{ "status" : "accepted" , "order_id" : "%s" }\n' "$id" ;;
      field-order) printf '{"status":"accepted","order_id":"%s"}\n' "$id" ;;
      wrong-id) printf '{"order_id":"ord-somebody-else","status":"accepted"}\n' ;;
      missing-id) printf '{"status":"accepted"}\n' ;;
      id-in-error) printf '{"error":"order %s was rejected"}\n' "$id" ;;
      invalid-json) printf '{"order_id":\n' ;;
      http-error)
        printf '{"order_id":"%s","status":"accepted"}\n' "$id"
        exit 22
        ;;
      *) printf '{"order_id":"%s","status":"accepted"}\n' "$id" ;;
    esac
    ;;
  *) printf 'ok' ;;
esac
STUB
chmod +x "$TMP/bin/curl"
export DOCKER_LOG="$TMP/app-docker.argv"
: >"$DOCKER_LOG"
export CURL_LOG="$TMP/app-curl.argv"
: >"$CURL_LOG"
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ok app
is "the app phase exits 0 when every step succeeds" "$(cat "$TMP/app-ok.rc")" "0"
# A durable target whose platform did not publish the broker credential Secret has a missing
# prerequisite, not a reason to skip the authenticated transport: the phase must refuse. Runs
# before the delegation curl stub replaces the transaction one.
printf '\nscenario: an absent broker credential refuses the app phase\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 STUB_NO_BROKER_CRED=1 run_case app-nobroker app
is "the app phase refuses an absent broker credential" "$(cat "$TMP/app-nobroker.rc")" "1"
has "missing broker input fails the independent comparison" \
  "Kafka authority/delivery observation failed" "$TMP/app-nobroker.out"
lacks "missing input never causes credential writes" "secret set" "$TMP/app-nobroker.argv"
lacks "missing input never causes broker Secret creation" "create secret generic redpanda-users" "$TMP/app-nobroker.argv"
printf '\nscenario: an unreadable broker input also refuses the app phase\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 STUB_UNREADABLE_BROKER_CRED=1 run_case app-broker-unreadable app
is "an unreadable input blocks qualification" "$(cat "$TMP/app-broker-unreadable.rc")" "1"
has "unknown input is never accepted" "Kafka authority/delivery observation failed" "$TMP/app-broker-unreadable.out"
cp "$TMP/bin/curl" "$TMP/bin/curl.transaction"
mv "$TMP/bin/curl.delegation" "$TMP/bin/curl"
cp "$TMP/bin/curl" "$TMP/bin/curl.delegation"
has "it builds each image from that service's own Dockerfile" \
  "docker build -f $TMP/app-ok.logs/app-build-context/app/payments/orders_svc/Dockerfile" "$DOCKER_LOG"
has "including the TypeScript namespace's service from its own Dockerfile" \
  "docker build -f $TMP/app-ok.logs/app-build-context/app/demo_ts/order_svc/Dockerfile" "$DOCKER_LOG"
has "and builds from the candidate revision's context, not the checkout" \
  " $TMP/app-ok.logs/app-build-context" "$DOCKER_LOG"
present "$TMP/app-ok.logs/candidate-binding.txt" \
  "the run records the revision it bound the build to"
has "and that revision is the candidate's" \
  "candidate_revision: $CANDIDATE_REVISION" "$TMP/app-ok.logs/candidate-binding.txt"
lacks "so no pin reaches the build from a moving ref" \
  "#main" "$TMP/app-ok.logs/candidate-binding.txt"
has "and pushes it into the target's Artifact Registry under the workspace's name" \
  "docker push us-central1-docker.pkg.dev/sol-qualification/test-cluster/pluto/orders-svc:qual-" "$DOCKER_LOG"
has "and the TypeScript namespace's image too" \
  "docker push us-central1-docker.pkg.dev/sol-qualification/test-cluster/pluto/order-svc:qual-" "$DOCKER_LOG"
lacks "the harness publishes no migration runner: the release bundle pins its own" \
  "sol-migration-runner" "$DOCKER_LOG"
present "$TMP/app-ok.logs/ca-phases.txt" \
  "the shared CA family owner recorded its phases"
has "the shared CA owner ran the migration phase at the row's migration step" \
  "migration" "$TMP/app-ok.logs/ca-phases.txt"
has "and the application phase after the final deploy" \
  "application" "$TMP/app-ok.logs/ca-phases.txt"
has "and the report phase that re-reads durable evidence" \
  "report" "$TMP/app-ok.logs/ca-phases.txt"
present "$TMP/app-ok.logs/ca-requirements.json" \
  "the candidate-bound requirements are recorded"
has "and include the migration namespace read" \
  '"namespace": "pluto-comms", "resource": "jobs.batch"' \
  "$TMP/app-ok.logs/ca-requirements.json"
lacks "the harness does not acquire observer credentials" \
  "--configuration sol-ca-observer-" "$TMP/app-ok.argv"
lacks "the harness does not rewrite the observer auth plugin" \
  "config set-credentials" "$TMP/app-ok.argv"
has "the selected observer context is used without a cluster-name heuristic" \
  '"context": "ca-observer-selected"' "$TMP/app-ok.logs/ca-request-migration.json"
has "the recorded auth mechanism names the supplied kubeconfig" \
  "auth: operator-supplied kubeconfig" "$TMP/app-ok.logs/ca-observer.txt"
lacks "the harness did not run a second migration outside the shared owner" \
  "migrate apply" "$TMP/app-ok.argv"
has "the migration request names the gcp scenario" \
  '"scenario": "gcp"' "$TMP/app-ok.logs/ca-request-migration.json"
has "the request names the independent observation identity" \
  "gcp:qualifier@sol-qualification.iam.gserviceaccount.com" \
  "$TMP/app-ok.logs/ca-request-migration.json"
has "and the deploy identity as the submission authority" \
  "gcp:deployer@example.com" "$TMP/app-ok.logs/ca-request-migration.json"
has "the observer authority is recorded separately from the deploy authority" \
  "gcp:qualifier@sol-qualification.iam.gserviceaccount.com" "$TMP/app-ok.logs/ca-authority.json"
has "the deploy authority is recorded for the migration receipt" \
  "gcp:deployer@example.com" "$TMP/app-ok.logs/ca-deploy-authority.json"
has "the observer authenticated as the declared principal" \
  "configured_observer_principal: gcp:qualifier@sol-qualification.iam.gserviceaccount.com" \
  "$TMP/app-ok.logs/ca-observer.txt"
has "the recorded authorization claim names only the bounded sample" \
  "permission_sample: get/list secrets, create pods/exec, get pods/log, patch deployments/configmaps/jobs and delete jobs denied in candidate-bound namespaces" \
  "$TMP/app-ok.logs/ca-observer.txt"
lacks "the shell does not duplicate the driver's positive read preflight" \
  "auth can-i get deployments.apps" "$TMP/app-ok.argv"
lacks "the harness no longer claims namespace confinement" \
  "sol-qualifier-unbound" "$TMP/app-ok.argv"
for permission in "get secrets" "list secrets" "create pods/exec" "get pods/log" \
  "patch deployments.apps" "patch configmaps" "patch jobs.batch" "delete jobs.batch"; do
  has "the bounded sample checks $permission" \
    "auth can-i $permission -n pluto-payments" "$TMP/app-ok.argv"
done
has "the requirement set is the candidate-bound obligation set" \
  "requirement_source: candidate-bound obligations" "$TMP/app-ok.logs/ca-observer.txt"
has "the report is recorded as the CA family authority, not a release acceptance" \
  "database_ca: the shared candidate-bound observer established the GCP application and migration CA family" \
  "$TMP/app-ok.logs/prerequisites.txt"
has "the deploy is given the target's own registry" \
  "--registry us-central1-docker.pkg.dev/sol-qualification/test-cluster" "$TMP/app-ok.argv"
has "and every selected workload is pinned by digest" \
  "deploy qual/gcp/us-central1 --registry us-central1-docker.pkg.dev/sol-qualification/test-cluster --image-ref orders_svc=us-central1-docker.pkg.dev/sol-qualification/test-cluster/pluto/orders-svc@sha256:" \
  "$TMP/app-ok.argv"
has "including the TypeScript namespace's service" \
  "--image-ref order_svc=us-central1-docker.pkg.dev/sol-qualification/test-cluster/pluto/order-svc@sha256:" \
  "$TMP/app-ok.argv"
lacks "the main deployment never uses a mutable workload tag" \
  "--image-tag qual-" "$TMP/app-ok.argv"
lacks "no operator POSTGRES_URL is set for the migration path" \
  "secret set POSTGRES_URL" "$TMP/app-ok.argv"
# The image a deploy resolves is the release's own, so what must hold is that the bundle
# carries a digest-pinned reference -- not that the harness exported one, which an installed
# release refuses (#1427).
has "the database setup image is pinned by digest in the release bundle (#1402, #1427)" \
  "postgres@sha256:" "$INSTALL/share/sol/$VERSION/setup-image"
has "and the harness hands no ambient override, which an installed release would refuse" \
  "[setup=unset]" "$TMP/app-ok.argv"
lacks "Kafka delivery never uses the application secret CLI" "secret set" "$TMP/app-ok.argv"
has "the provider authority matches broker and consumers" '"consumer_password_and_ca_match": true' "$TMP/app-ok.logs/kafka-delivery.json"
lacks "no removed --target/--domain surface is used" \
  "--domain" "$TMP/app-ok.argv"
lacks "no secret value is passed on a command line" \
  "testpass" "$TMP/app-ok.argv"
has "the observation records no credentials" \
  "never recorded" "$TMP/app-ok.logs/kafka-delivery.json"
has "the deploy's class-Secret delivery is asserted, not the operator's copy" \
  "database_delivery: qual-gcp-us-central1-ddl-creds@pluto-comms (migration Job, as the deploy declared it), qual-gcp-us-central1-dml-creds@pluto-payments (unit consumer)" \
  "$TMP/app-ok.logs/prerequisites.txt"
has "a real application-secret refusal is observed" \
  "application_secret_refusal: declared SOL_API_KEY was absent" "$TMP/app-ok.logs/prerequisites.txt"
has "and the migration-gate observation too" \
  "scoped_out: \"A deploy refuses to move workloads against an unapplied migration\" (this row applies migrations before its steady-state deploy)" \
  "$TMP/app-ok.logs/prerequisites.txt"
has "the run identity records the bundle version" \
  "sol_version: $VERSION" "$TMP/app-ok.logs/sol-identity.txt"
has "and the bundle's digest-pinned migration runner" \
  "migration_runner_image: $RUNNER" "$TMP/app-ok.logs/sol-identity.txt"
lacks "the app target selects no profile, so the row claims none of its guarantees" "profile:" "$TARGET_FILE"
has "the app target declares the durable shape it does not derive from a profile" \
  "shape: durable" "$TARGET_FILE"
lacks "the target does not compete with the Kafka binding authority" \
  "KAFKA_SASL_PASSWORD:" "$TARGET_FILE"
has "but it still declares the durable installation the cloud phase created" \
  "dns_zone_ownership: sol" "$TARGET_FILE"
has "the target declares the project the residue probe needs" "project_id: sol-qualification" "$TARGET_FILE"
has "the target names the cluster's own kube context" \
  "kube_context: gke_sol-qualification_us-central1_test-cluster" "$TARGET_FILE"
has "the target declares the resource pair the scenario uses" "events: {}" "$TARGET_FILE"
has "and the OCaml unit pair the scenario exercises" "orders_svc: {}" "$TARGET_FILE"
has "and the TypeScript unit pair too" "order_svc: {}" "$TARGET_FILE"
lacks "the legacy charge pair is omitted" "charge_svc: {}" "$TARGET_FILE"
has "the service whose ingress host is outside any zone Sol can issue for is omitted" "checkout_svc:" "$TARGET_FILE"
has "and the legacy pair is omitted rather than silently deployed" "charge_svc:" "$TARGET_FILE"
present "$TMP/app-ok.logs/app-transaction-ocaml.txt" "the OCaml transaction's evidence is in the bundle"
has "the OCaml transaction records the worker's write-back, not just an accepted order" \
  "fulfilled or confirmed" "$TMP/app-ok.logs/app-transaction-ocaml.txt"
present "$TMP/app-ok.logs/app-transaction-ts.txt" "the TypeScript transaction's evidence is in the bundle"
has "the TypeScript transaction records the worker's write-back too" \
  "fulfilled or confirmed" "$TMP/app-ok.logs/app-transaction-ts.txt"
present "$TMP/app-ok.logs/alpha-rows.txt" "the alpha rows each namespace ran are recorded"
has "the OCaml namespace's row mapping is recorded" "OCaml" "$TMP/app-ok.logs/alpha-rows.txt"
has "and the TypeScript namespace's" "TypeScript" "$TMP/app-ok.logs/alpha-rows.txt"
has "and B1 is marked run for the OCaml namespace" "$(printf 'OCaml\tB1\trun')" \
  "$TMP/app-ok.logs/alpha-rows.txt"
has "and for the TypeScript namespace" "$(printf 'TypeScript\tB1\trun')" \
  "$TMP/app-ok.logs/alpha-rows.txt"
has "the scenario drives the orders path" "/orders" "$CURL_LOG"
lacks "and never the legacy charges path the old app phase exercised" "/charges" "$CURL_LOG"
lacks "nor its notification read-back" "/notifications" "$CURL_LOG"
present "$TMP/app-ok.logs/app-runtime-secrets.txt" "the deploy's database source step is recorded"
has "as the cluster root's postgres_url output, which the deploy reads" \
  "database master source: the cluster root postgres_url output" \
  "$TMP/app-ok.logs/app-runtime-secrets.txt"
lacks "and the harness records no connection string at all" "://" \
  "$TMP/app-ok.logs/app-runtime-secrets.txt"
lacks "and never the password in the clear" "qual-secret" "$TMP/app-ok.logs/app-runtime-secrets.txt"
lacks "only a unit that protects /metrics declares the API key, so it is not a workspace runtime secret" "SOL_API_KEY:" \
  "$TMP/app-ok.logs/app-runtime-secrets.txt"
is "the CA phases ran in lifecycle order" \
  "$(tr '\n' ',' <"$TMP/app-ok.logs/ca-phases.txt")" "requirements,migration,application,report,"

printf '\nscenario: no independent CA observation identity refuses the app phase\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-no-observer app \
  GCP_CA_OBSERVER_SOURCE_KUBECONFIG=
is "the app phase refuses without an independent observation identity" \
  "$(cat "$TMP/app-ca-no-observer.rc")" "1"
has "and says the deploy kubeconfig is not a fallback" \
  "no independent GCP database-CA observation identity" "$TMP/app-ca-no-observer.out"
not_exists "no authority was fabricated without an observer" \
  "$TMP/app-ca-no-observer.logs/ca-authority.json"
not_exists "and the shared CA owner never ran" "$TMP/app-ca-no-observer.logs/ca-phases.txt"

printf '\nscenario: an observer that is the deploy identity refuses the app phase\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-operator app \
  STUB_CA_OBSERVER_PRINCIPAL=gcp:deployer@example.com \
  GCP_CA_OBSERVER_PRINCIPAL=gcp:deployer@example.com
is "the app phase refuses a non-independent observer" \
  "$(cat "$TMP/app-ca-operator.rc")" "1"
has "and names the conflation" \
  "CA observation identity is the deploy identity" "$TMP/app-ca-operator.out"

printf '\nscenario: an ambient identity that is not the configured observer refuses the app phase\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-wrong-observer app \
  STUB_CA_OBSERVER_PRINCIPAL=ambient@example.com
is "the app phase refuses a credential that did not authenticate as the configured observer" \
  "$(cat "$TMP/app-ca-wrong-observer.rc")" "1"
has "and names the observed and configured principals" \
  "not the configured observer gcp:qualifier@sol-qualification.iam.gserviceaccount.com" \
  "$TMP/app-ca-wrong-observer.out"

printf '\nscenario: an observer that can read Secrets refuses the app phase\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-secret-read app \
  STUB_CA_OBSERVER_ALLOW_SECRETS=1
is "the app phase refuses an observation identity broader than read-only" \
  "$(cat "$TMP/app-ca-secret-read.rc")" "1"
has "and names the forbidden authority" "CA observation permission sample forbids" \
  "$TMP/app-ca-secret-read.out"

printf '\nscenario: a representative mutation grant on the observer refuses the app phase\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-mutation app \
  STUB_CA_OBSERVER_ALLOW='patch deployments.apps'
is "the app phase refuses a mutation grant" \
  "$(cat "$TMP/app-ca-mutation.rc")" "1"
has "and names the mutation" "holds 'patch deployments.apps'" "$TMP/app-ca-mutation.out"

printf '\nscenario: an observer addressing another cluster refuses the app phase\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-foreign-cluster app \
  STUB_CA_OBSERVER_CLUSTER_UID=other-cluster
is "the app phase refuses a foreign observer cluster" "$(cat "$TMP/app-ca-foreign-cluster.rc")" "1"
has "and names the cluster mismatch" "another Kubernetes cluster or endpoint" "$TMP/app-ca-foreign-cluster.out"

printf '\nscenario: no selected observer context refuses the app phase\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-no-context app STUB_CA_CONTEXT=
is "the app phase refuses an unselected observer context" "$(cat "$TMP/app-ca-no-context.rc")" "1"
has "and names the missing context" "names no selected context" "$TMP/app-ca-no-context.out"

printf '\nscenario: a CA migration phase failure stops the phase before the final deploy\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-migration-fails app \
  STUB_CA_FAIL=migration
is "the app phase fails when the shared migration observation fails" \
  "$(cat "$TMP/app-ca-migration-fails.rc")" "1"
has "and the failure is recorded as a phase failure" \
  "database-CA migration phase did not pass" "$TMP/app-ca-migration-fails.out"
not_exists "the final deploy never ran" "$TMP/app-ca-migration-fails.logs/app-deploy.log"
lacks "and the application phase was not reached" "application" \
  "$TMP/app-ca-migration-fails.logs/ca-phases.txt"
not_exists "and no report was produced" "$TMP/app-ca-migration-fails.logs/ca-report.json"

printf '\nscenario: a CA application phase failure prevents a report\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-application-fails app \
  STUB_CA_FAIL=application
is "the app phase fails when the shared application observation fails" \
  "$(cat "$TMP/app-ca-application-fails.rc")" "1"
has "the migration phase succeeded first" "migration" \
  "$TMP/app-ca-application-fails.logs/ca-phases.txt"
has "and the application phase ran" "application" \
  "$TMP/app-ca-application-fails.logs/ca-phases.txt"
lacks "but the report was not reached" "report" \
  "$TMP/app-ca-application-fails.logs/ca-phases.txt"
not_exists "so no passing report exists" "$TMP/app-ca-application-fails.logs/ca-report.json"

printf '\nscenario: a CA report failure refuses an apparently successful app phase\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-report-fails app \
  STUB_CA_FAIL=report
is "the app phase fails when the durable report does not pass" \
  "$(cat "$TMP/app-ca-report-fails.rc")" "1"
has "and names the report phase" "database-CA report phase did not pass" \
  "$TMP/app-ca-report-fails.out"
is "after both observation phases ran" \
  "$(tr '\n' ',' <"$TMP/app-ca-report-fails.logs/ca-phases.txt")" \
  "requirements,migration,application,report,"

printf '\nscenario: a supplied observer kubeconfig requires a declared principal\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-source-no-principal app \
  GCP_CA_OBSERVER_SOURCE_KUBECONFIG="$REPO/internal/qualification/gcp/fixtures/kubeconfig-gcloud-real.yaml" \
  GCP_CA_OBSERVER_PRINCIPAL=
is "the app phase refuses a supplied kubeconfig without a declared principal" \
  "$(cat "$TMP/app-ca-source-no-principal.rc")" "1"
has "and says the principal must be declared" \
  "GCP_CA_OBSERVER_PRINCIPAL is required" "$TMP/app-ca-source-no-principal.out"

printf '\nscenario: a supplied observer kubeconfig can authenticate the declared principal\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-source-ok app \
  GCP_CA_OBSERVER_SOURCE_KUBECONFIG="$REPO/internal/qualification/gcp/fixtures/kubeconfig-gcloud-real.yaml" \
  GCP_CA_OBSERVER_PRINCIPAL=gcp:qualifier@sol-qualification.iam.gserviceaccount.com \
  STUB_CA_FAIL=report
is "the supplied kubeconfig is accepted through the CA phases" \
  "$(tr '\n' ',' <"$TMP/app-ca-source-ok.logs/ca-phases.txt")" \
  "requirements,migration,application,report,"
has "and the observer is recorded as the configured principal" \
  "configured_observer_principal: gcp:qualifier@sol-qualification.iam.gserviceaccount.com" \
  "$TMP/app-ca-source-ok.logs/ca-observer.txt"
has "and the source is recorded as an operator-supplied kubeconfig" \
  "auth: operator-supplied kubeconfig" "$TMP/app-ca-source-ok.logs/ca-observer.txt"
has "the only failure is the deliberately failing report" \
  "database-CA report phase did not pass" "$TMP/app-ca-source-ok.out"

printf '\nscenario: candidate-bound requirements do not cover the deploy migration namespace\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-requirements-drift app \
  STUB_CA_REQUIREMENTS_OMIT=pluto-comms
is "the app phase refuses a requirement set that omits the migration namespace" \
  "$(cat "$TMP/app-ca-requirements-drift.rc")" "1"
has "and names the lifecycle/candidate disagreement" \
  "do not cover the deploy's migration namespace pluto-comms" \
  "$TMP/app-ca-requirements-drift.out"

printf '\nscenario: the deploy declares no migration namespace\n'
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-ca-no-migration-namespace app \
  STUB_DDL_NAMESPACE=
is "the app phase refuses a missing migration namespace" \
  "$(cat "$TMP/app-ca-no-migration-namespace.rc")" "1"
has "and names the missing declaration" \
  "the deploy declared no migration namespace" \
  "$TMP/app-ca-no-migration-namespace.out"
lacks "the migration phase never ran" "migration" \
  "$TMP/app-ca-no-migration-namespace.logs/ca-phases.txt"
not_exists "and the final deploy never ran" \
  "$TMP/app-ca-no-migration-namespace.logs/app-deploy.log"

printf '\nscenario: a stalled orders read-back fails the phase, so success cannot be manufactured\n'
# The earlier app cases restored the DNS/identity curl stub; the transaction
# cases exercise the configurable application stub.
cp "$TMP/bin/curl.transaction" "$TMP/bin/curl"
export CURL_LOG="$TMP/app-stall.curl"
: >"$CURL_LOG"
export DOCKER_LOG="$TMP/app-stall.docker"
: >"$DOCKER_LOG"
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 STUB_TX_READBACK=pending \
  run_case app-stall app APP_READBACK_ATTEMPTS=2 APP_READBACK_INTERVAL=1
is "a read-back that never reaches fulfilled fails the phase" \
  "$(cat "$TMP/app-stall.rc")" 1
lacks "and no alpha row is recorded as run" "$(printf 'B1\trun')" \
  "$TMP/app-stall.logs/alpha-rows.txt"
has "the failure names the order that never completed" "never reached fulfilled or confirmed" \
  "$TMP/app-stall.logs/app-transaction-ocaml.log"

printf '\nscenario: adversarial — the shared transaction predicate decides every order body\n'
# The two predicates this change removed were textual. Demonstrate that each
# would have accepted a body the shared evaluator refuses, then drive the real
# harness against the same bodies.
old_status="$TMP/old-status-only.json"
printf '{"status":"fulfilled"}' >"$old_status"
if grep -qE '"status":"(fulfilled|confirmed)"' "$old_status"; then
  ok "the removed status grep accepts a body with no order identity"
else
  no "the removed status grep accepts a body with no order identity" "match" "no match"
fi
old_error="$TMP/old-id-in-error.json"
printf '{"error":"order %s was rejected"}' "ord-old" >"$old_error"
if grep -qF "ord-old" "$old_error"; then
  ok "the removed order-id grep accepts an error message that merely names the id"
else
  no "the removed order-id grep accepts an error message that merely names the id" "match" "no match"
fi
lacks "the harness no longer greps the submitted id out of the response" \
  'grep -qF "$order_id" "$LOG_DIR/app-order' "$HARNESS"
lacks "and no longer greps the terminal status" \
  'grep -qE '\''"status":"(fulfilled|confirmed)"'\'' "$status_file"' "$HARNESS"

run_transaction_case() {
  local name="$1"
  shift
  export DOCKER_LOG="$TMP/$name.docker"
  : >"$DOCKER_LOG"
  export CURL_LOG="$TMP/$name.curl"
  : >"$CURL_LOG"
  STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 \
    run_case "$name" app APP_READBACK_ATTEMPTS="${TX_ATTEMPTS:-2}" APP_READBACK_INTERVAL=1 "$@"
}

export STUB_PORT_FORWARD_PIDS="$TMP/tx-port-forward-pids"
: >"$STUB_PORT_FORWARD_PIDS"

# Positive: alternate JSON serialization must still establish the effect.
for mode in accepted whitespace field-order; do
  run_transaction_case "tx-submit-$mode" STUB_TX_SUBMIT="$mode"
  is "submit $mode: the phase exits 0" "$(cat "$TMP/tx-submit-$mode.rc")" 0
  has "submit $mode: the OCaml effect is recorded" "the worker effect is visible" \
    "$TMP/tx-submit-$mode.logs/app-transaction-ocaml.txt"
  has "submit $mode: the TypeScript effect is recorded" "the worker effect is visible" \
    "$TMP/tx-submit-$mode.logs/app-transaction-ts.txt"
done

for mode in confirmed fulfilled whitespace field-order; do
  run_transaction_case "tx-readback-$mode" STUB_TX_READBACK="$mode"
  is "read-back $mode: the phase exits 0" "$(cat "$TMP/tx-readback-$mode.rc")" 0
  has "read-back $mode: the OCaml effect is recorded" "the worker effect is visible" \
    "$TMP/tx-readback-$mode.logs/app-transaction-ocaml.txt"
  has "read-back $mode: the TypeScript effect is recorded" "the worker effect is visible" \
    "$TMP/tx-readback-$mode.logs/app-transaction-ts.txt"
done

# Positive: polling is bounded but a pending first read-back may still complete.
rm -f "$TMP/tx-eventually.counter"
run_transaction_case tx-readback-eventually STUB_TX_READBACK=eventually \
  STUB_TX_COUNTER="$TMP/tx-eventually.counter"
is "a pending first read-back that later completes exits 0" \
  "$(cat "$TMP/tx-readback-eventually.rc")" 0
has "and the first response was recorded as pending" '"status":"pending"' \
  "$TMP/tx-readback-eventually.logs/app-transaction-ocaml.txt"
has "and the completed effect is recorded" "the worker effect is visible" \
  "$TMP/tx-readback-eventually.logs/app-transaction-ocaml.txt"

# Negative submission bodies: none may be read as the submitted order.
for mode in wrong-id missing-id id-in-error invalid-json http-error; do
  run_transaction_case "tx-submit-$mode" STUB_TX_SUBMIT="$mode"
  [ "$(cat "$TMP/tx-submit-$mode.rc")" != "0" ] \
    && ok "submit $mode: the phase fails" \
    || no "submit $mode: the phase fails" "non-zero" "0"
  lacks "submit $mode: no OCaml row is recorded" "$(printf 'OCaml\tB1\trun')" \
    "$TMP/tx-submit-$mode.logs/alpha-rows.txt"
done
has "a different returned id is named" "identified ord-somebody-else, not the submitted" \
  "$TMP/tx-submit-wrong-id.logs/app-transaction-ocaml.log"
has "a missing id is not a usable identity" "not a usable order identity" \
  "$TMP/tx-submit-missing-id.logs/app-transaction-ocaml.log"
has "an id only in an error message is not a usable identity" "not a usable order identity" \
  "$TMP/tx-submit-id-in-error.logs/app-transaction-ocaml.log"
has "malformed submission JSON is not a usable identity" "not a usable order identity" \
  "$TMP/tx-submit-invalid-json.logs/app-transaction-ocaml.log"
has "an HTTP failure is reported as a transport failure" "failed at the transport (curl exit 22)" \
  "$TMP/tx-submit-http-error.logs/app-transaction-ocaml.log"

# Negative read-backs: every body is evaluated structurally, and the failure
# names whether the evidence was an unmet effect, unreadable, or unreachable.
for mode in pending wrong-id status-only missing-status invalid-json http-error; do
  run_transaction_case "tx-readback-$mode" STUB_TX_READBACK="$mode"
  [ "$(cat "$TMP/tx-readback-$mode.rc")" != "0" ] \
    && ok "read-back $mode: the phase fails" \
    || no "read-back $mode: the phase fails" "non-zero" "0"
  lacks "read-back $mode: no OCaml row is recorded" "$(printf 'OCaml\tB1\trun')" \
    "$TMP/tx-readback-$mode.logs/alpha-rows.txt"
done
for mode in pending wrong-id status-only missing-status; do
  has "read-back $mode: the semantic negative is named" "never reached fulfilled or confirmed" \
    "$TMP/tx-readback-$mode.logs/app-transaction-ocaml.log"
done
has "a malformed read-back is not a semantic negative" "never produced usable JSON evidence" \
  "$TMP/tx-readback-invalid-json.logs/app-transaction-ocaml.log"
has "an HTTP read-back failure is named as transport" "could not be completed through the transport" \
  "$TMP/tx-readback-http-error.logs/app-transaction-ocaml.log"

# A forwarder that dies before the request cannot establish the transaction, and
# the failure names the transport rather than the order.
run_transaction_case tx-port-forward-exit STUB_PORT_FORWARD_EXITS=1
[ "$(cat "$TMP/tx-port-forward-exit.rc")" != "0" ] \
  && ok "a port-forward that exits before the request fails the phase" \
  || no "a port-forward that exits before the request fails the phase" "non-zero" "0"
has "and the failure names the forwarder" "forwarding endpoint" \
  "$TMP/tx-port-forward-exit.logs/app-transaction-ocaml.log"

run_transaction_case tx-health-fails STUB_TX_HEALTH=fail
[ "$(cat "$TMP/tx-health-fails.rc")" != "0" ] \
  && ok "an unhealthy service fails before any order is submitted" \
  || no "an unhealthy service fails before any order is submitted" "non-zero" "0"
has "and the failure names the health endpoint" "never answered /healthz" \
  "$TMP/tx-health-fails.logs/app-transaction-ocaml.log"

# The forwarder is stopped on success and on every failure above. The stub
# records its own pid before sleeping, so a leaked process is observable.
leftover_forwarders=""
while IFS= read -r forwarder_pid; do
  [ -n "$forwarder_pid" ] || continue
  if kill -0 "$forwarder_pid" 2>/dev/null; then
    leftover_forwarders="$leftover_forwarders $forwarder_pid"
  fi
done <"$STUB_PORT_FORWARD_PIDS"
if [ -z "$leftover_forwarders" ]; then
  ok "every port-forward was stopped, including the failure paths"
else
  no "every port-forward was stopped, including the failure paths" "no live forwarder" \
    "still running:$leftover_forwarders"
fi
cp "$TMP/bin/curl.delegation" "$TMP/bin/curl"

printf '\nscenario: adversarial — a bundle that cannot pin Sol stops the run before Sol is asked to move anything\n'
export DOCKER_LOG="$TMP/app-runner-tag.docker"
: >"$DOCKER_LOG"
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-runner-tag app \
  SOL_INSTALL="$TAG_RUNNER_INSTALL"
[ "$(cat "$TMP/app-runner-tag.rc")" != "0" ] \
  && ok "the app phase refuses a bundle whose runner reference is a tag" \
  || no "the app phase refuses a bundle whose runner reference is a tag" "non-zero" "0"
lacks "and Sol is never invoked with it" "migrate apply" "$TMP/app-runner-tag.argv"
lacks "nor for the deploy" "deploy qual/gcp/us-central1" "$TMP/app-runner-tag.argv"
has "the refusal names the digest boundary" "not a digest reference" "$TMP/app-runner-tag.out"
lacks "and the harness never reaches the registry: it publishes no runner" \
  "sol-migration-runner" "$DOCKER_LOG"

printf '\nscenario: adversarial — a run cannot qualify a prefix that is not the candidate it names\n'
export DOCKER_LOG="$TMP/gcp-othercandidate.docker"
: >"$DOCKER_LOG"
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case gcp-othercandidate app \
  SOL_CANDIDATE="$TMP/candidate-other-revision.json"
[ "$(cat "$TMP/gcp-othercandidate.rc")" != "0" ] \
  && ok "a candidate naming another revision is refused" \
  || no "a candidate naming another revision is refused" "non-zero" "0"
has "and the refusal names both revisions" \
  "candidate $VERSION is revision 0000000000000000000000000000000000000000" \
  "$TMP/gcp-othercandidate.out"
lacks "no image is built for it" "docker build" "$DOCKER_LOG"
lacks "and Sol is never asked to deploy" "deploy qual" "$TMP/gcp-othercandidate.argv"

printf '\nscenario: adversarial — a development build is refused before any phase runs\n'
STUB_SOL_VERSION=Sol-ed3f041f run_case app-dev app
[ "$(cat "$TMP/app-dev.rc")" != "0" ] \
  && ok "the app phase refuses a development build" \
  || no "the app phase refuses a development build" "non-zero" "0"
has "the refusal names the installed-bundle rule" \
  "which is a development build" "$TMP/app-dev.out"
lacks "and Sol never migrates" "migrate apply" "$TMP/app-dev.argv"

printf '\nscenario: the app phase refuses when the run has no credentials\n'
run_case app-nocred app
is "it exits 2" "$(cat "$TMP/app-nocred.rc")" "2"
has "and says why" "no run kubeconfig" "$TMP/app-nocred.out"
lacks "and invokes no Sol command before it has somewhere to deploy" "sol deploy" "$TMP/app-nocred.argv"

printf '\nscenario: destroy asks for the identity it uses (FND-0078)\n'
run_case destroy-nocred destroy CLUSTER=test-cluster IMPERSONATOR=
is "a destroy without the impersonator is refused" "$(cat "$TMP/destroy-nocred.rc")" "1"
has "and names the variable the phase needs rather than crashing on it" \
  "IMPERSONATOR" "$TMP/destroy-nocred.out"
lacks "and tears nothing down" "sol destroy" "$TMP/destroy-nocred.argv"

printf '\nscenario: destroy reuses the target file the harness left behind (FND-0078)\n'
run_case destroy-empty-target destroy CLUSTER=test-cluster IMPERSONATOR=user:test@example.test \
  PRESEED_EMPTY_TARGET=1
lacks "an empty harness target file is not treated as a foreign one" \
  "was not written by this harness" "$TMP/destroy-empty-target.out"
has "and the phase went on to destroy its target, which it could only do from a usable file" \
  "sol destroy" "$TMP/destroy-empty-target.argv"

printf '\nscenario: destroy does not require the install-only ACME contact (#1400)\n'
OMIT_LE_EMAIL=1 run_case destroy-no-le-email destroy \
  STUB_TARGET_COPY="$TMP/destroy-no-le-email.target"
is "the documented minimal destroy invocation exits 0" \
  "$(cat "$TMP/destroy-no-le-email.rc")" "0"
lacks "and does not abort on an unset LE_EMAIL" \
  "LE_EMAIL: unbound variable" "$TMP/destroy-no-le-email.out"
has "it writes the target destroy needs" \
  "wrote target qual/gcp/us-central1" "$TMP/destroy-no-le-email.out"
present "$TMP/destroy-no-le-email.target" "and the written target is what sol destroy reads"
has "the target binds the cluster identity" \
  "cluster_name: test-cluster" "$TMP/destroy-no-le-email.target"
has "and the provisioner impersonator" \
  "provisioner_impersonator: user:test@example.com" "$TMP/destroy-no-le-email.target"
has "the teardown target declares a non-deliverable contact" \
  "letsencrypt_email: teardown@invalid" "$TMP/destroy-no-le-email.target"
has "and teardown runs against that target" \
  "sol destroy qual/gcp/us-central1" "$TMP/destroy-no-le-email.argv"

printf '\nscenario: no phase given\n'
run_case_without_a_phase
is "a bare invocation exits 2" "$(cat "$TMP/no-phase.rc")" "2"
has "and prints its phase model" "usage: live-qual.sh PHASE" "$TMP/no-phase.out"
has "and the environment a run needs" "IMPERSONATOR" "$TMP/no-phase.out"
lacks "and not its own source" "set -euo pipefail" "$TMP/no-phase.out"
lacks "and tears nothing down" "sol destroy" "$TMP/no-phase.argv"

run_case ready-bindings cloud STUB_CLUSTER_EXISTS=1
if grep -qF 'get clusterrolebinding sol-platform-provisioner-cluster -o json' \
    "$TMP/ready-bindings.argv" 2>/dev/null; then
  ok "a successful install reads the cluster-scoped provisioner binding"
else
  no "a successful install reads the cluster-scoped provisioner binding" "the kubectl call" "none"
fi
if grep -qF 'get rolebinding -A --field-selector metadata.name=sol-platform-provisioner -o json' \
    "$TMP/ready-bindings.argv" 2>/dev/null; then
  ok "and reads the namespaced bindings"
else
  no "and reads the namespaced bindings" "the kubectl call" "none"
fi
has "the bundle manifest names the state snapshot" "terraform state (cloud)" "$TMP/cloud-ok.logs/evidence-manifest.txt"

printf '\nscenario: destroy\n'
run_case destroy-ok destroy
is "exit 0" "$(cat "$TMP/destroy-ok.rc")" "0"
is "teardown is invoked" "$([ "$(grep -c 'sol destroy' "$TMP/destroy-ok.argv")" -ge 1 ] && echo yes)" "yes"
is "teardown is invoked exactly once" "$(grep -c 'sol destroy' "$TMP/destroy-ok.argv")" "1"
has "destroy carries the cluster" "--var=cluster_name=test-cluster" "$TMP/destroy-ok.argv"
has "destroy carries the base domain" "--var=base_domain=" "$TMP/destroy-ok.argv"
has "destroy carries the impersonator" "provisioner_impersonators" "$TMP/destroy-ok.argv"
lacks "the durable zone is not passed as disposable intent" "--var=create_dns_zone=true" "$TMP/destroy-ok.argv"
has "the durable zone is explicitly excluded" "--var=create_dns_zone=false" "$TMP/destroy-ok.argv"
present "$TMP/destroy-ok.logs/inventory-pre.tsv" "the pre-teardown inventory precedes teardown"
present "$TMP/destroy-ok.logs/inventory-post.tsv" "the post-teardown inventory is captured"
verdict_json="$TMP/destroy-ok.logs/gcp-inventory-verdict.json"
present "$verdict_json" "the promotion-verifiable teardown verdict is captured"
is "the teardown verdict names the gcp provider" "$(jq -r .provider "$verdict_json")" "gcp"
policy_name="$(sed -n 's/^TEARDOWN_POLICY_NAME="\([^"]*\)"/\1/p' "$HARNESS" | head -1)"
is "the teardown verdict names the release policy" "$(jq -r .policy "$verdict_json")" "$policy_name"
is "the teardown verdict names the candidate it observed" "$(jq -r '.candidate.revision' "$verdict_json")" "$CANDIDATE_REVISION"
is "the teardown verdict binds the attempt" "$(jq -r .attempt "$verdict_json")" "$ATTEMPT"
is "the teardown verdict binds the target" "$(jq -r .target "$verdict_json")" "$TARGET"
is "the teardown verdict records the cluster scope" "$(jq -r .scope.cluster "$verdict_json")" "test-cluster"
is "the teardown verdict states absence" "$(jq -r .verdict "$verdict_json")" "ABSENT"
declared_verdict="$(sed -n '/^INVENTORY_CLASSES=(/,/^)/p' "$HARNESS" \
  | sed -n 's/^  "\([^|]*\)|.*/\1/p' | sort)"
is "the teardown verdict declares the same class universe" \
  "$(jq -r '.required_classes | sort | join("\n")' "$verdict_json")" "$declared_verdict"
is "the teardown verdict observes exactly the declared classes" \
  "$(jq -r '.classes | map(.class) | sort | join("\n")' "$verdict_json")" "$declared_verdict"
if jq -e 'all(.classes[];
    (.expectation == "absent" and .state == "ABSENT")
    or (.expectation == "present" and .state == "PRESENT"))' "$verdict_json" >/dev/null; then
  ok "every class is in its required terminal state"
else
  no "every class is in its required terminal state" "all expectations met" \
    "$(jq -c '.classes' "$verdict_json" | cut -c1-160)"
fi
present "$TMP/destroy-ok.logs/state/cloud.tfstate" "the state snapshot is frozen before teardown (H3)"
if [ -f "$TARGET_FILE" ]; then no "the target is removed after verified teardown" "removed" "still present"; else ok "the target is removed after verified teardown"; fi

printf '\nscenario: verification finds a leftover\n'
run_case destroy-leftover destroy STUB_TARGET_PRESENT=1
if [ "$(cat "$TMP/destroy-leftover.rc")" = "0" ]; then no "non-zero exit when resources remain" "non-zero" "0"; else ok "non-zero exit when resources remain"; fi
if [ -f "$TARGET_FILE" ]; then ok "the target is retained when teardown is unverified"; else no "the target is retained when teardown is unverified" "present" "removed"; fi
has "the leftover names a class the contract requires (artifact registry)" "artifact-registry still exists" "$TMP/destroy-leftover.out"
verdict_json="$TMP/destroy-leftover.logs/gcp-inventory-verdict.json"
present "$verdict_json" "the failing teardown also leaves a structured verdict"
is "the failing structured verdict does not claim absence" "$(jq -r .verdict "$verdict_json")" "NOT ABSENT"
is "the leftover class is PRESENT in the structured verdict" \
  "$(jq -r '.classes[] | select(.class == "artifact-registry") | .state' "$verdict_json")" "PRESENT"

printf '\nscenario: apply fails at the platform boundary\n'
run_case cloud-fail cloud STUB_APPLY_RC=1 STUB_CLUSTER_EXISTS=1 STUB_KUBE_SIGNATURE=dial
has "a failed apply still tears down" "sol destroy" "$TMP/cloud-fail.argv"
if [ "$(grep -c 'sol deploy' "$TMP/cloud-fail.argv")" = "1" ]; then
  ok "the harness does not run a second deploy to diagnose the platform"
else
  no "the harness does not run a second deploy to diagnose the platform" "one whole-target deploy" \
    "$(grep -c 'sol deploy' "$TMP/cloud-fail.argv")"
fi
if [ "$(cat "$TMP/cloud-fail.rc")" = "0" ]; then no "a failed apply exits non-zero" "non-zero" "0"; else ok "a failed apply exits non-zero"; fi
present "$TMP/cloud-fail.logs/inventory-pre.tsv" "the pre-teardown inventory is captured on the failure path (H6)"
present "$TMP/cloud-fail.logs/state/cloud.tfstate" "the state snapshot is captured on the failure path (H3)"
if [ -s "$TMP/cloud-fail.logs/sol-runs/cloud-apply-20260925T000000Z-1234/phase.log" ]; then
  ok "Sol's run artifacts are captured on the failure path (H4)"
else
  no "Sol's run artifacts are captured on the failure path (H4)" "copied" "missing"
fi


printf '\nscenario: the provider says NOT_FOUND\n'
run_case notfound-underscore destroy STUB_PROBE_MODE=notfound
is "the provider's own NOT_FOUND (underscore) reads as ABSENT" "$(cat "$TMP/notfound-underscore.rc")" "0"
has "and names the class absent" "gke-cluster absent" "$TMP/notfound-underscore.out"
run_case notfound-compute destroy STUB_PROBE_MODE=compute-notfound
is "'was not found' reads as ABSENT" "$(cat "$TMP/notfound-compute.rc")" "0"

for mode in permission transport invalid; do
  printf '\nscenario: probe failed without saying not-found (%s)\n' "$mode"
  run_case "probe-$mode" destroy "STUB_PROBE_MODE=$mode"
  if [ "$(cat "$TMP/probe-$mode.rc")" = "0" ]; then
    no "an unreadable probe ($mode) fails the verification" "non-zero" "0"
  else
    ok "an unreadable probe ($mode) fails the verification"
  fi
  if grep -q 'could NOT determine absence' "$TMP/probe-$mode.out"; then
    ok "it names the failure to determine absence ($mode)"
  else
    no "it names the failure to determine absence ($mode)" "named" "unmentioned"
  fi
  if grep -q 'artifact-registry: UNKNOWN' "$TMP/probe-$mode.out"; then
    ok "a newly-covered class is UNKNOWN when it cannot be read ($mode)"
  else
    no "a newly-covered class is UNKNOWN when it cannot be read ($mode)" "artifact-registry: UNKNOWN" "$(grep -m1 'artifact-registry' "$TMP/probe-$mode.out" || echo absent)"
  fi
  if [ -f "$TARGET_FILE" ]; then
    ok "the target is retained ($mode)"
  else
    no "the target is retained ($mode)" "present" "removed"
  fi
  verdict_json="$TMP/probe-$mode.logs/gcp-inventory-verdict.json"
  is "the unreadable class is UNKNOWN in the structured verdict ($mode)" \
    "$(jq -r '.classes[] | select(.class == "artifact-registry") | .state' "$verdict_json")" "UNKNOWN"
  is "the structured verdict does not claim absence ($mode)" \
    "$(jq -r .verdict "$verdict_json")" "NOT ABSENT"
done

printf '\nscenario: durable Kafka authority participates in independent teardown\n'
for secret_mode in present disabled permission malformed wrong-shape; do
  run_case "kafka-secret-$secret_mode" destroy "STUB_KAFKA_SECRET=$secret_mode"
  is "$secret_mode blocks independent verified absence" "$(cat "$TMP/kafka-secret-$secret_mode.rc")" "1"
  if [ "$secret_mode" = present ] || [ "$secret_mode" = disabled ]; then expected=PRESENT; else expected=UNKNOWN; fi
  is "$secret_mode has the required explicit state" \
    "$(jq -r '.classes[] | select(.class == "kafka-secret") | .state' "$TMP/kafka-secret-$secret_mode.logs/gcp-inventory-verdict.json")" "$expected"
done
run_case kafka-secret-unrelated destroy STUB_KAFKA_SECRET=unrelated
is "another target's secret is excluded" "$(cat "$TMP/kafka-secret-unrelated.rc")" "0"
run_mutated_case kafka-secret-omitted destroy \
  '/provider_enumerate kafka-secret /,/gcloud secrets list --project/d'
is "deleting the secret observation fails teardown" "$(cat "$TMP/kafka-secret-omitted.rc")" "1"
is "an omitted secret observation is unknown" \
  "$(jq -r '.classes[] | select(.class == "kafka-secret") | .state' "$TMP/kafka-secret-omitted.logs/gcp-inventory-verdict.json")" UNKNOWN

printf '\nscenario: every inventory row is one tab-separated line per declared class\n'
run_case inventory-row-shape destroy
shape="$TMP/inventory-row-shape.logs/inventory-post.tsv"
bad_rows="$(awk -F'\t' 'NF != 4 { n++ } END { print n + 0 }' "$shape")"
is "every row has exactly four fields" "$bad_rows" "0"
if grep -qF -- '==>' "$shape"; then
  no "no multi-file head header reaches the evidence" "no '==>' header" "present"
else
  ok "no multi-file head header reaches the evidence"
fi
dupes="$(cut -f1 "$shape" | sort | uniq -d)"
is "no class is observed twice" "$dupes" ""
declared="$(sed -n '/^INVENTORY_CLASSES=(/,/^)/p' "$HARNESS" \
  | sed -n 's/^  "\([^|]*\)|.*/\1/p' | sort)"
observed="$(cut -f1 "$shape" | sort)"
if [ "$declared" = "$observed" ]; then
  ok "the emitted classes are exactly the declared universe"
else
  no "the emitted classes are exactly the declared universe" "$declared" "$observed"
fi

printf '\nscenario: the verdict needs every declared class, not just the rows that happened\n'
run_mutated_case inventory-missing-class destroy \
  '/provider_describe gke-cluster /,/gcloud container clusters describe/d'
is "an inventory that never observed a declared class does not verify" \
  "$(cat "$TMP/inventory-missing-class.rc")" "1"
has "it names the class that was never observed" \
  "gke-cluster: the class was not observed" "$TMP/inventory-missing-class.out"
has "and the verdict says absence was not established" \
  "gke-cluster: could NOT determine absence" "$TMP/inventory-missing-class.out"
is "the missing class is UNKNOWN in the structured verdict" \
  "$(jq -r '.classes[] | select(.class == "gke-cluster") | .state' "$TMP/inventory-missing-class.logs/gcp-inventory-verdict.json")" "UNKNOWN"
is "the incomplete structured verdict does not claim absence" \
  "$(jq -r .verdict "$TMP/inventory-missing-class.logs/gcp-inventory-verdict.json")" "NOT ABSENT"
if [ -f "$TARGET_FILE" ]; then
  ok "an incomplete inventory keeps the target for a later destroy"
else
  no "an incomplete inventory keeps the target for a later destroy" "retained" "removed"
fi

printf '\nscenario: a row for a class the verdict does not declare is rejected\n'
run_mutated_case inventory-undeclared-class verify \
  's/^    provider_describe gke-cluster /    provider_describe gke-cluster-undeclared /'
is "an undeclared class fails the verification" \
  "$(cat "$TMP/inventory-undeclared-class.rc")" "1"
has "it names the undeclared row" \
  "gke-cluster-undeclared: an inventory row for a class the verdict does not declare" \
  "$TMP/inventory-undeclared-class.out"

printf '\nscenario: a class observed twice is not one observation\n'
run_mutated_case inventory-duplicate-class verify \
  's/^\(    verdict_row scope-caller PRESENT .*\)$/\1\n\1/'
is "a duplicated class fails the verification" \
  "$(cat "$TMP/inventory-duplicate-class.rc")" "1"
has "it names the duplicated class" \
  "scope-caller: observed 2 times" "$TMP/inventory-duplicate-class.out"

printf '\nscenario: a provider read is bound to one project, region and caller\n'
for scope in project caller region; do
  case "$scope" in
    project) stub=STUB_PROJECT_UNKNOWN=1 ;;
    caller)  stub=STUB_CALLER_UNKNOWN=1 ;;
    region)  stub=STUB_REGION_UNKNOWN=1 ;;
  esac
  run_case "scope-$scope-unknown" destroy "$stub"
  is "an unestablished $scope scope fails the verification" \
    "$(cat "$TMP/scope-$scope-unknown.rc")" "1"
  has "it names the $scope class" "scope-$scope: UNKNOWN" "$TMP/scope-$scope-unknown.out"
  has "and says no class was read under it" \
    "the project, region or caller scope was not established" "$TMP/scope-$scope-unknown.out"
  has "so a disposable class is UNKNOWN, not absent" \
    "gke-cluster: UNKNOWN" "$TMP/scope-$scope-unknown.out"
  if [ -f "$TARGET_FILE" ]; then
    ok "the target is retained when the scope is unestablished ($scope)"
  else
    no "the target is retained when the scope is unestablished ($scope)" "present" "removed"
  fi
done

printf '\nscenario: a successful read with an empty projection is not an absence\n'
run_case describe-empty destroy STUB_DESCRIBE_EMPTY=1
has "the named read is UNKNOWN, not absent" "gke-cluster: UNKNOWN" "$TMP/describe-empty.out"
if [ "$(cat "$TMP/describe-empty.rc")" = "0" ]; then
  no "an empty projection does not verify" "non-zero" "0"
else
  ok "an empty projection does not verify"
fi

printf '\nscenario: a denied read that also says not-found is UNKNOWN\n'
run_case permission-not-found destroy STUB_PROBE_MODE=permission-not-found
has "authority outranks a not-found token" "gke-cluster: UNKNOWN" "$TMP/permission-not-found.out"
has "and the report names the authority failure" \
  "failed on authority or availability" "$TMP/permission-not-found.out"
if grep -q 'gke-cluster: ABSENT' "$TMP/permission-not-found.out"; then
  no "a denied read is never reported absent" "UNKNOWN" "ABSENT"
else
  ok "a denied read is never reported absent"
fi

printf '\nscenario: attribution is applied here, not delegated to a provider filter\n'
for attribution_filter in 'name~' 'bindings.members=' 'labels.goog-k8s-cluster-name'; do
  if grep -qF -- "$attribution_filter" "$TMP/inventory-row-shape.argv"; then
    no "attribution is not delegated to a provider filter ($attribution_filter)" \
      "no attribution filter" "present in the argv"
  else
    ok "attribution is not delegated to a provider filter ($attribution_filter)"
  fi
done
has "the enumeration asks for the whole class" \
  "compute forwarding-rules list --project sol-qualification --format=json" \
  "$TMP/inventory-row-shape.argv"

printf '\nscenario: a GKE-named load-balancer resource is attributable by its address\n'
PRESEED_LB_ADDRESS=34.0.0.1 run_case lb-address-attribution destroy STUB_LB_ADDRESS=1
has "the hashed forwarding rule is attributable by its address" \
  "forwarding-rules: PRESENT (a1b2c3d4" "$TMP/lb-address-attribution.out"
if [ "$(cat "$TMP/lb-address-attribution.rc")" = "0" ]; then
  no "residue with a hashed name fails the verification" "non-zero" "0"
else
  ok "residue with a hashed name fails the verification"
fi

printf '\nscenario: an unrelated resource in the class is not the target residue\n'
run_case disk-unrelated verify STUB_DISK_HASHED=1
has "an unattributable disk reads ABSENT" "disks: ABSENT" "$TMP/disk-unrelated.out"
is "and the verification passes" "$(cat "$TMP/disk-unrelated.rc")" "0"

printf '\nscenario: an enumeration whose shape is wrong is UNKNOWN, not absent\n'
run_case forwarding-wrong-shape verify STUB_FORWARDING_WRONG_SHAPE=1
has "a document without the attribution fields is UNKNOWN" \
  "forwarding-rules: UNKNOWN" "$TMP/forwarding-wrong-shape.out"
has "and the report says it could not decode the shape" \
  "shape is not one this class can decode" "$TMP/forwarding-wrong-shape.out"
if [ "$(cat "$TMP/forwarding-wrong-shape.rc")" = "0" ]; then
  no "a wrong-shaped enumeration does not verify" "non-zero" "0"
else
  ok "a wrong-shaped enumeration does not verify"
fi

printf '\nscenario: cluster-name attribution uses component boundaries\n'
for candidate in test-cluster-router prefix-test-cluster-extra test-cluster; do
  run_case "disk-name-match-$candidate" verify "STUB_DISK_NAME=$candidate"
  has "a name carrying the cluster at a boundary is residue ($candidate)" \
    "disks: PRESENT" "$TMP/disk-name-match-$candidate.out"
  if [ "$(cat "$TMP/disk-name-match-$candidate.rc")" = "0" ]; then
    no "boundary match fails the verification ($candidate)" "non-zero" "0"
  else
    ok "boundary match fails the verification ($candidate)"
  fi
done
for candidate in test-clustered-router test-cluster2-router; do
  run_case "disk-name-no-match-$candidate" verify "STUB_DISK_NAME=$candidate"
  has "a name that only embeds the cluster is not residue ($candidate)" \
    "disks: ABSENT" "$TMP/disk-name-no-match-$candidate.out"
  is "an unrelated similarly named disk verifies ($candidate)" \
    "$(cat "$TMP/disk-name-no-match-$candidate.rc")" "0"
done

printf '\nscenario: a child read that names only its parent\n'
run_case nat-parent-absent verify STUB_NAT_PARENT_MISSING=1
has "the router is independently absent" "router: ABSENT" "$TMP/nat-parent-absent.out"
has "the NAT follows its absent parent" "nat: ABSENT" "$TMP/nat-parent-absent.out"
is "and the verification passes" "$(cat "$TMP/nat-parent-absent.rc")" "0"

run_case nat-parent-ambiguous verify STUB_ROUTER_PRESENT=1 STUB_NAT_AMBIGUOUS=1
has "the router is present" "router: PRESENT" "$TMP/nat-parent-ambiguous.out"
has "the NAT read is UNKNOWN, not absent" "nat: UNKNOWN" "$TMP/nat-parent-ambiguous.out"
has "and the report says which resource is ambiguous" \
  "which resource is missing is ambiguous" "$TMP/nat-parent-ambiguous.out"
if [ "$(cat "$TMP/nat-parent-ambiguous.rc")" = "0" ]; then
  no "an ambiguous child read does not verify" "non-zero" "0"
else
  ok "an ambiguous child read does not verify"
fi

printf '\nscenario: a prior identity record from another scope is not used\n'
PRESEED_FOREIGN_PRIOR_IDENTITIES=$'forwarding-rules\ta1b2c3d4' \
  run_case prior-identities-foreign verify STUB_LB_ADDRESS=1
has "the foreign identity does not make the rule residue" \
  "forwarding-rules: ABSENT" "$TMP/prior-identities-foreign.out"
has "and the report says the record was ignored" \
  "belongs to another attempt or scope" "$TMP/prior-identities-foreign.out"
is "so the verification passes" "$(cat "$TMP/prior-identities-foreign.rc")" "0"

printf '\nscenario: the post inventory accounts for what the pre inventory attributed\n'
PRESEED_PRIOR_IDENTITIES=$'forwarding-rules\ta1b2c3d4' run_case prior-identity-residue verify STUB_LB_ADDRESS=1
has "a rule that no longer matches by name is still residue" \
  "forwarding-rules: PRESENT (a1b2c3d4" "$TMP/prior-identity-residue.out"
if [ "$(cat "$TMP/prior-identity-residue.rc")" = "0" ]; then
  no "the surviving recorded identity fails the verification" "non-zero" "0"
else
  ok "the surviving recorded identity fails the verification"
fi

printf '\nscenario: a complete post inventory that no longer holds the record is clean\n'
PRESEED_PRIOR_IDENTITIES=$'forwarding-rules\ta1b2c3d4' run_case prior-identity-cleared verify
has "the recorded identity is gone" "forwarding-rules: ABSENT" "$TMP/prior-identity-cleared.out"
is "and a complete, same-scope post inventory passes" \
  "$(cat "$TMP/prior-identity-cleared.rc")" "0"

printf '\nscenario: no contradictory configuration is ever rendered\n\'
if cat "$TMP"/*.argv | grep -qE 'create_dns_zone=true'; then
  no "no invocation asks for the durable zone to be created" "no create_dns_zone=true" "rendered somewhere"
else
  ok "no invocation asks for the durable zone to be created"
fi

printf '\nscenario: the durable root would be replaced\n'
run_case durable-refusal cloud STUB_INSTALL_REFUSED=1
if [ "$(cat "$TMP/durable-refusal.rc")" = "0" ]; then
  no "a plan that would replace a durable prerequisite refuses" "non-zero" "0"
else
  ok "a plan that would replace a durable prerequisite refuses"
fi
has "the refusal names the durable risk" "REFUSED" "$TMP/durable-refusal.out"
has "the refused whole-target deploy is the only mutation attempted" "sol deploy" "$TMP/durable-refusal.argv"
lacks "an unresolved installation never tears down a disposable target it did not apply" "sol destroy" "$TMP/durable-refusal.argv"

printf '\nscenario: platform subcommand\n'
run_case platform-refused platform
is "exit 2" "$(cat "$TMP/platform-refused.rc")" "2"
has "the refusal points at the invocation that installs the platform" "sol deploy" "$TMP/platform-refused.out"
lacks "the refused phase runs nothing" "sol deploy" "$TMP/platform-refused.argv"

printf '\nscenario: process discipline\n'
grep -vE '^[[:space:]]*#' "$HARNESS" >"$TMP/harness-code.sh"
for forbidden in 'pkill' 'killall' 'force-unlock' 'kill -9' 'kill -KILL' 'kill -s KILL'; do
  if grep -qF -- "$forbidden" "$TMP/harness-code.sh"; then
    no "the harness contains no '$forbidden' in code" "absent" "present"
  else
    ok "the harness contains no '$forbidden' in code"
  fi
done
if grep -qF 'kill -TERM "$run_pid"' "$HARNESS"; then
  ok "stopping signals the recorded run by its own pid (identity, not pattern)"
else
  no "stopping signals the recorded run by its own pid (identity, not pattern)" 'kill -TERM "$run_pid"' "missing"
fi
if grep -qE 'kill +-[A-Za-z0-9]* +-' "$TMP/harness-code.sh"; then
  no "stopping never signals a whole process group, which would kill Terraform in flight" \
    "no group kill" "present"
else
  ok "stopping never signals a whole process group, which would kill Terraform in flight"
fi
if grep -qF 'run.pid' "$HARNESS"; then
  ok "the run records its own pid"
else
  no "the run records its own pid" "run.pid" "missing"
fi
terminate_body="$(sed -n '/^on_terminate()/,/^}/p' "$HARNESS")"
if [ -n "$terminate_body" ] && ! printf '%s' "$terminate_body" | grep -qE '\bkill\b'; then
  ok "the SIGTERM trap tears down without killing the Terraform in flight"
else
  no "the SIGTERM trap tears down without killing the Terraform in flight" \
    "an on_terminate body with no kill" "missing, or it kills"
fi

run_case_closed_stdout() {
  local name="$1" sub="$2"
  shift 2
  export ARGV_LOG="$TMP/$name.argv"
  export TMP
  export API_PROBE_LOG="$TMP/$name.probe.argv"
  CURRENT_CASE="$name"
  export LOG_DIR="$TMP/$name.logs"
  export WORKSPACE="$SCRATCH_WS"
  export XDG_DATA_HOME="$TMP/data"
  export STUB_KUBECONFIG_FIXTURE="$REPO/internal/qualification/gcp/fixtures/kubeconfig-gcloud-real.yaml"
  export STUB_PROVISIONER_SA="test-cluster-provisioner@sol-qualification.iam.gserviceaccount.com"
  : >"$ARGV_LOG"
  : >"$API_PROBE_LOG"
  rm -f "$TARGET_FILE"
  rm -rf "$LOG_DIR"
  env ALLOW_CANONICAL=1 SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" CLUSTER=test-cluster \
    IMPERSONATOR=user:test@example.com LE_EMAIL=test@example.com \
    PROJECT=sol-qualification REGION=us-central1 \
    PATH="$TMP/bin:$PATH" "$@" \
    "$HARNESS" "$sub" 2>"$TMP/$name.err" | true
  local -a codes=("${PIPESTATUS[@]}")
  printf '%s\n' "${codes[0]}" >"$TMP/$name.rc"
}

run_case_sigterm() {
  local name="$1" signal="$2"
  shift 2
  export ARGV_LOG="$TMP/$name.argv"
  export TMP
  export API_PROBE_LOG="$TMP/$name.probe.argv"
  CURRENT_CASE="$name"
  export LOG_DIR="$TMP/$name.logs"
  export WORKSPACE="$SCRATCH_WS"
  export XDG_DATA_HOME="$TMP/data"
  export STUB_KUBECONFIG_FIXTURE="$REPO/internal/qualification/gcp/fixtures/kubeconfig-gcloud-real.yaml"
  export STUB_PROVISIONER_SA="test-cluster-provisioner@sol-qualification.iam.gserviceaccount.com"
  : >"$ARGV_LOG"
  : >"$API_PROBE_LOG"
  rm -f "$TARGET_FILE"
  rm -rf "$LOG_DIR"
  env ALLOW_CANONICAL=1 SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" CLUSTER=test-cluster \
    IMPERSONATOR=user:test@example.com LE_EMAIL=test@example.com \
    PROJECT=sol-qualification REGION=us-central1 \
    PATH="$TMP/bin:$PATH" "$@" \
    "$HARNESS" cloud >"$TMP/$name.out" 2>&1 &
  local run_pid=$! waited=0
  while [ ! -e "$LOG_DIR/cloud-apply.log" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -"$signal" "$run_pid" 2>/dev/null || true
  wait "$run_pid"
  printf '%s\n' "$?" >"$TMP/$name.rc"
}

printf '\nscenario: the harness survives a closed stdout reader and still tears down (attempt-5 shape)\n'
run_case_closed_stdout sigpipe cloud STUB_APPLY_RC=1 STUB_CLUSTER_EXISTS=1
is "the phase still fails" "$(cat "$TMP/sigpipe.rc")" "1"
has "the teardown runs even though stdout is gone" "sol destroy" "$TMP/sigpipe.argv"
present "$TMP/sigpipe.logs/inventory-post.tsv" "the independent post-teardown inventory is captured"
has "the harness narrative records the teardown" "teardown: sol destroy" \
  "$TMP/sigpipe.logs/harness.log"
has "and the failure that preceded it" "did not reconcile the environment" "$TMP/sigpipe.logs/harness.log"

printf '\nscenario: SIGTERM tears down and verifies absence without killing Terraform in flight\n'
run_case_sigterm sigterm TERM STUB_APPLY_RC=1 STUB_CLUSTER_EXISTS=1 STUB_SOL_SLEEP=3
is "the terminated run exits non-zero" "$(cat "$TMP/sigterm.rc")" "1"
has "the teardown runs on TERM" "sol destroy" "$TMP/sigterm.argv"
present "$TMP/sigterm.logs/inventory-post.tsv" "the independent post-teardown inventory is captured"
has "the harness records the signal" "received SIGTERM" "$TMP/sigterm.logs/harness.log"



creds_case() {
  local name="$1" configured="$2"
  shift 2
  local kc="$TMP/kc-$name.yaml"
  printf 'apiVersion: v1\nclusters:\n- cluster:\n    server: https://%s\n  name: c\n' \
    "$configured" >"$kc"
  run_case "creds-$name" cloud KUBECONFIG="$kc" "$@"
}

creds_case sampling 136.115.125.189 STUB_CLUSTER_EXISTS=1
sampling_kc="$TMP/creds-sampling.logs/run-kubeconfig.yaml"
sampling_name_line="$(grep -n -m1 '^  name:' "$sampling_kc" | cut -d: -f1)"
sampling_server_line="$(grep -n -m1 '^    server:' "$sampling_kc" | cut -d: -f1)"
is "the run-owned kubeconfig is the gcloud shape the shell matcher could not read: name after the cluster block" \
  "$sampling_name_line" "$(( ${sampling_server_line:-0} + 1 ))"
has "and it names this run's cluster, at the fixture's endpoint" "server: https://34.0.0.1" "$sampling_kc"
lacks "and no cluster of another run appears in it" "sol-qual-gcp-15c" "$sampling_kc"
amb="$TMP/ambient-kubeconfig.yaml"
{
  printf 'apiVersion: v1\nkind: Config\ncurrent-context: eks-stale\n'
  printf 'clusters:\n'
  printf -- '- name: eks-stale\n  cluster:\n    server: https://9F5AAA970F948E45A7AE0807DA893DCE.gr7.us-east-1.eks.amazonaws.com\n'
  printf -- '- name: gke_old_us-central1_sol-qual-gcp-15c\n  cluster:\n    server: https://136.115.125.189\n'
  printf 'contexts:\n- name: eks-stale\n  context:\n    cluster: eks-stale\n    user: u\n'
  printf 'users:\n- name: u\n  user:\n    token: x\n'
} >"$amb"

run_case "e2e-credentials" cloud KUBECONFIG="$amb" STUB_SOL_SLEEP=6 \
  CLUSTER_KUBECONFIG_POLL_S=1 STUB_STATUS_FAILS_N=3 STUB_APPLY_RC=1 STUB_CLUSTER_EXISTS=1

has "the waiter recorded a poll that found no cluster" "poll-failed" \
  "$TMP/e2e-credentials.logs/kubeconfig-waiter.tsv"
has "and then an establishment on the RUNNING path" "credentials-established" \
  "$TMP/e2e-credentials.logs/kubeconfig-waiter.tsv"
lacks "the waiter did not exit on the absent cluster" "parent-gone" "$TMP/e2e-credentials.logs/kubeconfig-waiter.tsv"

est="$(grep -n 'run kubeconfig: established' "$TMP/e2e-credentials.out" | head -1 | cut -d: -f1)"
fail_line="$(grep -n 'did not reconcile the environment' "$TMP/e2e-credentials.out" | head -1 | cut -d: -f1)"
if [ -n "$est" ] && [ -n "$fail_line" ] && [ "$est" -lt "$fail_line" ]; then
  ok "run credentials are established before the failure, not by it (line $est < $fail_line)"
else
  no "run credentials are established before the failure, not by it" "established before the failure" \
    "established at line ${est:-never}, failure at ${fail_line:-never}"
fi
has "the run kubeconfig exists and names this run's cluster" "test-cluster" \
  "$TMP/e2e-credentials.logs/run-kubeconfig.yaml"

if grep -qF "kubeconfig=$TMP/e2e-credentials.logs/run-kubeconfig.yaml" "$TMP/e2e-credentials.argv"; then
  ok "every kubectl read is bound to the run's kubeconfig"
else
  no "every kubectl read is bound to the run's kubeconfig" "the run kubeconfig in the argv log" \
    "$(grep -m1 kubectl "$TMP/e2e-credentials.argv" 2>/dev/null | cut -c1-90)"
fi

freeze_line="$(grep -n 'freezing the evidence bundle' "$TMP/e2e-credentials.out" | head -1 | cut -d: -f1)"
kube_line="$(grep -n 'capturing read-only Kubernetes evidence' "$TMP/e2e-credentials.out" | head -1 | cut -d: -f1)"
teardown_line="$(grep -n 'teardown: sol destroy' "$TMP/e2e-credentials.out" | head -1 | cut -d: -f1)"
if [ -n "$freeze_line" ] && [ -n "$kube_line" ] && [ "$freeze_line" -lt "$kube_line" ]; then
  ok "the bundle is frozen before the heavy Kubernetes reads (line $freeze_line < $kube_line)"
else
  no "the bundle is frozen before the heavy Kubernetes reads" "freeze before the kube capture" \
    "freeze at ${freeze_line:-never}, kube capture at ${kube_line:-never}"
fi
if [ -n "$teardown_line" ] && [ -n "$freeze_line" ] && [ "$freeze_line" -lt "$teardown_line" ]; then
  ok "and before the teardown (line $freeze_line < $teardown_line)"
else
  no "and before the teardown" "freeze before teardown" \
    "freeze at ${freeze_line:-never}, teardown at ${teardown_line:-never}"
fi
lacks "the bundle is complete on the failure path" "the evidence bundle is INCOMPLETE" \
  "$TMP/e2e-credentials.out"

lacks "no capture command was malformed" "unknown command" "$TMP/e2e-credentials.out"
for artifact in pods pod-states pod-demand events pvc pv nodes node-capacity node-taints \
    helm-release-secrets; do
  present "$TMP/e2e-credentials.logs/platform-failure/$artifact.log" "the failure capture produced $artifact"
done
for artifact in pod-demand node-taints; do
  has "the capture summary accounts for $artifact" "$artifact" \
    "$TMP/e2e-credentials.logs/platform-failure/capture-summary.txt"
done
has "the pod demand capture keeps the requests an unschedulable pod asked for" \
  "requests=map[cpu:1 memory:2Gi]" "$TMP/e2e-credentials.logs/platform-failure/pod-demand.log"
has "and the scheduler's own verdict on it" "PodScheduled=False(Unschedulable)" \
  "$TMP/e2e-credentials.logs/platform-failure/pod-demand.log"
has "the node taint capture keeps a taint that can keep a pod off a node" "effect:NoSchedule" \
  "$TMP/e2e-credentials.logs/platform-failure/node-taints.log"

creds_case neverready 136.115.125.189 STUB_GET_CREDENTIALS_RC=1 STUB_APPLY_RC=1 \
  STUB_CLUSTER_EXISTS=1
has "a capture that could not get credentials says so" "could not establish credentials" \
  "$TMP/creds-neverready.logs/platform-failure/NO-KUBECONFIG.txt"
has "and the summary records the credential state" "credentials for test-cluster: no" \
  "$TMP/creds-neverready.logs/platform-failure/capture-summary.txt"
has "the summary lists every artifact it attempted" "helm-release-secrets" \
  "$TMP/creds-neverready.logs/platform-failure/capture-summary.txt"

creds_case readfails 136.115.125.189 STUB_APPLY_RC=1 STUB_CLUSTER_EXISTS=1 STUB_KUBE_READ_RC=1
has "a failed capture read records the failure in the artifact" "Error from server" \
  "$TMP/creds-readfails.logs/platform-failure/pods.log"

printf '\nscenario: a stop before the platform is a complete bundle\n'
run_case bundle-pre-platform cloud STUB_APPLY_RC=1 STUB_APPLY_FAILS_AT=bootstrap
lacks "a root the run never reached is not demanded of the bundle" \
  "bundle member missing or empty: state/platform.tfstate" "$TMP/bundle-pre-platform.out"
present "$TMP/bundle-pre-platform.logs/state/cloud.tfstate" \
  "the root the run reached still has its state in the bundle"
has "the pre-platform stop is recorded as such" "[cloud-bootstrap-apply] FAILED" \
  "$TMP/bundle-pre-platform.out" \
  || true
present "$TMP/bundle-pre-platform.logs/platform-failure/capture-summary.txt" \
  "the failure capture completes even when the cluster is absent"
present "$TMP/bundle-pre-platform.logs/platform-failure/NO-KUBECONFIG.txt" \
  "and records that no credential bound to this run existed"

printf '\nscenario: a platform state object the run could not capture is recorded, not demanded\n'
run_case bundle-platform-reached cloud STUB_APPLY_RC=1 STUB_APPLY_ERROR=already-exists \
  STUB_STATE_UNREADABLE=1
has "the manifest records the state object it could not capture" \
  "terraform state (platform)  MISSING" "$TMP/bundle-platform-reached.logs/evidence-manifest.txt"
has "and the read that could not establish it is kept" "COULD NOT READ" "$TMP/bundle-platform-reached.out"
lacks "which does not by itself make the bundle incomplete" \
  "bundle member missing or empty: state/platform.tfstate" "$TMP/bundle-platform-reached.out"

printf '\nscenario: an unreadable bundle member\n'
lacks "a complete bundle is not reported as incomplete" "evidence bundle is INCOMPLETE" "$TMP/cloud-fail.out"
run_case bundle-unreadable cloud STUB_APPLY_RC=1 STUB_CLUSTER_EXISTS=1 STUB_STATE_UNREADABLE=1
has "a state object the run could not read is recorded as such" "COULD NOT READ" "$TMP/bundle-unreadable.out"
lacks "which does not by itself make the bundle incomplete" \
  "bundle member missing or empty: state/cloud.tfstate" "$TMP/bundle-unreadable.out"

printf '\nscenario: a successful list that warns on stderr\n'
run_case filter-warning destroy STUB_FILTER_WARNING=1
if grep -q 'address-regional: PRESENT' "$TMP/filter-warning.out"; then
  no "the warning is not read as a resource" "address-regional: ABSENT" "PRESENT"
else
  ok "the warning is not read as a resource"
fi
is "the warned verification still passes" "$(cat "$TMP/filter-warning.rc")" "0"

# A destroyed cluster's CSI disks are named `pvc-<uuid>`, so only the GKE cluster label
# attributes them. A `name` filter read them as absent; the label filter must fail the run.
printf '\nscenario: a destroyed cluster'"'"'s CSI disks are visible to the absence probe\n'
PRESEED_TARGET=1 run_case verify-disk-residue verify STUB_DISK_RESIDUE=1
if [ "$(cat "$TMP/verify-disk-residue.rc")" = "0" ]; then
  no "the disk residue fails verification" "non-zero" "0"
else
  ok "the disk residue fails verification"
fi
has "and the report names the disk class" "disks still exists" "$TMP/verify-disk-residue.out"

printf '\nscenario: verify is read-only even when it fails\n'
PRESEED_TARGET=1 run_case verify-fail verify STUB_TARGET_PRESENT=1
if [ "$(cat "$TMP/verify-fail.rc")" = "0" ]; then
  no "a failing verification exits non-zero" "non-zero" "0"
else
  ok "a failing verification exits non-zero"
fi
lacks "a failing verification invokes no teardown, even with a target file present" "sol destroy" "$TMP/verify-fail.argv"
has "it still reports what it saw" "resources remain" "$TMP/verify-fail.out"
PRESEED_TARGET=1 run_case verify-clean verify
is "a clean verification exits 0" "$(cat "$TMP/verify-clean.rc")" "0"
lacks "a clean verification invokes no teardown" "sol destroy" "$TMP/verify-clean.argv"
if grep -q 'NOT_FOUND: Unknown service account' "$HERE/test-live-qual.sh"; then
  ok "the not-found fixture is the provider's captured wording (underscore form), not a paraphrase"
else
  no "the not-found fixture is the provider's captured wording (underscore form), not a paraphrase" \
    "NOT_FOUND: Unknown service account" "absent"
fi

printf '\nscenario: the target key is overridable\n'
TARGET=qual9/gcp/us-central1 run_case target-override destroy
has "the override reaches sol" "sol destroy qual9/gcp/us-central1" "$TMP/target-override.argv"
has "and names the state objects it will read" "sol/qual9/gcp/us-central1/cloud.tfstate" "$TMP/target-override.argv"
if grep -q 'sol/qual/gcp/us-central1/' "$TMP/target-override.argv"; then
  no "the default key is not silently used as well" "no sol/qual/ path" "found one"
else
  ok "the default key is not silently used as well"
fi

printf '\nscenario: Attempt-9-shaped teardown verifies\n'
run_case attempt9-verified destroy
is "a clean teardown with a provider-deleted identity and role verifies" "$(cat "$TMP/attempt9-verified.rc")" "0"
has "the fixture asked about the harness's own provisioner identity" "$STUB_PROVISIONER_SA" "$TMP/attempt9-verified.argv"
has "the identity class is ABSENT for the right reason" "service-account-provisioner: ABSENT" "$TMP/attempt9-verified.out"
has "and names the authoritative observable" "not in the active list" "$TMP/attempt9-verified.out"
has "the binding class is ABSENT for the right reason" "impersonator-binding: ABSENT" "$TMP/attempt9-verified.out"
has "and names the implication, not a relabelled denial" "cannot be impersonated" "$TMP/attempt9-verified.out"
has "the role class is ABSENT for the right reason" "custom-role: ABSENT" "$TMP/attempt9-verified.out"
has "and reports the provider's own deletion marker" "provider-deleted" "$TMP/attempt9-verified.out"
has "the raw deletion marker is preserved in the bundle" "True" "$TMP/attempt9-verified.logs/inventory-custom-role.log"
has "the raw describe answer for the deleted identity is preserved" "PERMISSION_DENIED" "$TMP/attempt9-verified.logs/inventory-service-account-provisioner.describe.log"
if grep -q 'could NOT determine absence' "$TMP/attempt9-verified.out"; then
  no "nothing is left UNKNOWN in this shape" "no UNKNOWN" "$(grep -m1 'could NOT determine' "$TMP/attempt9-verified.out")"
else
  ok "nothing is left UNKNOWN in this shape"
fi

printf '\nscenario: the identity is still active\n'
run_case mutation-sa-active destroy STUB_SA_ACTIVE_PROVISIONER=1 STUB_SA_POLICY=empty
if [ "$(cat "$TMP/mutation-sa-active.rc")" = "0" ]; then
  no "an active provisioner identity fails the verification" "non-zero" "0"
else
  ok "an active provisioner identity fails the verification"
fi
has "and is reported PRESENT" "service-account-provisioner: PRESENT" "$TMP/mutation-sa-active.out"

printf '\nscenario: the impersonation grant is still there\n'
run_case mutation-binding-present destroy STUB_SA_ACTIVE_PROVISIONER=1 STUB_SA_POLICY=binding
if [ "$(cat "$TMP/mutation-binding-present.rc")" = "0" ]; then
  no "a surviving impersonator binding fails the verification" "non-zero" "0"
else
  ok "a surviving impersonator binding fails the verification"
fi
has "and is reported PRESENT" "impersonator-binding: PRESENT" "$TMP/mutation-binding-present.out"

printf '\nscenario: the role is still active\n'
run_case mutation-role-active destroy STUB_ROLE_STATE=active
if [ "$(cat "$TMP/mutation-role-active.rc")" = "0" ]; then
  no "an active custom role fails the verification" "non-zero" "0"
else
  ok "an active custom role fails the verification"
fi
has "and is reported PRESENT" "custom-role: PRESENT" "$TMP/mutation-role-active.out"

printf '\nscenario: the policy read is denied while the identity is active\n'
run_case mutation-policy-denied destroy STUB_SA_ACTIVE_PROVISIONER=1
has "the binding class is UNKNOWN when its read is ambiguous" "impersonator-binding: UNKNOWN" "$TMP/mutation-policy-denied.out"
if [ "$(cat "$TMP/mutation-policy-denied.rc")" = "0" ]; then
  no "ambiguous policy evidence does not verify" "non-zero" "0"
else
  ok "ambiguous policy evidence does not verify"
fi

printf '\nscenario: the authoritative collection itself fails\n'
run_case mutation-list-fails destroy STUB_SA_LIST_FAIL=1
has "a failed authoritative list is UNKNOWN, never absent" "service-account-provisioner: UNKNOWN" "$TMP/mutation-list-fails.out"
has "and the binding does not guess either" "impersonator-binding: UNKNOWN" "$TMP/mutation-list-fails.out"
if [ "$(cat "$TMP/mutation-list-fails.rc")" = "0" ]; then
  no "an unreadable authority collection does not verify" "non-zero" "0"
else
  ok "an unreadable authority collection does not verify"
fi

printf '\nscenario: the role is genuinely not found / unreadable\n'
run_case role-notfound destroy STUB_ROLE_STATE=notfound
is "a not-found role verifies" "$(cat "$TMP/role-notfound.rc")" "0"
run_case role-unreadable destroy STUB_ROLE_STATE=error
has "an unreadable role is UNKNOWN" "custom-role: UNKNOWN" "$TMP/role-unreadable.out"

printf '\nscenario: the harness passes no dead argument\n'
run_case cloud-vars cloud
lacks "no command-not-found diagnostic" "command not found" "$TMP/cloud-vars.out"
has "the generated target carries the impersonator" "provisioner_impersonator: user:test@example.com" "$TARGET_FILE"
lacks "and the cloud path passes no second copy of it" "-var=provisioner_impersonators" "$TMP/cloud-vars.argv"

identity_verdict() { awk -F'\t' -v c="$1" '$1==c{print $2}' "$2"; }

printf '\nscenario: the identity capture records the VERIF-021 / VERIF-022 mechanism facts\n'
PRESEED_CREDENTIALS=1 PRESEED_INVENTORY=1 run_case identity-capture identity STUB_CLUSTER_EXISTS=1
is "the identity phase exits 0" "$(cat "$TMP/identity-capture.rc")" "0"
present "$TMP/identity-capture.logs/identity/identity.tsv" "the identity read is in the bundle"
is "the GKE Secret Manager add-on is recorded present" \
  "$(identity_verdict gke-secret-manager-addon "$TMP/identity-capture.logs/identity/identity.tsv")" "PRESENT"
has "with its rotation interval" "rotation interval 2m" \
  "$TMP/identity-capture.logs/identity/identity.tsv"
is "the OIDC discovery document is recorded present" \
  "$(identity_verdict cluster-oidc-discovery "$TMP/identity-capture.logs/identity/identity.tsv")" "PRESENT"
is "no rendered projected-token volume is recorded positively absent" \
  "$(identity_verdict projected-token-volumes "$TMP/identity-capture.logs/identity/identity.tsv")" "ABSENT"
is "and no sol- secret exists yet, recorded as absent" \
  "$(identity_verdict secret-manager-grants "$TMP/identity-capture.logs/identity/identity.tsv")" "ABSENT"
has "the identity summary is in the bundle" "VERIF-021 / VERIF-022 mechanism capture" \
  "$TMP/identity-capture.logs/identity/summary.txt"

printf '\nscenario: the identity capture surfaces present facts\n'
PRESEED_CREDENTIALS=1 PRESEED_INVENTORY=1 run_case identity-present identity \
  STUB_CLUSTER_EXISTS=1 STUB_SECRETS_PRESENT=1 STUB_PROJECTED_TOKENS=1
is "the granted secret's policy is recorded present" \
  "$(identity_verdict secret-manager-grants "$TMP/identity-present.logs/identity/identity.tsv")" "PRESENT"
is "and the rendered projected token is recorded present" \
  "$(identity_verdict projected-token-volumes "$TMP/identity-present.logs/identity/identity.tsv")" "PRESENT"
has "with its audience and expiry" "aud=order-svc exp=3600" \
  "$TMP/identity-present.logs/identity/projected-tokens.txt"

printf '\nscenario: adversarial — an unreadable identity read is UNKNOWN, never absent\n'
PRESEED_CREDENTIALS=1 PRESEED_INVENTORY=1 run_case identity-cluster-unknown identity \
  STUB_CLUSTER_EXISTS=1 STUB_CLUSTER_JSON_FAIL=1
is "an unreadable cluster read is UNKNOWN" \
  "$(identity_verdict gke-secret-manager-addon "$TMP/identity-cluster-unknown.logs/identity/identity.tsv")" "UNKNOWN"
PRESEED_CREDENTIALS=1 PRESEED_INVENTORY=1 run_case identity-oidc-unknown identity \
  STUB_CLUSTER_EXISTS=1 STUB_OIDC_FAIL=1
is "a non-200 issuer read is UNKNOWN, not absent" \
  "$(identity_verdict cluster-oidc-discovery "$TMP/identity-oidc-unknown.logs/identity/identity.tsv")" "UNKNOWN"
PRESEED_CREDENTIALS=1 PRESEED_INVENTORY=1 run_case identity-secrets-unknown identity \
  STUB_CLUSTER_EXISTS=1 STUB_SECRETS_LIST_FAIL=1
is "an unreadable secret list is UNKNOWN" \
  "$(identity_verdict secret-manager-grants "$TMP/identity-secrets-unknown.logs/identity/identity.tsv")" "UNKNOWN"
PRESEED_CREDENTIALS=1 PRESEED_INVENTORY=1 run_case identity-pods-unknown identity \
  STUB_CLUSTER_EXISTS=1 STUB_KUBE_READ_RC=1
is "an unreadable pod list is UNKNOWN" \
  "$(identity_verdict projected-token-volumes "$TMP/identity-pods-unknown.logs/identity/identity.tsv")" "UNKNOWN"

printf '\nscenario: the identity phase needs a target credential like every other phase\n'
run_case identity-nocred identity
is "it exits 2 with no run kubeconfig" "$(cat "$TMP/identity-nocred.rc")" "2"
has "and says why" "no run kubeconfig" "$TMP/identity-nocred.out"

printf '\nscenario: provider authority and delivered values cannot disagree\n'
for delivery_mode in denied mismatch; do
  STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case "kafka-delivery-$delivery_mode" app "STUB_KAFKA_DELIVERY=$delivery_mode"
  is "$delivery_mode blocks application qualification" "$(cat "$TMP/kafka-delivery-$delivery_mode.rc")" "1"
  lacks "no credential writes repair $delivery_mode" "secret set" "$TMP/kafka-delivery-$delivery_mode.argv"
done
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-secret-false-success app STUB_SECRET_PROBE_RC=0
is "false success of a missing application secret fails qualification" "$(cat "$TMP/app-secret-false-success.rc")" "1"
lacks "captured state metadata excludes database credentials" "qual-secret" "$TMP/app-ok.logs/state/cloud.tfstate"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ] || exit 1
dirty="$(git -C "$REPO" status --porcelain --untracked-files=all -- examples/pluto/)"
if [ -n "$dirty" ]; then
  printf '[FAIL] the suite left the checkout dirty:\n%s\n' "$dirty"; exit 1
fi
printf 'checkout clean\n'
