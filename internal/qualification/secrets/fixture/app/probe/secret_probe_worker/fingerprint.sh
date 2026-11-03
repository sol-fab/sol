#!/bin/sh
# A value-free fingerprint. It lets the scenario observe rotation/refresh without
# reading or printing the credential.
set -eu
file="${SOL_PROBE_SECRET_FILE:-${SOL_SECRETS_DIR:-/var/run/sol/secrets}/SOL_PROBE_SECRET}"
if [ ! -r "$file" ]; then
  printf 'Status: 503 Service Unavailable\r\nContent-Type: application/json\r\n\r\n{"secret":"unavailable"}\n'
  exit 0
fi
digest="$(sha256sum "$file" | cut -d' ' -f1)"
printf 'Status: 200 OK\r\nContent-Type: application/json\r\n\r\n{"fingerprint":"%s"}\n' "$digest"
