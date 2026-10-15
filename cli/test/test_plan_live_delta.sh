#!/usr/bin/env bash
set -eu

sol="$(realpath "$1")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/workspace/app/payments/api_svc" "$tmp/workspace/sol" "$tmp/bin"
printf 'FROM scratch\n' > "$tmp/workspace/app/payments/api_svc/Dockerfile"
cat > "$tmp/workspace/sol.yml" <<'EOF'
project: plan_test
services:
  api_svc:
    language: ocaml
EOF
cat > "$tmp/workspace/sol/environments.yml" <<'EOF'
prod:
  targets:
    aws/us-east-1:
      shape: local
      cluster_name: planned
      kube_context: planned
      state_bucket: sol-plan-state
      secrets:
        payments/api_svc:
          POSTGRES_URL:
            authority: sol
          SOL_API_KEY:
            authority: sol
          KAFKA_SASL_PASSWORD:
            authority: sol
          KAFKA_SSL_CA_CERT:
            authority: sol
      aws:
        state_lock_table: sol-plan-lock
EOF
cat > "$tmp/bin/terraform" <<EOF
#!/usr/bin/env bash
exit 0
EOF
cat > "$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo 'ResourceNotFound: not found' >&2
exit 1
EOF
# A reachable cluster on a first deploy: the current release pointer is absent, so there
# is no recorded UID evidence. The declared workload is absent; one undeclared workload
# is live under the workspace label. The delta must say "create" for the declared
# workload and "retained" for the surplus one, and must not infer ownership.
cat > "$tmp/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
case "$3 $4" in
  "get configmap")
    echo 'Error from server (NotFound): configmaps "sol-release-current-workspace" not found' >&2
    exit 1
    ;;
  "get deployment")
    case "$5" in
      -A)
        printf '%s' '{"items":[{"metadata":{"namespace":"workspace-payments","name":"foreign-svc","uid":"foreign-uid"},"spec":{"template":{"metadata":{"labels":{"workspace":"workspace"}}}}}]}'
        ;;
      *)
        echo 'Error from server (NotFound): deployments "api-svc" not found' >&2
        exit 1
        ;;
    esac
    ;;
  "get rollout")
    echo 'error: the server could not find the requested resource' >&2
    exit 1
    ;;
  "get cronjob")
    printf '%s' '{"items":[]}'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$tmp/bin/"*
cd "$tmp/workspace"
PATH="$tmp/bin:$PATH" KUBECTL_LOG="$tmp/kubectl.log" "$sol" plan prod/aws/us-east-1 \
  --image-ref api_svc=registry.example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  > "$tmp/output"
grep -F 'Live workload delta' "$tmp/output" >/dev/null
grep -F 'create' "$tmp/output" >/dev/null
grep -F 'deployment workspace-payments/api-svc' "$tmp/output" >/dev/null
grep -F 'Surplus' "$tmp/output" >/dev/null
grep -F 'retained' "$tmp/output" >/dev/null
grep -F 'deployment workspace-payments/foreign-svc' "$tmp/output" >/dev/null
if grep -F 'removable' "$tmp/output" >/dev/null; then
  echo 'sol plan claimed a removable surplus without recorded UID evidence' >&2
  exit 1
fi
# Reading live objects is not a mutation. The verb is the first token after `--context`.
verb_of() {
  set -- $1
  while [ $# -gt 0 ]; do
    case "$1" in
      --context) shift 2 ;;
      --*) shift ;;
      *) printf '%s' "$1"; return ;;
    esac
  done
}
while IFS= read -r line; do
  [ -n "$line" ] || continue
  verb="$(verb_of "$line")"
  case " apply create delete patch replace edit scale rollout label annotate " in
    *" $verb "*)
      echo "sol plan live delta invoked a mutating kubectl verb: $verb" >&2
      exit 1
      ;;
  esac
done < "$tmp/kubectl.log"
