#!/bin/sh
# Reads the value from the documented provider-secret file contract and compares it
# with the request header. The value is never written to the response or a log.
set -eu
file="${SOL_PROBE_SECRET_FILE:-${SOL_SECRETS_DIR:-/var/run/sol/secrets}/SOL_PROBE_SECRET}"
if [ ! -r "$file" ]; then
  printf 'Status: 503 Service Unavailable\r\nContent-Type: application/json\r\n\r\n{"secret":"unavailable"}\n'
  exit 0
fi
value="$(cat "$file")"
if [ -n "$value" ] && [ "${HTTP_X_PROBE_SECRET:-}" = "$value" ]; then
  printf 'Status: 200 OK\r\nContent-Type: application/json\r\n\r\n{"secret":"present","length":%s}\n' "${#value}"
else
  printf 'Status: 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{"secret":"denied"}\n'
fi
