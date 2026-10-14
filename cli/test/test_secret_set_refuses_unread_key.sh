#!/usr/bin/env bash
# #1425: `sol secret set` must not write a unit Secret the workload never reads.
#
# A unit that consumes the target's database reads POSTGRES_URL from the target's DML class
# Secret (`<target>-dml-creds`), not from its own. Planning knew that and routed accordingly;
# `sol secret set` checked only the application declaration and the authority mapping, so it
# accepted the write and created a Secret the pod never projects. The refusal now happens on
# the same resolved input ownership the plan gate uses, before the value is read and before
# any write.
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
secrets = ["POSTGRES_URL"]
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
      aws:
        state_lock_table: sol-secret-set-refusal-lock
EOF

# Any write is a failure here: the test asserts the CLI refused before touching the cluster.
cat >"$tmp/bin/kubectl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/kubectl.log"
exit 0
EOF
chmod +x "$tmp/bin/kubectl"

cd "$tmp/workspace"
set +e
output="$(
  PATH="$tmp/bin:$PATH" SOL_HOME="$(dirname "$sol")" \
    "$sol" secret set prod/aws/us-east-1 payments/api_svc/POSTGRES_URL --from-stdin \
    <<<"a-value-nobody-should-write" 2>&1
)"
rc=$?
set -e

[ "$rc" -ne 0 ] || note "the write must be refused; exit was $rc: $output"
printf '%s\n' "$output" | grep -F 'DML class Secret' >/dev/null \
  || note "the refusal must name where POSTGRES_URL is delivered from: $output"
if [ -f "$tmp/kubectl.log" ] && grep -Eq 'apply|create|patch' "$tmp/kubectl.log"; then
  note "the refusal must happen before any cluster write: $(cat "$tmp/kubectl.log")"
fi

[ "$fail" -eq 0 ] || exit 1
echo "secret set refuses a POSTGRES_URL the target's database binding supplies"
