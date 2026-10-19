#!/bin/sh
set -eu
sol=$1

set_help=$("$sol" secret set --help=plain)
delete_help=$("$sol" secret delete --help=plain)
status_help=$("$sol" secret status --help=plain)

printf '%s\n' "$set_help" | grep -F 'TARGET' >/dev/null
printf '%s\n' "$set_help" | grep -F 'DOMAIN/UNIT/KEY' >/dev/null
printf '%s\n' "$set_help" | grep -F '@platform/KAFKA_SASL_PASSWORD' >/dev/null
printf '%s\n' "$set_help" | grep -F 'refused' >/dev/null
printf '%s\n' "$set_help" | grep -F -- '--from-stdin' >/dev/null
printf '%s\n' "$set_help" | grep -F -- '--from-file=PATH' >/dev/null
if printf '%s\n' "$set_help" | grep -F -- '--value=' >/dev/null; then exit 1; fi
printf '%s\n' "$delete_help" | grep -F 'DOMAIN/UNIT/KEY' >/dev/null
printf '%s\n' "$delete_help" | grep -F '@platform/KEY' >/dev/null
printf '%s\n' "$status_help" | grep -F 'TARGET' >/dev/null

local_help=$("$sol" local --help=plain)
if printf '%s\n' "$local_help" | grep -Eq '^[[:space:]]+secret[[:space:]]'; then exit 1; fi

# Rejection must happen before attempting to read stdin when target or address
# resolution fails. The command exits promptly with this closed pipe.
if printf '' | timeout 3 "$sol" secret set dev/aws/us-east-1 payments/charge_svc/API_KEY --from-stdin >/dev/null 2>&1; then
  exit 1
fi

echo "secret CLI exposes unit-scoped writes and refuses resource-owned platform inputs"
