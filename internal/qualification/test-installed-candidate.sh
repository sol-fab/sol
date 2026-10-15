#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/install/share/sol/v0.0.0"
printf 'postgres@sha256:%064d\n' 0 >"$tmp/install/share/sol/v0.0.0/setup-image"
python3 - "$tmp" <<'PY'
import hashlib, json, pathlib, sys, tarfile
root = pathlib.Path(sys.argv[1])
archive = root / 'bundle.tar.gz'
with tarfile.open(archive, 'w:gz') as bundle:
    bundle.add(root / 'install', arcname='sol-v0.0.0')
(root / 'candidate.json').write_text(json.dumps(dict(
    version='v0.0.0', revision='a'*40, runner_image='runner', bundle=archive.name,
    bundle_sha256=hashlib.sha256(archive.read_bytes()).hexdigest())))
PY
verify() (
  source "$here/sol-under-test.sh"
  SOL_INSTALL="$tmp/install" SOL_CANDIDATE="$tmp/candidate.json"
  SOL_BUNDLE_VERSION=v0.0.0 SOL_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa SOL_RUNNER_IMAGE=runner
  sol_under_test_verify_candidate
)
verify
printf 'different setup digest\n' >"$tmp/install/share/sol/v0.0.0/setup-image"
if verify >"$tmp/error" 2>&1; then
  echo 'accepted a substituted setup image' >&2; exit 1
fi
grep -q 'installed file differs' "$tmp/error"
printf 'corrupt archive' >>"$tmp/bundle.tar.gz"
if verify >"$tmp/error" 2>&1; then
  echo 'accepted a substituted archive' >&2; exit 1
fi
grep -q 'bundle_sha256 does not match' "$tmp/error"
rm "$tmp/bundle.tar.gz"
if verify >"$tmp/error" 2>&1; then
  echo 'accepted an absent archive' >&2; exit 1
fi
printf 'installed candidate: matching bundle accepted; changed setup image, changed archive, and absent archive refused\n'
