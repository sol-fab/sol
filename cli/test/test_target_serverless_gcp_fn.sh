#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
examples="${2:-examples/pluto}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state" "$work/home" "$work/ws/app/ops"
ln -s "$(cd "$examples/app/ops/probe_fn" && pwd)" "$work/ws/app/ops/probe_fn"
cat > "$work/ws/sol.yml" <<'YAML'
project: pluto
services:
  probe_fn:
    type: fn
    path: app/ops/probe_fn
    language: ocaml
YAML
mkdir -p "$work/ws/sol"
cat > "$work/ws/sol/environments.yml" <<'YAML'
live:
  shape: local
  targets:
    gcp/us-west1:
      execution: serverless
      gcp:
        project_id: example-project
YAML
cat > "$work/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_GCLOUD_STATE"
if [[ "$1 $2 $3" == "run jobs describe" ]]; then
  [[ -f "$state/job" ]] || { echo "ERROR: Cannot find job [probe-fn]." >&2; exit 1; }
  cat <<JSON
{"metadata":{"name":"probe-fn","labels":{"sol-owned":"cloud-run-job-experiment","sol-service":"probe-fn"},"generation":"2"}}
JSON
  exit 0
fi
if [[ "$1 $2 $3" == "run jobs deploy" ]]; then
  image=""
  for arg in "$@"; do
    case "$arg" in --image=*|--image) ;; esac
  done
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image) image="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$image" ]] || { echo "missing --image" >&2; exit 1; }
  printf '%s\n' "$image" > "$state/image"
  gen=2
  [[ -f "$state/generation" ]] && gen=$(($(cat "$state/generation") + 1))
  printf '%s\n' "$gen" > "$state/generation"
  touch "$state/job"
  echo "deployed"
  exit 0
fi
if [[ "$1 $2 $3" == "run jobs execute" ]]; then
  [[ -f "$state/job" ]] || { echo "job absent" >&2; exit 1; }
  n=1
  [[ -f "$state/exec-count" ]] && n=$(($(cat "$state/exec-count") + 1))
  printf '%s\n' "$n" > "$state/exec-count"
  name="ex-$n"
  mkdir -p "$state/executions"
  cp "$state/image" "$state/executions/$name.image"
  echo "executed $name"
  exit 0
fi
if [[ "$1 $2 $3 $4" == "run jobs executions list" ]]; then
  [[ -f "$state/job" ]] || { echo "ERROR: NOT_FOUND" >&2; exit 1; }
  first=1
  printf '['
  for f in $(ls -r "$state"/executions/*.image 2>/dev/null); do
    name="$(basename "$f" .image)"
    [[ "$first" == 1 ]] || printf ','
    first=0
    printf '{"metadata":{"name":"projects/example-project/locations/us-west1/jobs/probe-fn/executions/%s"}}' "$name"
  done
  printf ']\n'
  exit 0
fi
if [[ "$1 $2 $3 $4" == "run jobs executions describe" ]]; then
  name="${5##*/}"
  [[ -f "$state/executions/$name.image" ]] || { echo "execution absent" >&2; exit 1; }
  image="$(cat "$state/executions/$name.image")"
  if [[ "${FAKE_EXEC_FAIL:-0}" == 1 ]]; then
    cat <<JSON
{"job":"projects/example-project/locations/us-west1/jobs/probe-fn","spec":{"template":{"spec":{"containers":[{"image":"$image"}]}}},"status":{"succeededCount":0,"failedCount":1,"cancelledCount":0,"conditions":[{"type":"Completed","status":"False"}]}}
JSON
  else
    cat <<JSON
{"job":"projects/example-project/locations/us-west1/jobs/probe-fn","spec":{"template":{"spec":{"containers":[{"image":"$image"}]}}},"status":{"succeededCount":1,"failedCount":0,"cancelledCount":0,"conditions":[{"type":"Completed","status":"True"}]}}
JSON
  fi
  exit 0
fi
if [[ "$1 $2 $3 $4" == "run jobs executions delete" ]]; then
  name="${5##*/}"
  rm -f "$state/executions/$name.image"
  echo "deleted $name"
  exit 0
fi
if [[ "$1 $2 $3" == "run jobs list" ]]; then
  if [[ -f "$state/job" ]]; then
    printf '[{"metadata":{"name":"probe-fn"}}]\n'
  else
    printf '[]\n'
  fi
  exit 0
fi
if [[ "$1 $2 $3" == "run jobs delete" ]]; then
  rm -f "$state/job"
  echo "deleted"
  exit 0
fi
echo "unexpected gcloud: $*" >&2
exit 1
FAKE
chmod +x "$work/bin/gcloud"
unset XDG_DATA_HOME
export PATH="$work/bin:$PATH" FAKE_GCLOUD_STATE="$work/state" HOME="$work/home"
image_a="repo-a@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
image_b="repo-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
cd "$work/ws"
"$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "probe_fn=$image_a" > "$work/deploy-1"
grep -q '"kind":"fn"' "$work/deploy-1"
grep -q '"provider":"gcp"' "$work/deploy-1"
grep -q '"execution":"projects/example-project/locations/us-west1/jobs/probe-fn/executions/ex-1"' "$work/deploy-1"
record=$(find "$work/home/.local/share/sol/runs" -name serverless-release.json -type f -print | sort | tail -1)
[[ -n "$record" ]]
grep -q '"kind":"fn"' "$record"
grep -q '"execution":"projects/example-project/locations/us-west1/jobs/probe-fn/executions/ex-1"' "$record"

"$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "probe_fn=$image_b" > "$work/deploy-2"
grep -q '"execution":"projects/example-project/locations/us-west1/jobs/probe-fn/executions/ex-2"' "$work/deploy-2"
[[ "$(cat "$work/state/image")" == "$image_b" ]]

"$sol" rollback --target live/gcp/us-west1 --record "$record" --service probe_fn --to-revision ex-1 > "$work/rollback"
grep -q '"image":"'"$image_a"'"' "$work/rollback"
grep -q '"execution":"projects/example-project/locations/us-west1/jobs/probe-fn/executions/ex-3"' "$work/rollback"
[[ "$(cat "$work/state/image")" == "$image_a" ]]

"$sol" destroy live/gcp/us-west1 --apply --service probe_fn --record "$record" > "$work/destroy"
[[ ! -f "$work/state/job" ]]
[[ ! -e "$work/state/executions/ex-1.image" ]]
[[ ! -e "$work/state/executions/ex-2.image" ]]
[[ ! -e "$work/state/executions/ex-3.image" ]]

# A Job that was created and executed but whose execution failed must still leave a
# destroyable ownership record.
if FAKE_EXEC_FAIL=1 "$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "probe_fn=$image_a" > "$work/deploy-fail" 2>&1; then
  echo "deploy accepted a failed execution" >&2; exit 1
fi
grep -q 'did not succeed' "$work/deploy-fail"
record=$(find "$work/home/.local/share/sol/runs" -name serverless-release.json -type f -print | sort | tail -1)
grep -q '"kind":"fn"' "$record"
"$sol" destroy live/gcp/us-west1 --apply --service probe_fn --record "$record" > "$work/destroy-fail"
[[ ! -f "$work/state/job" ]]
[[ -z "$(ls -A "$work/state/executions" 2>/dev/null)" ]]
echo "GCP Cloud Run Jobs fn lifecycle test passed"
