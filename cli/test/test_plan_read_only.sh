#!/usr/bin/env bash
set -eu

sol="$(realpath "$1")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/workspace/app/payments/api_svc" "$tmp/workspace/app/payments/events_worker" "$tmp/workspace/sol" "$tmp/bin"
printf 'FROM scratch\n' > "$tmp/workspace/app/payments/api_svc/Dockerfile"
printf 'FROM scratch\n' > "$tmp/workspace/app/payments/events_worker/Dockerfile"
cat > "$tmp/workspace/sol.yml" <<'EOF'
project: plan_test
services:
  api_svc:
    language: ocaml
  events_worker:
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
        payments/events_worker:
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
printf '%s\n' "\$*" >> "$tmp/terraform.log"
exit 0
EOF
cat > "$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo 'ResourceNotFound: not found' >&2
exit 1
EOF
cat > "$tmp/bin/kubectl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/kubectl.log"
echo 'Unable to connect to the server: dial tcp 192.0.2.1:443: i/o timeout' >&2
exit 1
EOF
chmod +x "$tmp/bin/terraform" "$tmp/bin/aws" "$tmp/bin/kubectl"
cd "$tmp/workspace"
PATH="$tmp/bin:$PATH" "$sol" plan prod/aws/us-east-1 \
  --image-ref api_svc=registry.example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image-ref events_worker=registry.example/worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  > "$tmp/output"
grep -F 'image=registry.example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$tmp/output" >/dev/null
grep -F 'image=registry.example/worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$tmp/output" >/dev/null
grep -F 'First-run installation bootstrap plan (temporary local state)' "$tmp/output" >/dev/null
grep -F 'Live workload delta deferred' "$tmp/output" >/dev/null
grep -F 'Unable to connect to the server' "$tmp/output" >/dev/null
grep -F 'init -backend=false' "$tmp/terraform.log" >/dev/null
grep -F ' plan ' "$tmp/terraform.log" >/dev/null
terraform_chdir=$(sed -n '1s/.*-chdir=\([^ ]*\).*/\1/p' "$tmp/terraform.log")
test -n "$terraform_chdir"
test ! -e "$terraform_chdir"
if grep -F ' apply ' "$tmp/terraform.log" >/dev/null; then
  echo 'sol plan invoked terraform apply' >&2
  exit 1
fi
# Absence of `apply` is not enough: `destroy`, `import`, `state`, `taint` and friends
# mutate too. Assert the whole set of Terraform subcommands is read-only preview.
unexpected_terraform=$(
  awk '{ for (i = 1; i <= NF; i++) if ($i !~ /^-/) { print $i; break } }' "$tmp/terraform.log" \
    | grep -Ev '^(init|plan)$' || true
)
if [ -n "$unexpected_terraform" ]; then
  echo "sol plan invoked non-preview terraform commands: $unexpected_terraform" >&2
  exit 1
fi
# The cluster access is reading live objects; it must stay a read. The verb is the first
# token after the leading `--context <name>`, so a resource named `rollout` is not a verb.
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
if [ -f "$tmp/kubectl.log" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    verb="$(verb_of "$line")"
    case " apply create delete patch replace edit scale rollout label annotate " in
      *" $verb "*)
        echo "sol plan invoked a mutating kubectl verb: $verb" >&2
        exit 1
        ;;
    esac
  done < "$tmp/kubectl.log"
fi
if PATH="$tmp/bin:$PATH" "$sol" plan prod/aws/us-east-1 \
  --image-ref api_svc=registry.example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  > "$tmp/unreachable-output" 2>&1; then
  echo 'sol plan unexpectedly inherited images from an unreachable cluster' >&2
  exit 1
fi
grep -F 'cannot inherit workload images from the current release' "$tmp/unreachable-output" >/dev/null
