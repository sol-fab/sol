#!/usr/bin/env bash
# #1477: the durable posture hands Node the platform CA through NODE_EXTRA_CA_CERTS. This
# exercises the mechanism itself — a real Node HTTPS request against a server whose
# certificate is signed by a private test CA — so the guard is about the trust path, not a
# string that happens to match.
#
# It asserts:
#   - without the CA, the request fails and certificate verification stays on (a TLS
#     verification cause, not a silent success);
#   - with NODE_EXTRA_CA_CERTS set to the CA, the request succeeds;
#   - the failure mode is not masked by NODE_TLS_REJECT_UNAUTHORIZED=0.
#
# The renderer half (that Sol projects NODE_EXTRA_CA_CERTS and mounts the file it names) is
# cli/test/inline/test_manifest_render.ml. Node and openssl are this script's requirement;
# the OCaml unit job does not install Node, so there it skips unless REQUIRE_NODE=1, and the
# TypeScript job runs it with REQUIRE_NODE=1.
set -euo pipefail

if ! command -v node >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  if [ "${REQUIRE_NODE:-0}" = 1 ]; then
    printf 'node-ca-trust: node and openssl are required here but are unavailable\n' >&2
    exit 1
  fi
  printf 'node-ca-trust: SKIP (node or openssl unavailable in this environment)\n'
  exit 0
fi

work="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

# A private CA and a server certificate it signs for localhost.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/ca.key" -out "$work/ca.crt" \
  -days 2 -subj "/CN=sol-node-ca-trust-test" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$work/srv.key" -out "$work/srv.csr" \
  -subj "/CN=localhost" >/dev/null 2>&1
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' >"$work/san.ext"
openssl x509 -req -in "$work/srv.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" \
  -CAcreateserial -out "$work/srv.crt" -days 2 -extfile "$work/san.ext" >/dev/null 2>&1

cat >"$work/server.mjs" <<'JS'
import https from "node:https";
import fs from "node:fs";
const server = https.createServer(
  { key: fs.readFileSync(process.argv[2]), cert: fs.readFileSync(process.argv[3]) },
  (_req, res) => { res.writeHead(200); res.end("ok"); },
);
server.listen(0, "127.0.0.1", () => process.stdout.write(String(server.address().port)));
JS

cat >"$work/client.mjs" <<'JS'
try {
  const response = await fetch(process.argv[2]);
  process.stdout.write(`ok ${response.status}\n`);
} catch (error) {
  const cause = error && error.cause ? (error.cause.code ?? error.cause.message) : "";
  process.stdout.write(`error ${JSON.stringify(error.message)} cause=${cause}\n`);
  process.exit(3);
}
JS

node "$work/server.mjs" "$work/srv.key" "$work/srv.crt" >"$work/port" &
server_pid=$!
for _ in $(seq 1 50); do
  [ -s "$work/port" ] && break
  sleep 0.1
done
port="$(cat "$work/port")"
if [ -z "$port" ]; then
  printf 'node-ca-trust: the test HTTPS server did not report a port\n' >&2
  exit 1
fi
url="https://localhost:$port/"

# 1. Without the CA: the fetch must fail, and the cause must be TLS verification. If it
#    succeeded, verification is off somewhere and the guard is meaningless.
if output="$(node "$work/client.mjs" "$url")"; then
  printf 'node-ca-trust: the fetch succeeded without trusting the private CA: %s\n' "$output" >&2
  exit 1
fi
case "$output" in
  *'"fetch failed"'*) ;;
  *)
    printf 'node-ca-trust: unexpected failure without the CA: %s\n' "$output" >&2
    exit 1
    ;;
esac
case "$output" in
  *cause=UNABLE_TO_VERIFY_LEAF_SIGNATURE* | *cause=ERR_TLS_CERT_ALTNAME_INVALID* | \
    *cause=SELF_SIGNED_CERT_IN_CHAIN* | *cause=DEPTH_ZERO_SELF_SIGNED_CERT*) ;;
  *)
    printf 'node-ca-trust: the failure was not TLS verification: %s\n' "$output" >&2
    exit 1
    ;;
esac

# 2. With NODE_EXTRA_CA_CERTS naming the CA: the same request must succeed.
if ! output="$(NODE_EXTRA_CA_CERTS="$work/ca.crt" node "$work/client.mjs" "$url")"; then
  printf 'node-ca-trust: the fetch failed with the CA configured: %s\n' "$output" >&2
  exit 1
fi
case "$output" in
  "ok 200") ;;
  *)
    printf 'node-ca-trust: unexpected result with the CA configured: %s\n' "$output" >&2
    exit 1
    ;;
esac

printf 'node-ca-trust: a Node HTTPS request fails without the private CA and succeeds with it (#1477)\n'
