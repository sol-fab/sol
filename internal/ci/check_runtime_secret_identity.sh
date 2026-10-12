#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
substrate="$root/cli/lib/deploy/sol_cli_substrate.ml"
secret="$root/cli/lib/deploy/sol_cli_secret.ml"
migrate="$root/cli/lib/deploy/sol_cli_migration_job.ml"
manifest="$root/cli/lib/workspace/sol_cli_manifest_yaml.ml"
render="$root/cli/lib/deploy/sol_cli_database_setup_render.ml"

fail=0
require() {
  local description="$1" file="$2" pattern="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo "check_runtime_secret_identity: $description" >&2
    echo "  expected $file to match /$pattern/" >&2
    fail=1
  fi
}
require_absent() {
  local description="$1" file="$2" pattern="$3"
  if grep -qE "$pattern" "$file"; then
    echo "check_runtime_secret_identity: $description" >&2
    echo "  did not expect $file to match /$pattern/" >&2
    fail=1
  fi
}

# 2b: the migration Job is a DDL consumer. Its reader and the class Secret's writer must
# name the same object through one definition; a reader that hardcoded `<target>-ddl-creds`
# could drift from the writer.
require "the migration Job runner renders its Job through Sol_cli_manifest.migration_job_doc" \
  "$migrate" 'Sol_cli_manifest\.migration_job_doc'

require "the migration Job builder references the DDL class Secret by the passed name" \
  "$manifest" '"secretRef", Y\.map \[ "name", Y\.string ddl_creds_name \]'

require "the class Secret names have a single home" \
  "$render" 'let creds_name ~credential_class target ='

# The substrate no longer verifies the operator's POSTGRES_URL: 2b removed the workload
# default, and the class Secrets are written by the setup step *after* the substrate
# prerequisite. The check that required it must not come back as a hidden ordering trap.
require_absent "the substrate no longer verifies the operator's POSTGRES_URL" \
  "$substrate" 'verify_runtime_secret'

# The runtime Secret survives for Kafka, and the contract Job is its remaining consumer.
# Its name still has one home, and the Job still names it from that constant.
require "the Kafka runtime Secret verification names it from the shared constant" \
  "$secret" '~secret_name:Sol_cli_manifest\.runtime_secret_name'

require "the contract Job references the shared runtime Secret" \
  "$manifest" '"secretRef", Y\.map \[ "name", Y\.string runtime_secret_name \]'

require "the runtime Secret name has a single home" \
  "$manifest" 'let runtime_secret_name = '

require "the workload suffix has a single home" \
  "$manifest" 'let workload_secret_name name ='

if [ "$fail" -ne 0 ]; then
  echo "check_runtime_secret_identity: the migration reader, the class writer and the runtime Secret could disagree" >&2
  exit 1
fi

echo "check_runtime_secret_identity: readers and writers resolve the same identities"
