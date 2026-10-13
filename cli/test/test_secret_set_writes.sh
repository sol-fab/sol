#!/usr/bin/env bash
# **Set writes; activation is explicit** (#1350, and the defect it was masking, #1434).
#
# The deploy refuses to apply a unit whose declared secret is absent, so the operator has to
# write the value *before* the Deployment exists. That used to fail: `sol secret set` wrote the
# value and then restarted the unit's Deployment and waited for its rollout, and on a target
# where the workload did not exist yet the write reported
#
#   error: secret value was written for <ns>/<KEY>, but deployment/<unit> could not be restarted:
#          ... deployments.apps "<unit>" not found
#
# with a non-zero exit, even though the value had been written. Only ignoring the failure let a
# first deploy proceed.
#
# This drives the real binary against a stub `kubectl` whose cluster has **no workload at all**,
# and asserts the write succeeds, reaches the Secret, and never asks for a rollout.
set -euo pipefail

sol="$(realpath "$1")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
note() {
  echo "test_secret_set_writes: $1" >&2
  fail=1
}

mkdir -p "$tmp/workspace/app/payments/api_svc" "$tmp/workspace/sol" "$tmp/bin"
printf 'FROM scratch\n' >"$tmp/workspace/app/payments/api_svc/Dockerfile"
cat >"$tmp/workspace/app/payments/api_svc/sol.toml" <<'EOF'
[infra.env]
secrets = ["SOL_API_KEY"]
EOF

cat >"$tmp/workspace/sol.yml" <<'EOF'
project: secret_set_test
services:
  api_svc:
    type: http
    path: app/payments/api_svc
    language: ocaml
EOF

cat >"$tmp/workspace/sol/environments.yml" <<'EOF'
prod:
  targets:
    aws/us-east-1:
      cluster_name: planned
      kube_context: planned
      state_bucket: sol-secret-set-state
      secrets:
        payments/api_svc:
          SOL_API_KEY:
            authority: sol
      aws:
        state_lock_table: sol-secret-set-lock
EOF

# The stub cluster has a namespace and nothing else: no Deployment, no ReplicaSet, no rollout.
# `get secret` is NotFound until something is applied, and afterwards returns a Secret with a
# new resourceVersion, which is how the CLI tells "written" from "already had that value".
cat >"$tmp/bin/kubectl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/kubectl.log"
case " \$* " in
  *" get secret "*)
    if [ -f "$tmp/applied" ]; then
      printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"api-svc-secrets","namespace":"workspace-payments","resourceVersion":"2","labels":{"app.kubernetes.io/managed-by":"sol"}},"data":{"SOL_API_KEY":"dmFsdWU="}}\n'
    else
      printf 'Error from server (NotFound): secrets "api-svc-secrets" not found\n' >&2
      exit 1
    fi
    ;;
  *" create "*|*" apply "*)
    # The namespace is created first (its manifest is the "sol-secret-ns-" render); only the
    # Secret's own write counts as "the value exists now".
    case " \$* " in
      *"sol-secret-ns-"*) ;;
      *) : >"$tmp/applied" ;;
    esac
    printf 'secret/api-svc-secrets configured\n'
    ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/kubectl"

cd "$tmp/workspace"
set +e
output="$(
  PATH="$tmp/bin:$PATH" SOL_HOME="$(dirname "$sol")" \
    "$sol" secret set prod/aws/us-east-1 payments/api_svc/SOL_API_KEY --from-stdin \
    <<<"a-value-nobody-prints" 2>&1
)"
rc=$?
set -e

[ "$rc" -eq 0 ] || note "writing before the workload exists must succeed; exit was $rc: $output"
printf '%s\n' "$output" | grep -F 'Secret updated for payments/api_svc/SOL_API_KEY' >/dev/null \
  || note "the write must report the Secret it updated: $output"
grep -q 'apply\|create' "$tmp/kubectl.log" || note "the write must reach the cluster"
if grep -q 'rollout' "$tmp/kubectl.log"; then
  note "a write must not restart a workload (activation is the deploy's job): $(cat "$tmp/kubectl.log")"
fi
printf '%s\n' "$output" | grep -F 'restart' >/dev/null \
  && note "the write must not claim a restart: $output"

[ "$fail" -eq 0 ] || exit 1
echo "secret set writes a unit secret with no workload to restart"
