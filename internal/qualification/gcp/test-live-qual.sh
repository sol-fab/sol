#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$HERE/live-qual.sh"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
export ATTEMPT="${ATTEMPT:-qual-self-test}"
export TARGET="${TARGET:-qual/gcp/us-central1}"

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

suite_environment

mkdir -p "$TMP/bin"

VERSION="v0.1.0-alpha.7"
DIGEST64="$(printf 'a%.0s' $(seq 1 64))"
RUNNER="ghcr.io/example/sol-migration-runner:$VERSION@sha256:$DIGEST64"
INSTALL="$TMP/install"

bundle() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/share/sol/$VERSION/platform/shared" \
    "$dir/share/sol/$VERSION/platform/cloud/gcp/bootstrap"
  printf '{\n  "components": {}\n}\n' >"$dir/share/sol/$VERSION/platform/shared/components.json"
  cat >"$dir/bin/sol" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' "${STUB_SOL_VERSION:-v0.1.0-alpha.7}"
  exit 0
fi
printf 'sol %s [runner=%s]\n' "$*" "${SOL_MIGRATION_RUNNER_IMAGE:-unset}" >>"$ARGV_LOG"
if [ -n "${STUB_SOL_SLEEP:-}" ]; then sleep "$STUB_SOL_SLEEP"; fi
case "$1" in
  deploy)
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
        printf 'The environment for %s is reconciled.\n' "$2"
      fi
      [ "${STUB_APPLY_RC:-0}" = "0" ]
    else
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
gcloud_log_to="$ARGV_LOG"
case " $* " in *"value(endpoint)"*) gcloud_log_to="${API_PROBE_LOG:-$ARGV_LOG}" ;; esac
printf "gcloud %s" "$*" >>"$gcloud_log_to"; printf "\n" >>"$gcloud_log_to"
case "$*" in
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
      printf '{"version":4,"serial":7,"resources":[],"outputs":{"postgres_url":{"value":"postgresql://postgres:qual-secret@10.172.0.3/app","type":"string","sensitive":true}}}\n'
      exit 0
    fi
    printf '{"version":4,"serial":7,"resources":[]}\n'; exit 0 ;;
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
    exit 0 ;;
  *"compute regions describe"*)
    if [ "${STUB_QUOTA_GARBAGE:-0}" = "1" ]; then printf "not a quota document\n"; exit 0; fi
    if [ "${STUB_QUOTA_BUSY:-0}" = "1" ]; then printf "CPUS;IN_USE_ADDRESSES;SSD_TOTAL_GB;DISKS_TOTAL_GB;INSTANCES,4;0;0;0;1\n"; exit 0; fi
    printf "CPUS;IN_USE_ADDRESSES;SSD_TOTAL_GB;DISKS_TOTAL_GB;INSTANCES,0;0;0;0;0\n"; exit 0 ;;
  # A GKE CSI disk is named `pvc-<uuid>`, so it is attributable only by the cluster label.
  # The stub honors that filter, so the disk-absence scenario below fails against a `name`
  # filter and passes against the label one.
  *"compute disks list"*)
    case " $* " in
      *"labels.goog-k8s-cluster-name=$CLUSTER"*)
        if [ "${STUB_DISK_RESIDUE:-0}" = "1" ]; then printf 'pvc-residue\n'; fi
        exit 0 ;;
    esac
    exit 0 ;;
  *"compute instances list"*|*"compute disks list"*|*"compute snapshots list"*)
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
      binding) printf "roles/iam.serviceAccountTokenCreator\n"; exit 0 ;;
      empty)   exit 0 ;;
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
  "create secret generic"*)
    if [ "${STUB_SECRET_CREATE_FAILS:-0}" = "1" ]; then
      printf 'Error from server (Forbidden): secrets "redpanda-users" is forbidden\n' >&2
      exit 1
    fi
    : >"${TMP:-/tmp}/credential-supplied"
    printf 'secret/redpanda-users created\n'
    exit 0 ;;
  "get secret redpanda-users"*)
    printf '%s' 'sol-workloads:testpass:SCRAM-SHA-256' | base64
    exit 0 ;;
  "get secret redpanda-default-cert"*)
    printf '%s' 'ca-certificate-for-tests' | base64
    exit 0 ;;
  # 2b: the deploy delivers the database as class Secrets; the row lists them across
  # namespaces and checks the consumer's own Secret for the master copy it no longer holds.
  "get secret -A"*)
    printf '%s\n' \
      "${STUB_DML_NAMESPACE:-pluto-payments} ${STUB_CLASS_PREFIX:-qual-gcp-us-central1}-dml-creds" \
      "${STUB_DDL_NAMESPACE:-pluto-comms} ${STUB_CLASS_PREFIX:-qual-gcp-us-central1}-ddl-creds"
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
    printf 'gke_old-project_us-central1_sol-qual-gcp-15c\ngke_sol-qualification_us-central1_test-cluster\n'
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

chmod +x "$TMP"/bin/*

SOL_DATA="$TMP/data/sol"
mkdir -p "$SOL_DATA/runs/cloud-apply-20260925T000000Z-1234"
printf 'lifecycle phase: CloudBootstrap\n' >"$SOL_DATA/runs/cloud-apply-20260925T000000Z-1234/phase.log"
printf 'root=platform/cloud/gcp/cluster\n' >"$SOL_DATA/runs/cloud-apply-20260925T000000Z-1234/meta"
printf 'exited 0\n' >"$SOL_DATA/runs/cloud-apply-20260925T000000Z-1234/exit"

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
  env ALLOW_CANONICAL=1 SOL_INSTALL="$INSTALL" SOL_CANDIDATE="${SOL_CANDIDATE-$INSTALL/candidate.json}" CLUSTER=test-cluster \
    IMPERSONATOR=user:test@example.com LE_EMAIL=test@example.com \
    PROJECT=sol-qualification REGION=us-central1 \
    PATH="$TMP/bin:$PATH" "$@" \
    "$HARNESS" "$sub" >"$TMP/$name.out" 2>&1
  echo "$? " >"$TMP/$name.rc"
  sed -i 's/ //' "$TMP/$name.rc"
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
has "the cloud target declares the app database the enabled units use" "app_db:" "$TARGET_FILE"
has "and the events resource" "events: {}" "$TARGET_FILE"
has "and the OCaml units the alpha scenario runs" "orders_svc: {}" "$TARGET_FILE"
has "and the TypeScript units" "order_svc: {}" "$TARGET_FILE"
# A profiled target requires an authority for every key its units need; the profile's
# authenticated Kafka makes KAFKA_SASL_PASSWORD/KAFKA_SSL_CA_CERT required for each
# included unit, so the written target must declare them or `sol check` refuses.
has "the profiled target maps the platform Kafka keys the included OCaml units need" \
  "payments/orders_svc:" "$TARGET_FILE"
has "for the worker too" "comms/fulfilment_worker:" "$TARGET_FILE"
has "and the TypeScript units the row includes" "demo_ts/order_svc:" "$TARGET_FILE"
has "and its worker" "demo_ts/fulfillment_worker:" "$TARGET_FILE"
has "with the platform as the authority" "authority: sol" "$TARGET_FILE"
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

printf '\nscenario: the harness supplies the platform credential the install names, then resumes\n'
run_case credential-boundary cloud STUB_APPLY_CREDENTIAL_MISSING=1
is "exit 0" "$(cat "$TMP/credential-boundary.rc")" "0"
has "the harness creates the documented Secret in the namespace the install named" \
  "create secret generic redpanda-users -n redpanda" "$TMP/credential-boundary.argv"
has "with the SASL user the workload renderer names" "sol-workloads:" "$TMP/credential-boundary.argv"
has "and the SCRAM mechanism the durable layer declares" "SCRAM-SHA-256" "$TMP/credential-boundary.argv"
has "bound to the run's own kubeconfig" \
  "[kubeconfig=$TMP/credential-boundary.logs/run-kubeconfig.yaml]" "$TMP/credential-boundary.argv"
if [ "$(grep -c 'sol deploy' "$TMP/credential-boundary.argv")" -ge 2 ]; then
  ok "and resumes the deploy once the prerequisite exists"
else
  no "and resumes the deploy once the prerequisite exists" "two whole-target deploy invocations" \
    "$(grep -c 'sol deploy' "$TMP/credential-boundary.argv")"
fi
has "the run record states the credential was supplied" \
  "platform_credential: redpanda/redpanda-users" "$TMP/credential-boundary.logs/prerequisites.txt"
has "and that this run generated it" "platform_credential_source: generated-for-this-run" \
  "$TMP/credential-boundary.logs/prerequisites.txt"
lacks "and never records the value" "SCRAM-SHA-256" "$TMP/credential-boundary.logs/prerequisites.txt"
present "$TMP/credential-boundary.logs/state/platform.tfstate" \
  "the resumed apply's platform root is still credited in the bundle"

printf '\nscenario: a state object that cannot be read is recorded, not demanded\n'
run_case credential-boundary-nostate cloud STUB_APPLY_CREDENTIAL_MISSING=1 STUB_STATE_UNREADABLE=1
lacks "an unreadable state object does not by itself make the bundle incomplete" \
  "bundle member missing or empty: state/platform.tfstate" "$TMP/credential-boundary-nostate.out"
has "the manifest reports what the run holds" "terraform state (platform)  MISSING" \
  "$TMP/credential-boundary-nostate.logs/evidence-manifest.txt"
has "and the read that could not establish it is kept" "COULD NOT READ" "$TMP/credential-boundary-nostate.out"

printf '\nscenario: a platform credential the harness cannot supply fails the run\n'
run_case credential-refused cloud STUB_APPLY_CREDENTIAL_MISSING=1 STUB_SECRET_CREATE_FAILS=1
if [ "$(cat "$TMP/credential-refused.rc")" != "0" ]; then
  ok "the install does not proceed without the prerequisite the harness stands in for"
else
  no "the install does not proceed without the prerequisite the harness stands in for" "non-zero" "0"
fi
has "and the failure names the input the harness could not create" "redpanda/redpanda-users" \
  "$TMP/credential-refused.out"
lacks "and the harness does not claim a successful platform apply" "platform-apply ok" \
  "$TMP/credential-refused.logs/cloud-apply.log"

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
case " $* " in
  *"/orders/"*)
    id="${!#}"
    printf '{"order_id":"%s","status":"confirmed"}' "$id"
    ;;
  *"/orders"*)
    body=""
    prev=""
    for arg in "$@"; do
      [ "$prev" = "-d" ] && body="$arg"
      prev="$arg"
    done
    id="$(printf '%s' "$body" | sed -n 's/.*"order_id":"\([^"]*\)".*/\1/p')"
    printf '{"order_id":"%s","status":"accepted"}' "$id"
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
mv "$TMP/bin/curl.delegation" "$TMP/bin/curl"
is "the app phase exits 0 when every step succeeds" "$(cat "$TMP/app-ok.rc")" "0"
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
has "the workspace's migrations are applied before the deploy" "migrate apply" "$TMP/app-ok.argv"
lacks "the migrate step is not asked to publish a runner" \
  "migrate apply qual/gcp/us-central1 --registry" "$TMP/app-ok.argv"
has "Sol is handed no runner reference at all" \
  "migrate apply qual/gcp/us-central1 [runner=unset]" "$TMP/app-ok.argv"
has "the deploy is given the target's own registry" \
  "--registry us-central1-docker.pkg.dev/sol-qualification/test-cluster" "$TMP/app-ok.argv"
has "and every selected workload is pinned by digest" \
  "deploy qual/gcp/us-central1 --registry us-central1-docker.pkg.dev/sol-qualification/test-cluster --image-ref orders_svc=us-central1-docker.pkg.dev/sol-qualification/test-cluster/pluto/orders-svc@sha256:" \
  "$TMP/app-ok.argv"
has "including the TypeScript namespace's service" \
  "--image-ref order_svc=us-central1-docker.pkg.dev/sol-qualification/test-cluster/pluto/order-svc@sha256:" \
  "$TMP/app-ok.argv"
lacks "no mutable tag is passed to a profile that requires immutable artifacts" \
  "--image-tag" "$TMP/app-ok.argv"
lacks "no operator POSTGRES_URL is set for the migration path" \
  "secret set POSTGRES_URL" "$TMP/app-ok.argv"
has "and the Kafka credential and CA" \
  "secret set KAFKA_SSL_CA_CERT --target qual/gcp/us-central1 --domain comms" "$TMP/app-ok.argv"
lacks "no secret value is passed on a command line" \
  "testpass" "$TMP/app-ok.argv"
has "the supplied keys are recorded without their values" \
  "secret_values: never recorded" "$TMP/app-ok.logs/prerequisites.txt"
has "the deploy's class-Secret delivery is asserted, not the operator's copy" \
  "database_delivery: qual-gcp-us-central1-ddl-creds (migration Job), qual-gcp-us-central1-dml-creds@pluto-payments (unit consumer)" \
  "$TMP/app-ok.logs/prerequisites.txt"
# A profile-less deploy fires neither gate, so this row scopes them out and names the bug
# that must make them fire on any deploy (#1403) rather than claiming them here.
has "the secret-stop observation is scoped out, naming the gating bug" \
  "scoped_out: \"Sol refuses absent operator secrets\" (a profile-less deploy has no required-secret stop; #1403)" \
  "$TMP/app-ok.logs/prerequisites.txt"
has "and the migration-gate observation too" \
  "scoped_out: \"A deploy refuses to move workloads against an unapplied migration\" (a profile-less deploy has no migration gate; #1403)" \
  "$TMP/app-ok.logs/prerequisites.txt"
has "the run identity records the bundle version" \
  "sol_version: $VERSION" "$TMP/app-ok.logs/sol-identity.txt"
has "and the bundle's digest-pinned migration runner" \
  "migration_runner_image: $RUNNER" "$TMP/app-ok.logs/sol-identity.txt"
lacks "the app target selects no profile, so the row claims none of its guarantees" "profile:" "$TARGET_FILE"
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

printf '\nscenario: a stalled orders read-back fails the phase, so success cannot be manufactured\n'
export CURL_LOG="$TMP/app-stall.curl"
: >"$CURL_LOG"
mv "$TMP/bin/curl" "$TMP/bin/curl.orders"
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${CURL_LOG:-/dev/null}"
case " $* " in
  *"/orders/"*) printf '{"status":"pending"}' ;;
  *"/orders"*)
    body=""
    prev=""
    for arg in "$@"; do
      [ "$prev" = "-d" ] && body="$arg"
      prev="$arg"
    done
    id="$(printf '%s' "$body" | sed -n 's/.*"order_id":"\([^"]*\)".*/\1/p')"
    printf '{"order_id":"%s","status":"accepted"}' "$id"
    ;;
  *) printf 'ok' ;;
esac
STUB
chmod +x "$TMP/bin/curl"
export DOCKER_LOG="$TMP/app-stall.docker"
: >"$DOCKER_LOG"
STUB_STATE_WITH_OUTPUTS=1 PRESEED_CREDENTIALS=1 run_case app-stall app \
  APP_READBACK_ATTEMPTS=2 APP_READBACK_INTERVAL=1
mv "$TMP/bin/curl.orders" "$TMP/bin/curl"
is "a read-back that never reaches fulfilled fails the phase" \
  "$(cat "$TMP/app-stall.rc")" 1
lacks "and no alpha row is recorded as run" "$(printf 'B1\trun')" \
  "$TMP/app-stall.logs/alpha-rows.txt"
has "the failure names the order that never completed" "never reached fulfilled or confirmed" \
  "$TMP/app-stall.logs/app-transaction-ocaml.log"

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
present "$TMP/destroy-ok.logs/state/cloud.tfstate" "the state snapshot is frozen before teardown (H3)"
if [ -f "$TARGET_FILE" ]; then no "the target is removed after verified teardown" "removed" "still present"; else ok "the target is removed after verified teardown"; fi

printf '\nscenario: verification finds a leftover\n'
run_case destroy-leftover destroy STUB_TARGET_PRESENT=1
if [ "$(cat "$TMP/destroy-leftover.rc")" = "0" ]; then no "non-zero exit when resources remain" "non-zero" "0"; else ok "non-zero exit when resources remain"; fi
if [ -f "$TARGET_FILE" ]; then ok "the target is retained when teardown is unverified"; else no "the target is retained when teardown is unverified" "present" "removed"; fi
has "the leftover names a class the contract requires (artifact registry)" "artifact-registry still exists" "$TMP/destroy-leftover.out"

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
done

printf '\nscenario: no contradictory configuration is ever rendered\n'
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

printf '\nscenario: a filtered list that warns\n'
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ] || exit 1
dirty="$(git -C "$REPO" status --porcelain --untracked-files=all -- examples/pluto/)"
if [ -n "$dirty" ]; then
  printf '[FAIL] the suite left the checkout dirty:\n%s\n' "$dirty"; exit 1
fi
printf 'checkout clean\n'
