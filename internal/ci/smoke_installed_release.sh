#!/usr/bin/env bash
set -euo pipefail

archive="$1" version="$2" runner="$3" dev_binary="$4"
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work" "$root/.smoke-reachback"' EXIT

tar -C "$work" -xzf "$archive"
install="$work/sol-$version"
[ -x "$install/bin/sol" ] || { echo "smoke: $archive has no sol-$version/bin/sol" >&2; exit 1; }
mkdir -p "$work/dev"
cp "$dev_binary" "$work/dev/sol"

image=sol-installed-smoke-runtime
docker build -q -t "$image" - >/dev/null <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 libgmp10 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE

in_container() {
  local mount="$1"; shift
  docker run --rm --network none --read-only --tmpfs /tmp -e HOME=/tmp \
    -v "$mount:/opt/sol:ro" "$image" "$@"
}

pass() { echo "  [OK]   $*"; }
die() { echo "  [FAIL] $*" >&2; exit 1; }

echo "installed-release smoke: $archive"

got="$(in_container "$install" /opt/sol/bin/sol --version)"
[ "$got" = "$version" ] || die "sol --version printed '$got', expected $version"
pass "sol --version is $version"

out="$(in_container "$install" /opt/sol/bin/sol assets)" || { echo "$out"; die "sol assets failed in the installed layout"; }
echo "$out" | sed 's/^/         /'
grep -qx "assets: installed release $version" <<<"$out" || die "not resolved as installed release $version"
grep -qx "  root: /opt/sol/share/sol/$version" <<<"$out" || die "root is not the installed bundle"
grep -qx "  ok  migration runner  $runner" <<<"$out" || die "runner is not the release's published digest"
grep -qx "all assets present" <<<"$out" || die "assets incomplete"
# Both image references the bundle needs must be in the assembled artifact itself: a release
# that provisions a database must not depend on an ambient variable (#1427). The report line
# and the file are checked, so a bundle that carries a file nothing resolves still fails.
setup="$(cat "$install/share/sol/$version/setup-image")" \
  || die "the installed bundle has no setup-image"
grep -qx "  ok  database setup image  $setup" <<<"$out" \
  || die "the setup image is not the release's pinned digest"
pass "sol assets: the setup image is the release's pinned digest"
pass "sol assets: installed bundle, every consumer ran, runner is $runner"

if in_container "$install" env SOL_HOME=/nonexistent /opt/sol/bin/sol assets >/dev/null 2>&1; then
  die "an invalid SOL_HOME fell through"
fi
pass "an invalid SOL_HOME is an error, not a fall-through"

# There is no `sol cloud` group: the user model is target-addressed. The whole target is
# reconciled by `sol deploy`, destroyed by the top-level `sol destroy` (which keeps its
# destructive confirmation), and audited by the target-scoped `sol target reconcile`. The
# removed `sol cloud` group and its plan/apply/bootstrap/destroy members must not reappear
# through the installed bundle, whose layout differs from the development build that
# cli/test/test_target_command_surface.sh checks.
root_surface="$(in_container "$install" /opt/sol/bin/sol --help=plain)" ||
  { echo "$root_surface"; die "sol --help failed from the read-only install"; }
if grep -Eq "^[[:space:]]+cloud[[:space:]]" <<<"$root_surface"; then
  die "the removed sol cloud group is still public in the installed release"
fi
destroy_surface="$(in_container "$install" /opt/sol/bin/sol destroy --help=plain)" ||
  { echo "$destroy_surface"; die "sol destroy --help failed from the read-only install"; }
grep -Eq "^[[:space:]]+sol destroy" <<<"$destroy_surface" ||
  die "sol destroy is missing from the installed release"
grep -Fq -- "--apply" <<<"$destroy_surface" ||
  die "sol destroy lost the --apply destructive confirmation"
target_surface="$(in_container "$install" /opt/sol/bin/sol target --help=plain)" ||
  { echo "$target_surface"; die "sol target --help failed from the read-only install"; }
for command in show reconcile; do
  grep -Eq "^[[:space:]]+$command[[:space:]]" <<<"$target_surface" ||
    die "sol target $command is missing from the installed release"
done
pass "sol destroy is top-level, sol target owns the ownership audit, and there is no sol cloud group"

# `sol plan` is the read-only whole-target preview. From the installed bundle it has to
# read a workspace with no checkout and run without a writable install or Terraform on
# PATH. A fresh target's installation prerequisites are not established, so the
# infrastructure plan defers rather than failing. The Terraform working directory and
# cloud backend identity are asserted where Terraform actually runs: the offline
# lifecycle harness (DEC-050) and cli/test/inline/test_terraform_workdir.ml.
cloud="$work/cloud"
mkdir -p "$cloud/ws/sol"
printf 'project: installed-smoke\n' >"$cloud/ws/sol.yml"
cat >"$cloud/ws/sol/environments.yml" <<'YAML'
prod:
  targets:
    aws/us-east-1:
      shape: local
      base_domain: example.test
      cluster_name: installed-smoke
      letsencrypt_email: ops@example.test
      cluster_endpoint_cidr: 203.0.113.0/24
      state_bucket: installed-smoke-state
      aws:
        state_lock_table: installed-smoke-lock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
YAML
if ! out="$(docker run --rm --network none --read-only --tmpfs /tmp -e HOME=/tmp \
      -v "$install:/opt/sol:ro" -v "$cloud/ws:/work" -w /work \
      -e PATH=/usr/local/bin:/usr/bin:/bin -e XDG_DATA_HOME=/tmp/xdg \
      "$image" /opt/sol/bin/sol plan prod/aws/us-east-1 2>&1)"; then
  echo "$out"; die "sol plan failed from the read-only install"
fi
grep -qx "Project: installed-smoke" <<<"$out" ||
  { echo "$out"; die "sol plan did not read the installed-smoke declaration"; }
grep -qx "Target: prod/aws/us-east-1" <<<"$out" ||
  { echo "$out"; die "sol plan did not resolve the target"; }
pass "sol plan previews the whole target from the read-only install"

refws="$work/refws"
mkdir -p "$refws"
git -C "$root" archive HEAD examples/pluto | tar -x -C "$refws"
# `prod/aws/us-east-1` declares no `kube_context`, so the plan cannot read the current
# release to inherit workload images from. A target-wide plan needs an immutable
# `--image-ref` for every workload, as a first deploy does, so supply the complete map.
# The names are exactly examples/pluto/sol.yml's services, including the deliberate
# `orders_svc`/`order_svc` and `fulfilment_worker`/`fulfillment_worker` pairs (distinct
# OCaml and TypeScript workloads). `resolve` refuses a name outside the declared scope,
# so a stale name here fails the plan rather than passing silently.
# The digest only has to be valid-shaped; the plan resolves the input contract and
# nothing is pulled.
ref_digest="sha256:$(printf '0%.0s' $(seq 64))"
image_refs=()
for svc in checkout_svc charge_svc notify_worker orders_svc fulfilment_worker order_svc fulfillment_worker; do
  image_refs+=("--image-ref" "$svc=registry.example/$svc@$ref_digest")
done
if ! out="$(docker run --rm --network none --read-only --tmpfs /tmp -e HOME=/tmp \
      -v "$install:/opt/sol:ro" -v "$refws:/work" -w /work/examples/pluto \
      -e XDG_DATA_HOME=/tmp/xdg \
      "$image" /opt/sol/bin/sol plan prod/aws/us-east-1 "${image_refs[@]}" 2>&1)"; then
  echo "$out"
  die "sol plan failed on the reference workspace from the read-only install"
fi
grep -qx "Project: pluto" <<<"$out" || { echo "$out"; die "sol plan did not read the reference workspace's declaration"; }
grep -qx "Target: prod/aws/us-east-1" <<<"$out" || { echo "$out"; die "sol plan did not resolve the target"; }
pass "sol plan reads the reference workspace with no checkout and SOL_HOME unset"

if in_container "$install" sh -c "touch /opt/sol/share/sol/$version/platform/probe" >/dev/null 2>&1; then
  die "control: the install is writable in the container, so the check above proves nothing"
fi
pass "control: the install really is read-only there"

if out="$(in_container "$work/dev" /opt/sol/sol assets 2>&1)"; then
  echo "$out"; die "control: a development build found assets -- the container can see a checkout"
fi
grep -q "no Sol checkout above this binary" <<<"$out" || { echo "$out"; die "control: unexpected failure"; }
pass "control: a development build finds nothing to reach back to"

cp -a "$install" "$work/damaged"
rm -rf "$work/damaged/share/sol/$version/platform/shared/observability/dashboards"
if in_container "$work/damaged" /opt/sol/bin/sol assets >/dev/null 2>&1; then
  die "control: a bundle missing its dashboards passed"
fi
pass "control: a bundle missing an asset fails"

mkdir -p "$root/.smoke-reachback/bin"
cp "$install/bin/sol" "$root/.smoke-reachback/bin/sol"
if out="$(env -u SOL_HOME "$root/.smoke-reachback/bin/sol" assets 2>&1)"; then
  echo "$out"; die "control: a release binary used the checkout around it"
fi
grep -q "but its assets are not at" <<<"$out" || { echo "$out"; die "control: unexpected failure"; }
pass "control: a release binary never reaches back into a checkout"

echo "installed-release smoke: passed"
