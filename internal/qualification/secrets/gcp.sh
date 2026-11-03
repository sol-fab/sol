#!/usr/bin/env bash
# GCP mechanics for the provider-backed secret scenario.
set -uo pipefail

gcp_project() { jq -r '.project' "$LOG_DIR/target-facts.json"; }
gcp_cluster() { jq -r '.cluster' "$LOG_DIR/target-facts.json"; }
gcp_region() { jq -r '.region' "$LOG_DIR/target-facts.json"; }

hook_preflight() {
  require_env QUAL_PROJECT
  for tool in gcloud kubectl docker jq curl; do
    command -v "$tool" >/dev/null 2>&1 || scenario_die "required tool $tool is not installed"
  done
  gcloud auth list --filter=status:ACTIVE '--format=value(account)' \
    >"$LOG_DIR/gcp-identity.txt" 2>"$LOG_DIR/gcp-identity.err" ||
    scenario_die "gcloud has no active account; see gcp-identity.err"
  gcloud services list --enabled --project "$(gcp_project)" \
    --filter='config.name:secretmanager.googleapis.com' '--format=value(config.name)' \
    >"$LOG_DIR/gcp-secretmanager-api.txt" 2>"$LOG_DIR/gcp-api.err" ||
    scenario_die "could not read enabled GCP services; see gcp-api.err"
  grep -qx 'secretmanager.googleapis.com' "$LOG_DIR/gcp-secretmanager-api.txt" ||
    scenario_die "secretmanager.googleapis.com is not enabled in $(gcp_project)"
  gcloud secrets list --project "$(gcp_project)" --limit=1 '--format=value(name)' \
    >"$LOG_DIR/gcp-secret-list.txt" 2>"$LOG_DIR/gcp-secret-list.err" ||
    scenario_die "the caller cannot list Secret Manager authorities; see gcp-secret-list.err"
  if gcloud container clusters describe "$(gcp_cluster)" --region "$(gcp_region)" \
      --project "$(gcp_project)" >"$LOG_DIR/gcp-existing-cluster.json" 2>/dev/null; then
    scenario_die "cluster $(gcp_cluster) already exists; this scenario requires a fresh target"
  fi
  printf 'project=%s\n' "$(gcp_project)" >"$LOG_DIR/preflight.txt"
}

hook_cluster_exists() {
  gcloud container clusters describe "$(gcp_cluster)" --region "$(gcp_region)" \
    --project "$(gcp_project)" >/dev/null 2>&1
}

hook_after_deploy() {
  gcloud container clusters describe "$(gcp_cluster)" --region "$(gcp_region)" \
    --project "$(gcp_project)" --format=json >"$LOG_DIR/gcp-cluster.json" 2>"$LOG_DIR/gcp-cluster.err" ||
    scenario_die "could not describe the GKE cluster; see gcp-cluster.err"
  python3 - "$LOG_DIR/gcp-cluster.json" <<'PY'
import json, sys
config = json.load(open(sys.argv[1], encoding="utf-8")).get("secretManagerConfig") or {}
if not config.get("enabled"):
    raise SystemExit("the GKE Secret Manager add-on is not enabled")
rotation = config.get("rotationConfig") or {}
if not rotation.get("enabled"):
    raise SystemExit("the GKE Secret Manager add-on rotation is not enabled")
interval = str(rotation.get("rotationInterval", ""))
if interval not in ("2m", "120s"):
    raise SystemExit(f"the GKE rotation interval is {interval!r}, expected 2m")
PY
  kubectl get csidriver secrets-store.csi.k8s.io >/dev/null 2>&1 ||
    scenario_die "the secrets-store CSI driver is not installed"
  printf 'secret_manager_addon=enabled\nrotation_interval=2m\ncsi_driver=secrets-store.csi.k8s.io\n' \
    >"$LOG_DIR/runtime-mechanism.txt"
}

hook_assert_projection() {
  grep -Eq 'provider:[[:space:]]*"?gke"?' "$LOG_DIR/spc.yaml" ||
    scenario_die "the SecretProviderClass does not select provider gke"
}

gcp_member() {
  printf 'serviceAccount:%s.svc.id.goog[%s/%s]' "$(gcp_project)" "$NS" "$K8S"
}

hook_assert_authorization() {
  local mode="$1" member policy
  member="$(gcp_member)"
  gcloud secrets get-iam-policy "$AUTHORITY_REFERENCE" --project "$(gcp_project)" \
    --format=json >"$LOG_DIR/gcp-iam-policy.json" 2>"$LOG_DIR/gcp-iam-policy.err" ||
    scenario_die "could not read the provider IAM policy; see gcp-iam-policy.err"
  policy="$(python3 - "$LOG_DIR/gcp-iam-policy.json" "$member" <<'PY'
import json, sys
policy = json.load(open(sys.argv[1], encoding="utf-8"))
member = sys.argv[2]
members = set()
for binding in policy.get("bindings", []):
    if binding.get("role") == "roles/secretmanager.secretAccessor":
        members.update(binding.get("members", []))
print("present" if member in members else "absent")
PY
)"
  case "$mode" in
    allowed) [ "$policy" = present ] || scenario_die "the KSA cannot read its declared authority" ;;
    revoked) [ "$policy" = absent ] || scenario_die "the KSA still holds secretAccessor after revocation" ;;
    restored) [ "$policy" = present ] || scenario_die "the KSA did not regain secretAccessor" ;;
    *) scenario_die "unknown authorization mode $mode" ;;
  esac
  printf 'mode=%s\nmember=%s\npolicy=%s\n' "$mode" "$member" "$policy" \
    >>"$LOG_DIR/authorization.json"
}

hook_authority_metadata() {
  local ref="$1"
  gcloud secrets describe "$ref" --project "$(gcp_project)" --format=json \
    >"$LOG_DIR/authority-describe.json" 2>"$LOG_DIR/authority-describe.err" ||
    scenario_die "could not describe the provider authority; see authority-describe.err"
  gcloud secrets versions list "$ref" --project "$(gcp_project)" --format=json \
    >"$LOG_DIR/authority-versions.json" 2>"$LOG_DIR/authority-versions.err" ||
    scenario_die "could not list the provider authority versions; see authority-versions.err"
}

hook_delete_authority() {
  gcloud secrets delete "$1" --project "$(gcp_project)" --quiet
}

hook_absence() {
  local secret_status cluster_status sql_status disk_status verdict=ABSENT
  if gcloud secrets describe "$1" --project "$(gcp_project)" >/dev/null \
      2>"$LOG_DIR/absence-secret.err"; then
    secret_status=PRESENT
  elif grep -Eqi 'NOT_FOUND|not found' "$LOG_DIR/absence-secret.err"; then
    secret_status=ABSENT
  else
    secret_status=UNKNOWN
  fi
  if gcloud container clusters describe "$(gcp_cluster)" --region "$(gcp_region)" \
      --project "$(gcp_project)" >/dev/null 2>"$LOG_DIR/absence-cluster.err"; then
    cluster_status=PRESENT
  elif grep -Eqi 'NOT_FOUND|not found' "$LOG_DIR/absence-cluster.err"; then
    cluster_status=ABSENT
  else
    cluster_status=UNKNOWN
  fi
  if gcloud sql instances list --project "$(gcp_project)" \
      --filter="name~$(gcp_cluster)" '--format=value(name)' >"$LOG_DIR/absence-sql.txt" \
      2>"$LOG_DIR/absence-sql.err"; then
    if [ -s "$LOG_DIR/absence-sql.txt" ]; then sql_status=PRESENT; else sql_status=ABSENT; fi
  else
    sql_status=UNKNOWN
  fi
  if gcloud compute disks list --project "$(gcp_project)" \
      --filter="name~$(gcp_cluster)" '--format=value(name)' >"$LOG_DIR/absence-disks.txt" \
      2>"$LOG_DIR/absence-disks.err"; then
    if [ -s "$LOG_DIR/absence-disks.txt" ]; then disk_status=PRESENT; else disk_status=ABSENT; fi
  else
    disk_status=UNKNOWN
  fi
  for status in "$secret_status" "$cluster_status" "$sql_status" "$disk_status"; do
    [ "$status" = ABSENT ] || verdict=FAIL
  done
  {
    printf 'absence=%s\n' "$verdict"
    printf 'secret=%s\n' "$secret_status"
    printf 'cluster=%s\n' "$cluster_status"
    printf 'sql=%s\n' "$sql_status"
    printf 'disks=%s\n' "$disk_status"
  } >"$LOG_DIR/absence-detail.txt"
  cat "$LOG_DIR/absence-detail.txt"
  [ "$verdict" = PASS ]
}

# Read-only target inventory for the shared runner's inventory-before/after files.
hook_inventory() {
  local ref="${AUTHORITY_REFERENCE:-}" rc=0
  printf 'provider=gcp\nproject=%s\nregion=%s\ncluster=%s\n' \
    "$(gcp_project)" "$(gcp_region)" "$(gcp_cluster)"
  if gcloud container clusters describe "$(gcp_cluster)" --region "$(gcp_region)" \
      --project "$(gcp_project)" >/dev/null 2>"$LOG_DIR/inventory-cluster.err"; then
    printf 'gke-cluster=PRESENT\n'
  elif grep -Eqi 'NOT_FOUND|not found' "$LOG_DIR/inventory-cluster.err" 2>/dev/null; then
    printf 'gke-cluster=ABSENT\n'
  else
    printf 'gke-cluster=UNKNOWN\n'
    rc=1
  fi
  if [ -z "$ref" ]; then
    printf 'probe-authority=NOT-SEEDED\n'
  elif gcloud secrets describe "$ref" --project "$(gcp_project)" \
      >/dev/null 2>"$LOG_DIR/inventory-secret.err"; then
    printf 'probe-authority=PRESENT\n'
  elif grep -Eqi 'NOT_FOUND|not found' "$LOG_DIR/inventory-secret.err" 2>/dev/null; then
    printf 'probe-authority=ABSENT\n'
  else
    printf 'probe-authority=UNKNOWN\n'
    rc=1
  fi
  if gcloud sql instances list --project "$(gcp_project)" \
      --filter="name~$(gcp_cluster)" --format='value(name)' >"$LOG_DIR/inventory-sql.txt" \
      2>"$LOG_DIR/inventory-sql.err"; then
    printf 'cloud-sql-target-owned=%s\n' "$(grep -c . "$LOG_DIR/inventory-sql.txt" || true)"
  else
    printf 'cloud-sql-target-owned=UNKNOWN\n'
    rc=1
  fi
  if gcloud compute disks list --project "$(gcp_project)" \
      --filter="name~$(gcp_cluster)" --format='value(name)' >"$LOG_DIR/inventory-disks.txt" \
      2>"$LOG_DIR/inventory-disks.err"; then
    printf 'disks-target-owned=%s\n' "$(grep -c . "$LOG_DIR/inventory-disks.txt" || true)"
  else
    printf 'disks-target-owned=UNKNOWN\n'
    rc=1
  fi
  return "$rc"
}
