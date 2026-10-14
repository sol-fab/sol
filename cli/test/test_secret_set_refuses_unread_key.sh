#!/usr/bin/env bash
# #1425: `sol secret set` must not write a unit Secret the workload never reads.
#
# A unit that consumes the target's database reads POSTGRES_URL from the target's DML class
# Secret (`<target>-dml-creds`), not from its own. Planning knew that and routed accordingly;
# `sol secret set` checked only the application declaration and the authority mapping, so it
# accepted the write and created a Secret the pod never projects. The refusal now happens on
# the same resolved input ownership the plan gate uses, before the value is read and before
# any write.
#
# The same run then writes a key the unit *does* own, so the stub cluster proves it would
# have logged the refused write: without that control, "no apply in the log" could pass
# because the log was never created at all.
set -euo pipefail

sol="$(realpath "$1")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
note() {
  echo "test_secret_set_refuses_unread_key: $1" >&2
  fail=1
}

mkdir -p "$tmp/workspace/app/payments/api_svc" "$tmp/workspace/sol" "$tmp/bin"
printf 'FROM scratch\n' >"$tmp/workspace/app/payments/api_svc/Dockerfile"
cat >"$tmp/workspace/app/payments/api_svc/sol.toml" <<'EOF'
[infra.env]
secrets = ["POSTGRES_URL", "SOL_API_KEY"]
EOF

cat >"$tmp/workspace/sol.yml" <<'EOF'
project: secret_set_refusal_test
resources:
  app_db:
    type: postgres
services:
  api_svc:
    type: http
    path: app/payments/api_svc
    uses: [app_db]
    language: ocaml
EOF

cat >"$tmp/workspace/sol/environments.yml" <<'EOF'
prod:
  targets:
    aws/us-east-1:
      cluster_name: planned
      kube_context: planned
      state_bucket: sol-secret-set-refusal
      secrets:
        payments/api_svc:
          POSTGRES_URL:
            authority: sol
          SOL_API_KEY:
            authority: sol
      aws:
        state_lock_table: sol-secret-set-refusal-lock
EOF

# A stub cluster with a namespace and nothing else. `get secret` is NotFound until something
# is applied; afterwards it returns a Secret with a new resourceVersion, which is how the CLI
# tells "written" from "already had that value". Every kubectl invocation is logged.
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
  *" create "*|*" apply "*|*" patch "*)
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

# 1. The binding supplies POSTGRES_URL, so the write must be refused before any cluster call.
set +e
output="$(
  PATH="$tmp/bin:$PATH" SOL_HOME="$(dirname "$sol")" \
    "$sol" secret set prod/aws/us-east-1 payments/api_svc/POSTGRES_URL --from-stdin \
    <<<"a-value-nobody-should-write" 2>&1
)"
rc=$?
set -e
[ "$rc" -ne 0 ] || note "the POSTGRES_URL write must be refused; exit was $rc: $output"
printf '%s\n' "$output" | grep -F 'DML class Secret' >/dev/null \
  || note "the refusal must name where POSTGRES_URL is delivered from: $output"
if [ -f "$tmp/kubectl.log" ]; then
  note "the refusal must happen before any cluster call: $(cat "$tmp/kubectl.log")"
fi

# 2. Positive control: a key the unit owns reaches the stub, proving the stub logs writes.
set +e
output="$(
  PATH="$tmp/bin:$PATH" SOL_HOME="$(dirname "$sol")" \
    "$sol" secret set prod/aws/us-east-1 payments/api_svc/SOL_API_KEY --from-stdin \
    <<<"an-owned-value" 2>&1
)"
rc=$?
set -e
[ "$rc" -eq 0 ] || note "the SOL_API_KEY write must succeed; exit was $rc: $output"
printf '%s\n' "$output" | grep -F 'Secret updated for payments/api_svc/SOL_API_KEY' >/dev/null \
  || note "the accepted write must report the Secret it updated: $output"
if [ ! -f "$tmp/kubectl.log" ]; then
  note "the positive control never reached the stub cluster, so the refusal assertion is vacuous"
elif ! grep -Eq 'apply|create|patch' "$tmp/kubectl.log"; then
  note "the positive control made no write: $(cat "$tmp/kubectl.log")"
fi

[ "$fail" -eq 0 ] || exit 1
echo "secret set refuses a POSTGRES_URL the target's database binding supplies"
