#!/bin/sh
set -eu
# Lambda provides the runtime API; local Kubernetes CronJob does not.
if [ -n "${AWS_LAMBDA_RUNTIME_API:-}" ]; then
  exec /lambda-entrypoint.sh "$@"
fi
exec node /var/task/index.js
