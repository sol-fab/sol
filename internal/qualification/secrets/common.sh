#!/usr/bin/env bash
# Shared steps for the provider-backed secret scenario. Provider mechanics live in
# aws.sh/gcp.sh; this file owns ordering, evidence, and fail-closed handling.
set -uo pipefail

scenario_die() {
  printf 'scenario: %s\n' "$1" >&2
  printf 'failed=%s\n' "$1" >>"${LOG_DIR:-/dev/null}/scenario-status.txt" 2>/dev/null || true
  exit 1
}

require_env() {
  local name value
  for name in "$@"; do
    eval "value=\${$name:-}"
    [ -n "$value" ] || scenario_die "set $name"
  done
}

scenario_record_phase() {
  printf 'phase=%s exit=%s\n' "$1" "$2" >>"$LOG_DIR/phase-verdicts.txt"
}

scenario_status() {
  printf '%s=%s\n' "$1" "$2" >>"$LOG_DIR/scenario-status.txt"
}

scenario_setup_workspace() {
  QUAL_UNIT="${QUAL_UNIT:-probe/secret_probe_worker}"
  QUAL_PROBE_KEY="${QUAL_PROBE_KEY:-SOL_PROBE_SECRET}"
  QUAL_PROBE_LOCAL_PORT="${QUAL_PROBE_LOCAL_PORT:-18080}"
  QUAL_ROTATION_TIMEOUT_S="${QUAL_ROTATION_TIMEOUT_S:-300}"
  QUAL_POD_TIMEOUT_S="${QUAL_POD_TIMEOUT_S:-300}"
  WORKSPACE="$LOG_DIR/scenario-workspace"
  case "$WORKSPACE" in
    "$LOG_DIR"/*) ;;
    *) scenario_die "refusing to manage a workspace outside LOG_DIR: $WORKSPACE" ;;
  esac
  rm -rf "$WORKSPACE"
  mkdir -p "$WORKSPACE/sol"
  cp -R "$HERE/fixture/." "$WORKSPACE/"
  cp "$QUAL_TARGET_FILE" "$WORKSPACE/sol/environments.yml"
  cp "$QUAL_TARGET_FILE" "$LOG_DIR/profile-target.yml"
  python3 - "$WORKSPACE/sol/environments.yml" "$SOL_TARGET" "$QUAL_UNIT" "$QUAL_PROBE_KEY" \
    "$LOG_DIR/target-facts.json" "$PROVIDER" <<'PY'
import json
import sys
import yaml

path, target, unit, key, facts_path, provider = sys.argv[1:7]
parts = target.split("/")
if len(parts) != 3:
    raise SystemExit(f"target {target!r} is not <env>/<provider>/<region>")
env, target_provider, region = parts
if target_provider != provider:
    raise SystemExit(f"target {target!r} names provider {target_provider}, not {provider}")
try:
    document = yaml.safe_load(open(path, encoding="utf-8"))
except OSError as error:
    raise SystemExit(f"cannot read target file: {error}")
try:
    declared = document[env]["targets"][target_provider + "/" + region]
except (KeyError, TypeError):
    raise SystemExit(f"target file does not declare {target}")
if declared.get("shape") != "durable":
    raise SystemExit(f"target {target} is not shape: durable")
try:
    authority = declared["secrets"][unit][key]["authority"]
except (KeyError, TypeError):
    raise SystemExit(f"target file does not map {unit}/{key} to a secret authority")
if authority != "sol":
    raise SystemExit(f"target file maps {unit}/{key} to {authority}, not sol")
cluster = declared.get("cluster_name")
if not cluster:
    raise SystemExit("target file declares no cluster_name")
project = None
if provider == "gcp":
    try:
        project = declared["gcp"]["project_id"]
    except (KeyError, TypeError):
        raise SystemExit("target file declares no gcp.project_id")
facts = {
    "provider": provider,
    "target": target,
    "environment": env,
    "region": region,
    "cluster": cluster,
    "project": project,
    "registry": declared.get("registry"),
}
json.dump(facts, open(facts_path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
  local declared_cluster declared_region
  declared_cluster="$(jq -r '.cluster' "$LOG_DIR/target-facts.json")"
  declared_region="$(jq -r '.region' "$LOG_DIR/target-facts.json")"
  [ "$QUAL_CLUSTER" = "$declared_cluster" ] ||
    scenario_die "QUAL_CLUSTER=$QUAL_CLUSTER does not match the target's $declared_cluster"
  [ "$QUAL_REGION" = "$declared_region" ] ||
    scenario_die "QUAL_REGION=$QUAL_REGION does not match the target's $declared_region"
  if [ "$PROVIDER" = gcp ]; then
    require_env QUAL_PROJECT
    [ "$QUAL_PROJECT" = "$(jq -r '.project' "$LOG_DIR/target-facts.json")" ] ||
      scenario_die "QUAL_PROJECT does not match the target's gcp.project_id"
  fi
  AUTHORITY_REFERENCE=""
  NS=""
  K8S=""
  SCENARIO_CLEANED=0
  PORT_FORWARD_PID=""
}

scenario_write_contract() {
  python3 - "$ROOT/internal/qualification/qualification-contract.json" "$LOG_DIR/contract.txt" <<'PY'
import hashlib
import json
import sys

path, out = sys.argv[1:3]
raw = open(path, "rb").read()
contract = json.loads(raw)
with open(out, "w", encoding="utf-8") as handle:
    handle.write(f"contract_id={contract['id']}\n")
    handle.write(f"contract_revision={contract['revision']}\n")
    handle.write(f"contract_sha256={hashlib.sha256(raw).hexdigest()}\n")
    handle.write("contract_path=internal/qualification/qualification-contract.json\n")
    handle.write("evidence_class=behavioral\n")
    handle.write("scenario_contract=qualification-scenario/v1\n")
PY
}

scenario_build_probe_image() {
  if [ -n "${QUAL_PROBE_IMAGE:-}" ]; then
    PROBE_IMAGE="$QUAL_PROBE_IMAGE"
  else
    local tag image
    tag="$(printf '%s' "$ATTEMPT" | tr -c 'a-zA-Z0-9_.-' '-')"
    image="$QUAL_REGISTRY/secret-qual-probe:$tag"
    DOCKER_BUILDKIT=0 docker build --platform linux/amd64 -t "$image" \
      "$WORKSPACE/app/probe/secret_probe_worker" >"$LOG_DIR/probe-build.log" 2>&1 ||
      scenario_die "probe image build failed; see probe-build.log"
    docker push "$image" >"$LOG_DIR/probe-push.log" 2>&1 ||
      scenario_die "probe image push failed; see probe-push.log"
    PROBE_IMAGE="$(docker inspect --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)"
  fi
  case "$PROBE_IMAGE" in
    *@sha256:*) ;;
    *) scenario_die "probe image is not a digest reference: ${PROBE_IMAGE:-unset}" ;;
  esac
  printf '%s\n' "$PROBE_IMAGE" >"$LOG_DIR/probe-image.txt"
  scenario_status probe_image "$PROBE_IMAGE"
}

scenario_seed_authority() {
  VALUE="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  if ! printf '%s' "$VALUE" | "$SOL" secret set "$SOL_TARGET" "$QUAL_UNIT" "$QUAL_PROBE_KEY" \
      --from-stdin >"$LOG_DIR/secret-set.log" 2>&1; then
    scenario_die "sol secret set failed; see secret-set.log"
  fi
  scenario_status authority seeded
}

scenario_plan_json() {
  if ! "$SOL" plan "$SOL_TARGET" --out "$LOG_DIR/plan.json" >"$LOG_DIR/plan.log" 2>&1; then
    scenario_die "sol plan failed; see plan.log"
  fi
}

scenario_extract_plan() {
  python3 - "$LOG_DIR/plan.json" "$LOG_DIR/plan-service.json" "$QUAL_UNIT" <<'PY'
import json
import sys

plan_path, out, unit = sys.argv[1:4]
plan = json.load(open(plan_path, encoding="utf-8"))
name = unit.split("/", 1)[1]
services = plan.get("services", [])
service = next((s for s in services if s.get("source_name") == name), None)
if service is None:
    raise SystemExit(f"plan does not contain service {name}")
json.dump(service, open(out, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
  NS="$(jq -r '.namespace // empty' "$LOG_DIR/plan-service.json")"
  K8S="$(jq -r '.k8s_name // empty' "$LOG_DIR/plan-service.json")"
  AUTHORITY_REFERENCE="$(jq -r --arg k "$QUAL_PROBE_KEY" \
    '.secret_sources[]? | select(.key == $k) | .reference' "$LOG_DIR/plan-service.json")"
  [ -n "$NS" ] && [ -n "$K8S" ] || scenario_die "plan did not name the probe namespace/workload"
  [ -n "$AUTHORITY_REFERENCE" ] ||
    scenario_die "plan did not carry a provider reference for $QUAL_PROBE_KEY"
  printf 'namespace=%s\nworkload=%s\nreference=%s\n' "$NS" "$K8S" "$AUTHORITY_REFERENCE" \
    >"$LOG_DIR/plan-identity.txt"
}

scenario_cold_deploy() {
  local rc=0
  "$SOL" deploy "$SOL_TARGET" --registry "$QUAL_REGISTRY" \
    --image-ref "secret_probe_worker=$PROBE_IMAGE" \
    >"$LOG_DIR/cold-deploy.log" 2>&1 || rc=$?
  scenario_status cold_deploy_exit "$rc"
  if [ "$rc" -ne 0 ]; then
    if ! hook_cluster_exists; then
      scenario_die "cold deploy failed before the provider substrate existed; see cold-deploy.log"
    fi
    scenario_status cold_deploy accepted_without_authorization 1
  fi
  if ! hook_cluster_exists; then
    scenario_die "cold deploy did not establish the provider cluster; see cold-deploy.log"
  fi
  scenario_record_phase cloud 0
}

scenario_apply_grants() {
  if ! "$SOL" grants apply "$SOL_TARGET" >"$LOG_DIR/grants-apply.log" 2>&1; then
    scenario_die "sol grants apply failed; see grants-apply.log"
  fi
  scenario_status grants_apply 0
}

scenario_warm_deploy() {
  if ! "$SOL" deploy "$SOL_TARGET" --registry "$QUAL_REGISTRY" \
      --image-ref "secret_probe_worker=$PROBE_IMAGE" >"$LOG_DIR/warm-deploy.log" 2>&1; then
    scenario_die "warm deploy failed; see warm-deploy.log"
  fi
  scenario_record_phase app 0
  if ! kubectl -n "$NS" rollout status "deployment/$K8S" \
      --timeout="${QUAL_POD_TIMEOUT_S}s" >"$LOG_DIR/rollout.log" 2>&1; then
    scenario_die "probe rollout did not become ready; see rollout.log"
  fi
}

scenario_start_port_forward() {
  scenario_stop_port_forward
  : >"$LOG_DIR/port-forward.log"
  local pod
  pod="$(kubectl -n "$NS" get pods -l "app=$K8S" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [ -n "$pod" ] || return 1
  kubectl -n "$NS" port-forward "pod/$pod" \
    "${QUAL_PROBE_LOCAL_PORT}:8080" >"$LOG_DIR/port-forward.log" 2>&1 &
  PORT_FORWARD_PID=$!
  local i
  for i in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${QUAL_PROBE_LOCAL_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

scenario_stop_port_forward() {
  if [ -n "${PORT_FORWARD_PID:-}" ]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
    PORT_FORWARD_PID=""
  fi
}

scenario_probe_status() {
  local path="$1" header="${2:-}" code
  local args=(-sS -o "$LOG_DIR/probe-body.json" -w '%{http_code}')
  if [ -n "$header" ]; then
    (umask 077; printf 'header = "%s"\n' "$header" >"$LOG_DIR/probe-header.cfg")
    args+=(--config "$LOG_DIR/probe-header.cfg")
  fi
  code="$(curl "${args[@]}" "http://127.0.0.1:${QUAL_PROBE_LOCAL_PORT}${path}" || true)"
  rm -f "$LOG_DIR/probe-header.cfg"
  printf '%s' "$code"
}

scenario_fingerprint() {
  local code fingerprint
  code="$(scenario_probe_status /cgi-bin/fingerprint)"
  [ "$code" = 200 ] || return 1
  fingerprint="$(jq -r '.fingerprint // empty' "$LOG_DIR/probe-body.json" 2>/dev/null)"
  [ -n "$fingerprint" ] || return 1
  printf '%s' "$fingerprint"
}

scenario_assert_projection() {
  kubectl -n "$NS" get pods -l "app=$K8S" -o json >"$LOG_DIR/pods.json" 2>"$LOG_DIR/pods.err" ||
    scenario_die "could not read the probe pods; see pods.err"
  SPC_NAME="$(jq -r '[.items[].spec.volumes[]? | select(.csi) | .csi.volumeAttributes.secretProviderClass] | first // empty' \
    "$LOG_DIR/pods.json")"
  [ -n "$SPC_NAME" ] || scenario_die "the probe pod has no CSI SecretProviderClass volume"
  kubectl -n "$NS" get secretproviderclass "$SPC_NAME" -o yaml >"$LOG_DIR/spc.yaml" 2>"$LOG_DIR/spc.err" ||
    scenario_die "could not read the SecretProviderClass; see spc.err"
  grep -q 'secretObjects' "$LOG_DIR/spc.yaml" &&
    scenario_die "the SecretProviderClass mirrors a Kubernetes Secret through secretObjects"
  hook_assert_projection || return 1
  python3 - "$LOG_DIR/pods.json" "$QUAL_PROBE_KEY" "$LOG_DIR/pod-projection.txt" <<'PY'
import json
import sys

pods_path, key, out = sys.argv[1:4]
pods = json.load(open(pods_path, encoding="utf-8"))["items"]
if not pods:
    raise SystemExit("no probe pods")
problems = []
env_seen = False
mount_seen = False
csi_seen = False
for pod in pods:
    spec = pod.get("spec", {})
    for volume in spec.get("volumes", []):
        csi = volume.get("csi") or {}
        if csi.get("driver") == "secrets-store.csi.k8s.io":
            csi_seen = True
    for container in spec.get("containers", []):
        for env in container.get("env", []):
            name = env.get("name")
            if name == key:
                problems.append(f"container env carries {key} directly")
            if name == key + "_FILE" and env.get("value"):
                env_seen = True
            if name == "SOL_SECRETS_DIR" and env.get("value"):
                env_seen = True
            ref = (env.get("valueFrom") or {}).get("secretKeyRef") or {}
            if ref.get("key") == key:
                problems.append(f"container env reads {key} from a Kubernetes Secret")
        for mount in container.get("volumeMounts", []):
            if mount.get("mountPath") == "/var/run/sol/secrets":
                mount_seen = True
if not csi_seen:
    problems.append("no CSI volume")
if not mount_seen:
    problems.append("no /var/run/sol/secrets mount")
if not env_seen:
    problems.append("no KEY_FILE/SOL_SECRETS_DIR environment")
with open(out, "w", encoding="utf-8") as handle:
    handle.write(f"pods={len(pods)}\ncsi_volume={str(csi_seen).lower()}\n")
    handle.write(f"secret_mount={str(mount_seen).lower()}\nenv_contract={str(env_seen).lower()}\n")
    handle.write(f"problems={len(problems)}\n")
for problem in problems:
    raise SystemExit(problem)
PY
  if ! scenario_start_port_forward; then
    scenario_die "could not port-forward to the probe service; see port-forward.log"
  fi
  local correct wrong fingerprint
  correct="$(scenario_probe_status /cgi-bin/probe "x-probe-secret: $VALUE")"
  wrong="$(scenario_probe_status /cgi-bin/probe "x-probe-secret: not-the-secret")"
  fingerprint="$(scenario_fingerprint || true)"
  {
    printf 'correct_status=%s\n' "$correct"
    printf 'wrong_status=%s\n' "$wrong"
    printf 'fingerprint=%s\n' "$fingerprint"
  } >"$LOG_DIR/projection.json"
  [ "$correct" = 200 ] || scenario_die "the probe did not accept the projected secret (HTTP $correct)"
  [ "$wrong" = 401 ] || scenario_die "the probe did not reject a wrong secret (HTTP $wrong)"
  [ -n "$fingerprint" ] || scenario_die "could not fingerprint the projected secret"
}

scenario_assert_no_mirror() {
  kubectl -n "$NS" get secrets -o json >"$LOG_DIR/secrets.json" 2>"$LOG_DIR/secrets.err" ||
    scenario_die "could not list namespace Secrets; see secrets.err"
  python3 - "$LOG_DIR/secrets.json" "$QUAL_PROBE_KEY" "$LOG_DIR/kubernetes-secret-absence.txt" <<'PY'
import json
import sys

path, key, out = sys.argv[1:4]
items = json.load(open(path, encoding="utf-8")).get("items", [])
holders = []
for item in items:
    if key in (item.get("data") or {}):
        holders.append(item.get("metadata", {}).get("name", "<unnamed>"))
with open(out, "w", encoding="utf-8") as handle:
    handle.write(f"kubernetes_secret_holders={len(holders)}\n")
    for name in holders:
        handle.write(f"holder={name}\n")
if holders:
    raise SystemExit("a Kubernetes Secret mirrors the provider-backed key: " + ", ".join(holders))
PY
}

scenario_rotation() {
  local old_fingerprint new_fingerprint elapsed start
  old_fingerprint="$(scenario_fingerprint)" || scenario_die "no fingerprint before rotation"
  VALUE="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  if ! printf '%s' "$VALUE" | "$SOL" secret set "$SOL_TARGET" "$QUAL_UNIT" "$QUAL_PROBE_KEY" \
      --from-stdin >"$LOG_DIR/rotation-set.log" 2>&1; then
    scenario_die "rotation write failed; see rotation-set.log"
  fi
  start="$(date +%s)"
  new_fingerprint=""
  while [ "$(( $(date +%s) - start ))" -lt "$QUAL_ROTATION_TIMEOUT_S" ]; do
    new_fingerprint="$(scenario_fingerprint || true)"
    if [ -n "$new_fingerprint" ] && [ "$new_fingerprint" != "$old_fingerprint" ]; then
      break
    fi
    sleep 5
  done
  elapsed="$(( $(date +%s) - start ))"
  {
    printf 'old_fingerprint=%s\n' "$old_fingerprint"
    printf 'new_fingerprint=%s\n' "${new_fingerprint:-unchanged}"
    printf 'elapsed_seconds=%s\n' "$elapsed"
    printf 'timeout_seconds=%s\n' "$QUAL_ROTATION_TIMEOUT_S"
  } >"$LOG_DIR/rotation.json"
  if [ -z "$new_fingerprint" ] || [ "$new_fingerprint" = "$old_fingerprint" ]; then
    scenario_die "the mounted file did not refresh within ${QUAL_ROTATION_TIMEOUT_S}s"
  fi
}

scenario_revoke_and_restore() {
  cp "$WORKSPACE/app/probe/secret_probe_worker/sol.toml" "$LOG_DIR/sol.toml.before-revocation"
  python3 - "$WORKSPACE/app/probe/secret_probe_worker/sol.toml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace('secrets = ["SOL_PROBE_SECRET"]', "secrets = []")
open(path, "w", encoding="utf-8").write(text)
PY
  if ! "$SOL" grants apply "$SOL_TARGET" >"$LOG_DIR/grants-revoke.log" 2>&1; then
    cp "$LOG_DIR/sol.toml.before-revocation" "$WORKSPACE/app/probe/secret_probe_worker/sol.toml"
    scenario_die "sol grants apply failed while revoking the probe grant; see grants-revoke.log"
  fi
  hook_assert_authorization revoked || return 1
  kubectl -n "$NS" delete pod -l "app=$K8S" --wait=false >"$LOG_DIR/pod-delete-revoked.log" 2>&1 || true
  local ready=1
  local deadline=$(( $(date +%s) + QUAL_POD_TIMEOUT_S ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if kubectl -n "$NS" get pods -l "app=$K8S" -o json >"$LOG_DIR/pods-revoked.json" 2>/dev/null; then
      if python3 - "$LOG_DIR/pods-revoked.json" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8")).get("items", [])
for item in items:
    for status in item.get("status", {}).get("containerStatuses", []):
        if status.get("ready"):
            raise SystemExit(0)
raise SystemExit(1)
PY
      then
        ready=0
        break
      fi
    fi
    sleep 5
  done
  kubectl -n "$NS" get events --sort-by=.lastTimestamp >"$LOG_DIR/events-revoked.txt" 2>&1 || true
  {
    printf 'grant_revoked=1\n'
    printf 'pod_ready_without_grant=%s\n' "$([ "$ready" = 0 ] && echo yes || echo no)"
  } >"$LOG_DIR/authorization-revoked.txt"
  [ "$ready" = 1 ] || {
    cp "$LOG_DIR/sol.toml.before-revocation" "$WORKSPACE/app/probe/secret_probe_worker/sol.toml"
    scenario_die "a new pod became ready after the grant was removed; the revocation was not observable"
  }
  cp "$LOG_DIR/sol.toml.before-revocation" "$WORKSPACE/app/probe/secret_probe_worker/sol.toml"
  if ! "$SOL" grants apply "$SOL_TARGET" >"$LOG_DIR/grants-restore.log" 2>&1; then
    scenario_die "sol grants apply failed while restoring the probe grant; see grants-restore.log"
  fi
  hook_assert_authorization restored || return 1
  kubectl -n "$NS" delete pod -l "app=$K8S" --wait=false >"$LOG_DIR/pod-delete-restored.log" 2>&1 || true
  if ! kubectl -n "$NS" rollout status "deployment/$K8S" \
      --timeout="${QUAL_POD_TIMEOUT_S}s" >"$LOG_DIR/rollout-restored.log" 2>&1; then
    scenario_die "the probe did not recover after the grant was restored"
  fi
  scenario_start_port_forward || scenario_die "could not re-establish the probe port-forward"
  local code
  code="$(scenario_probe_status /cgi-bin/probe "x-probe-secret: $VALUE")"
  [ "$code" = 200 ] || scenario_die "the probe did not recover the secret after grant restoration"
  printf 'grant_restored=1\nprobe_status=%s\n' "$code" >"$LOG_DIR/authorization-restored.txt"
}

scenario_missing_authority() {
  hook_delete_authority "$AUTHORITY_REFERENCE" >"$LOG_DIR/authority-delete.log" 2>&1 ||
    scenario_die "could not delete the probe authority; see authority-delete.log"
  local rc=0
  "$SOL" deploy "$SOL_TARGET" --registry "$QUAL_REGISTRY" \
    --image-ref "secret_probe_worker=$PROBE_IMAGE" >"$LOG_DIR/missing-failclosed.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    scenario_die "a deploy succeeded with the provider authority absent"
  fi
  grep -Eq 'provider secret authority|does not exist|no readable version|pending provider deletion' \
    "$LOG_DIR/missing-failclosed.log" ||
    scenario_die "the missing-authority deploy failed for an unrelated reason; see missing-failclosed.log"
  VALUE="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  if ! printf '%s' "$VALUE" | "$SOL" secret set "$SOL_TARGET" "$QUAL_UNIT" "$QUAL_PROBE_KEY" \
      --from-stdin >"$LOG_DIR/recovery-set.log" 2>&1; then
    scenario_die "could not re-seed the authority after deletion; see recovery-set.log"
  fi
  if ! "$SOL" deploy "$SOL_TARGET" --registry "$QUAL_REGISTRY" \
      --image-ref "secret_probe_worker=$PROBE_IMAGE" >"$LOG_DIR/recovery-deploy.log" 2>&1; then
    scenario_die "deploy did not recover after re-seeding the authority; see recovery-deploy.log"
  fi
  kubectl -n "$NS" delete pod -l "app=$K8S" --wait=false >"$LOG_DIR/recovery-pod-restart.log" 2>&1 || true
  kubectl -n "$NS" rollout status "deployment/$K8S" --timeout="${QUAL_POD_TIMEOUT_S}s" \
    >"$LOG_DIR/recovery-rollout.log" 2>&1 || scenario_die "the probe did not recover after re-seeding"
  scenario_start_port_forward || scenario_die "could not re-establish the probe port-forward for recovery"
  local code
  code="$(scenario_probe_status /cgi-bin/probe "x-probe-secret: $VALUE")"
  [ "$code" = 200 ] || scenario_die "the recovered authority was not consumed by the probe"
  printf 'missing_authority_refused=1\nrecovered_probe_status=%s\n' "$code" >"$LOG_DIR/recovery.txt"
}

scenario_namespace_recovery() {
  kubectl delete namespace "$NS" --wait=true >"$LOG_DIR/namespace-delete.log" 2>&1 ||
    scenario_die "could not delete the probe namespace; see namespace-delete.log"
  if ! "$SOL" deploy "$SOL_TARGET" --registry "$QUAL_REGISTRY" \
      --image-ref "secret_probe_worker=$PROBE_IMAGE" >"$LOG_DIR/namespace-recovery-deploy.log" 2>&1; then
    scenario_die "deploy did not recover after namespace replacement; see namespace-recovery-deploy.log"
  fi
  kubectl -n "$NS" rollout status "deployment/$K8S" --timeout="${QUAL_POD_TIMEOUT_S}s" \
    >"$LOG_DIR/namespace-recovery-rollout.log" 2>&1 ||
    scenario_die "the probe did not become ready after namespace replacement"
  scenario_start_port_forward || scenario_die "could not re-establish the probe port-forward"
  local code
  code="$(scenario_probe_status /cgi-bin/probe "x-probe-secret: $VALUE")"
  [ "$code" = 200 ] || scenario_die "the probe could not consume the authority after namespace replacement"
  printf 'namespace_replaced=1\nprobe_status=%s\n' "$code" >"$LOG_DIR/namespace-recovery.txt"
}

scenario_destroy_and_absence() {
  scenario_stop_port_forward
  local rc=0
  "$SOL" destroy "$SOL_TARGET" --apply >"$LOG_DIR/destroy.log" 2>&1 || rc=$?
  scenario_record_phase destroy "$rc"
  if [ "$rc" -ne 0 ]; then
    scenario_status destroy_exit "$rc"
    scenario_die "sol destroy failed; see destroy.log"
  fi
  SCENARIO_CLEANED=1
  if ! hook_absence "$AUTHORITY_REFERENCE" >"$LOG_DIR/absence.txt" 2>&1; then
    scenario_record_phase verify 1
    scenario_die "provider-side absence was not established; see absence.txt"
  fi
  scenario_record_phase verify 0
  scenario_status destroy 0
}

trap 'scenario_stop_port_forward' EXIT
