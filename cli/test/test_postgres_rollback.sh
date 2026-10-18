#!/usr/bin/env bash
# Real command orchestration against the existing offline provider fakes. The
# adapter supplies only Kubernetes responses required by a single recorded release.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
sol="$(realpath "$1")"
record="$(realpath "$2")"
tmp="$(mktemp -d)"
trap 'test_status=$?; if [ "$test_status" -ne 0 ] && [ -f "$tmp/output" ]; then cat "$tmp/output" >&2; fi; rm -rf "$tmp"; exit "$test_status"' EXIT
mkdir -p "$tmp/bin" "$tmp/work/sol" "$tmp/work/app/test/reader_svc" "$tmp/work/db/migrations" "$tmp/markers" "$tmp/records"
cp "$root"/internal/ci/lifecycle_fakes/* "$tmp/bin/"
mv "$tmp/bin/kubectl" "$tmp/bin/kubectl-base"
export TEST_PG_ROOT="$tmp" FAKE_CONFIGMAP_DIR="$tmp/records" FAIL_MARKER_DIR="$tmp/markers"
export LIFECYCLE_LOG="$tmp/calls" SOL_HOME="$root" XDG_DATA_HOME="$tmp/xdg"
export PATH="$tmp/bin:/usr/bin:/bin" SOL_WHOAMI_RETRY_INTERVAL_S=0 KUBECONFIG="$tmp/kubeconfig"
export SOL_MIGRATION_RUNNER_IMAGE=registry.example.test/migrate@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$tmp/bin/kubectl" <<'PY'
#!/usr/bin/python3
import json, os, pathlib, sys
args=sys.argv[1:]; root=pathlib.Path(os.environ['TEST_PG_ROOT'])
with (root/'calls').open('a') as f: f.write('kubectl-adapter '+' '.join(args)+'\n')
def emit(x): print(json.dumps(x)); sys.exit(0)
def value(flag, default=''): return args[args.index(flag)+1] if flag in args else default
verb=next((x for x in args if x in ('get','apply','create','replace','patch','logs')), '')
if verb in ('apply','create','replace') and '-f' in args:
    with (root/'manifests').open('a') as f: f.write(pathlib.Path(value('-f')).read_text()+'\n---\n')
if verb=='get':
    i=args.index('get'); kind=args[i+1]; name=args[i+2] if len(args)>i+2 else ''; ns=value('-n')
    if kind=='externalsecret':
        emit({'metadata':{'name':name,'namespace':ns,'uid':'class-uid','generation':2,'labels':{'app.kubernetes.io/managed-by':'sol'}},'spec':{'target':{'name':name}},'status':{'refreshTime':'2026-10-18T12:00:00Z','syncedResourceVersion':'2-abc','conditions':[{'type':'Ready','status':'True','reason':'SecretSynced'}]}})
    if kind=='secret':
        emit({'metadata':{'ownerReferences':[{'uid':'class-uid'}]},'data':{'POSTGRES_URL':'cG9zdGdyZXNxbDovL3VzZXI6cGFzc0BkYi9hcHA='}})
    if kind=='job' and 'status.succeeded' in value('-o'): print('1'); sys.exit(0)
    if kind=='job' and 'status.failed' in value('-o'): sys.exit(0)
    if kind=='deployment' and not value('-o').startswith('jsonpath'):
        release=(root/'release').read_text().strip()
        emit({'items':[{'metadata':{'name':'reader','namespace':'work-test','uid':'reader-uid'},'spec':{'template':{'metadata':{'labels':{'workspace':'work','release':release}}}}}]})
    if kind=='configmap' and name=='sol-release-current-work' and value('-o').startswith('jsonpath'):
        print((root/'release').read_text().strip()); sys.exit(0)
if verb=='logs':
    emit({'migrations':[]})
os.execv(str(root/'bin/kubectl-base'), [str(root/'bin/kubectl-base')]+args)
PY
chmod +x "$tmp/bin/kubectl"
printf 'FROM scratch\n' > "$tmp/work/app/test/reader_svc/Dockerfile"
printf '[service]\n' > "$tmp/work/app/test/reader_svc/sol.toml"
# The current application no longer consumes the database. The recorded release does.
cat > "$tmp/work/sol.yml" <<'YAML'
project: work
resources:
  app_db:
    type: postgres
services:
  reader_svc:
    type: http
    path: app/test/reader_svc
YAML
cat > "$tmp/work/sol/environments.yml" <<'YAML'
prod:
  targets:
    aws/us-east-1:
      shape: durable
      cluster_name: lifecycle-test
      kube_context: offline-postgres
      aws:
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
      resources:
        app_db:
          binding:
            ownership: external
            store: current-vault
            credentials:
              ddl: current/ddl
              dml: current/dml
YAML
"$record" --workspace work --out "$tmp/records" --own deployment:work-test:reader:reader-uid --uses app_db > "$tmp/release"
printf 'deployment\twork-test\treader\treader-uid\n' > "$tmp/owned"
export OWNED_WORKLOADS_FILE="$tmp/owned"
cd "$tmp/work"
if ! timeout 45 "$sol" rollback "$(cat "$tmp/release")" --target prod/aws/us-east-1 > "$tmp/output" 2>&1; then
  cat "$tmp/output" "$tmp/calls" >&2; exit 1
fi
python3 - "$tmp" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); text=(root/'manifests').read_text(); calls=(root/'calls').read_text(); output=(root/'output').read_text()
for required in ('current-vault','current/ddl','current/dml','prod-aws-us-east-1-ddl-creds','prod-aws-us-east-1-dml-creds','work-test'):
    assert required in text, (required,text)
assert 'prod-aws-us-east-1-db-ca' not in text, text
assert text.index('current/ddl') < text.index('sol-migrate-status'), text
assert text.index('current/dml') < text.index('sol-migrate-status'), text
assert 'Verified: workloads and pointer both name release' in output, output
PY
printf 'PostgreSQL rollback: current external authority, historical consumers, DDL/DML delivery, migration read and final verification passed.\n'

# Actual migrate commands use the selected DDL class and trust policy too.
run_migrations() {
  local trust="$1"
  printf '%s\n' '-- sol:disposition expand' 'SELECT 1;' > db/migrations/001_init.sql
  : > "$tmp/manifests"
  if ! timeout 30 "$sol" migrate apply prod/aws/us-east-1 > "$tmp/output" 2>&1; then cat "$tmp/output" >&2; exit 1; fi
  grep -F 'Done.' "$tmp/output" >/dev/null
  grep -F 'prod-aws-us-east-1-ddl-creds' "$tmp/manifests" >/dev/null
  if [ "$trust" = managed ]; then
    grep -F 'prod-aws-us-east-1-db-ca' "$tmp/manifests" >/dev/null
  else
    grep -F 'migration/ddl' "$tmp/manifests" >/dev/null
    grep -F 'migration-vault' "$tmp/manifests" >/dev/null
    if grep -E 'prod-aws-us-east-1-db-ca|current/dml|current/ddl' "$tmp/manifests" >/dev/null; then
      echo 'external migration reused prior source or changed application credentials' >&2; exit 1
    fi
  fi
  : > "$tmp/manifests"
  if ! timeout 30 "$sol" migrate apply prod/aws/us-east-1 --dry-run > "$tmp/output" 2>&1; then cat "$tmp/output" >&2; exit 1; fi
  grep -F 'SELECT 1;' "$tmp/output" >/dev/null
  grep -F 'sol-migrate-status' "$tmp/manifests" >/dev/null
  if [ "$trust" = external ]; then
    grep -F 'migration/ddl' "$tmp/manifests" >/dev/null
    grep -F 'migration-vault' "$tmp/manifests" >/dev/null
    if grep -F 'current/dml' "$tmp/manifests" >/dev/null; then echo 'read-only status rewrote workload credentials' >&2; exit 1; fi
  fi
  rm db/migrations/001_init.sql
}
cp sol/environments.yml "$tmp/pre-migration-environments"
sed -i 's|current/ddl|migration/ddl|;s|current-vault|migration-vault|' sol/environments.yml
run_migrations external
cp "$tmp/pre-migration-environments" sol/environments.yml

# Managed rollback consumes the existing class credentials and published CA;
# local rollback uses its runtime Secret; an absent database needs no SQL Job.
cp sol/environments.yml "$tmp/valid-environments"
python3 - "$tmp/valid-environments" sol/environments.yml <<'PYTHON'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text().split('      resources:')[0]
pathlib.Path(sys.argv[2]).write_text(s)
PYTHON
run_migrations managed
: > "$tmp/manifests"; : > "$tmp/calls"
if ! timeout 45 "$sol" rollback "$(cat "$tmp/release")" --target prod/aws/us-east-1 > "$tmp/output" 2>&1; then cat "$tmp/output" >&2; exit 1; fi
grep -F 'prod-aws-us-east-1-db-ca' "$tmp/manifests" >/dev/null
grep -F 'prod-aws-us-east-1-ddl-creds' "$tmp/manifests" >/dev/null
if grep -F 'current-vault' "$tmp/manifests" >/dev/null; then echo 'managed rollback reused external authority' >&2; exit 1; fi
: > "$tmp/manifests"; : > "$tmp/calls"
if ! timeout 45 "$sol" local rollback "$(cat "$tmp/release")" > "$tmp/output" 2>&1; then cat "$tmp/output" >&2; exit 1; fi
grep -F 'sol-secrets' "$tmp/manifests" >/dev/null
if grep -E 'prod-aws-us-east-1-db-ca|current-vault' "$tmp/manifests" >/dev/null; then echo 'local rollback reused target authority' >&2; exit 1; fi
cat >> sol/environments.yml <<'YAML'
      resources:
        app_db:
          omit: true
YAML
# The historical database requirement cannot disappear when the target omits it,
# even when another database now exists. No application objects may be changed.
cp sol/environments.yml "$tmp/absent-environments"
cp sol.yml "$tmp/original-workspace"
for replacement in absent replacement; do
  if [ "$replacement" = replacement ]; then
    python3 - <<'PYTHON'
from pathlib import Path
p=Path('sol.yml');s=p.read_text().replace('resources:\n','resources:\n  replacement_db:\n    type: postgres\n',1);p.write_text(s)
PYTHON
  fi
  : > "$tmp/manifests"; : > "$tmp/calls"
  if timeout 30 "$sol" rollback "$(cat "$tmp/release")" --target prod/aws/us-east-1 > "$tmp/output" 2>&1; then echo 'incompatible historical database was accepted' >&2; exit 1; fi
  grep -F 'no longer provides its required resources (app_db)' "$tmp/output" >/dev/null
  if grep -E 'kubectl(-adapter)? .* (apply|patch) ' "$tmp/calls" >/dev/null; then echo 'incompatible rollback mutated workloads' >&2; cat "$tmp/calls" >&2; exit 1; fi
done
cp "$tmp/absent-environments" sol/environments.yml
cp "$tmp/original-workspace" sol.yml
"$record" --workspace work --out "$tmp/records" --own deployment:work-test:reader:reader-uid > "$tmp/release"
: > "$tmp/manifests"; : > "$tmp/calls"
if ! timeout 45 "$sol" rollback "$(cat "$tmp/release")" --target prod/aws/us-east-1 > "$tmp/output" 2>&1; then cat "$tmp/output" >&2; exit 1; fi
if grep -E 'sol-migrate|ddl-creds|dml-creds|db-ca|current-vault' "$tmp/manifests" >/dev/null; then echo 'absent database invented delivery or SQL operations' >&2; exit 1; fi
: > "$tmp/calls"
if timeout 30 "$sol" migrate apply prod/aws/us-east-1 > "$tmp/output" 2>&1; then echo 'absent database allowed migration' >&2; exit 1; fi
grep -F 'declares no PostgreSQL resource' "$tmp/output" >/dev/null
if grep -E ' (create|apply|replace|patch|delete) ' "$tmp/calls" >/dev/null; then echo 'absent migration mutated' >&2; cat "$tmp/calls" >&2; exit 1; fi
# A historical Kafka requirement is valid without PostgreSQL when its authority
# remains declared; do not mistake every `uses` edge for a database dependency.
cp sol.yml "$tmp/no-kafka-workspace"
python3 - <<'PYTHON'
from pathlib import Path
p=Path('sol.yml');s=p.read_text().replace('resources:\n','resources:\n  event_log:\n    type: kafka\n',1);p.write_text(s)
PYTHON
"$record" --workspace work --out "$tmp/records" --own deployment:work-test:reader:reader-uid --uses event_log > "$tmp/release"
: > "$tmp/manifests"
if ! timeout 45 "$sol" rollback "$(cat "$tmp/release")" --target prod/aws/us-east-1 > "$tmp/output" 2>&1; then cat "$tmp/output" >&2; exit 1; fi
if grep -E 'sol-migrate|ddl-creds|dml-creds|db-ca' "$tmp/manifests" >/dev/null; then echo 'Kafka-only rollback invented PostgreSQL' >&2; exit 1; fi
cp "$tmp/no-kafka-workspace" sol.yml
cp "$tmp/valid-environments" sol/environments.yml
printf 'PostgreSQL rollback: managed, local and absent-database command paths passed.\n'

# Declarations must fail at the same boundary for deploy, migrate and rollback,
# before lease acquisition, setup, migration submission or provider mutation.
cp sol/environments.yml "$tmp/valid-environments"
for invalid in missing-store missing-ddl missing-dml blank-ddl connection private-ca extra-class; do
  python3 - "$tmp/valid-environments" sol/environments.yml "$invalid" <<'PY'
import pathlib, sys
source=pathlib.Path(sys.argv[1]).read_text(); case=sys.argv[3]
if case=='missing-store': source=source.replace('            store: current-vault\n','')
if case=='missing-ddl': source=source.replace('              ddl: current/ddl\n','')
if case=='missing-dml': source=source.replace('              dml: current/dml\n','')
if case=='blank-ddl': source=source.replace('ddl: current/ddl','ddl: " "')
if case=='connection': source+='            connection:\n              host: db.example.test\n'
if case=='private-ca': source+='            keys:\n              POSTGRES_CA_CERT: private/ca\n'
if case=='extra-class': source+='              ca: private/ca\n'
pathlib.Path(sys.argv[2]).write_text(source)
PY
  for command in deploy migrate rollback; do
    : > "$tmp/calls"
    case "$command" in
      deploy) args=(deploy prod/aws/us-east-1 --image-tag offline --registry registry.example.test --dry-run) ;;
      migrate) args=(migrate apply prod/aws/us-east-1) ;;
      rollback) args=(rollback "$(cat "$tmp/release")" --target prod/aws/us-east-1) ;;
    esac
    if timeout 30 "$sol" "${args[@]}" > "$tmp/output" 2>&1; then
      echo "invalid $invalid passed $command" >&2; exit 1
    fi
    if ! grep -E 'externally bound database|unsupported PostgreSQL inputs|resource "app_db" binding:|missing value for ddl' "$tmp/output" >/dev/null; then
      echo "$command did not reach binding validation ($invalid)" >&2; cat "$tmp/output" >&2; exit 1
    fi
    if grep -E 'kubectl(-adapter)? .* (create|apply|replace|patch|delete) |terraform .* (apply|destroy) ' "$tmp/calls" >/dev/null; then
      echo "$command mutated before refusing $invalid" >&2; cat "$tmp/calls" >&2; exit 1
    fi
  done
done
printf 'PostgreSQL invalid-input boundary: seven credential/trust cases refused before mutation in deploy, migrate and rollback.\n'
