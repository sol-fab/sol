#!/usr/bin/env bash

sol_under_test_die() {
  printf 'sol-under-test: %s\n' "$1" >&2
  exit 2
}

sol_under_test_resolve() {
  local install="${SOL_INSTALL:-}"
  if [ -z "$install" ]; then
    sol_under_test_die "set SOL_INSTALL to the extracted release prefix (the directory holding bin/sol and share/sol/<version>); a live qualification runs the artifact a user installs, never a repository build"
  fi
  [ -d "$install" ] || sol_under_test_die "SOL_INSTALL=$install is not a directory"
  install="$(cd "$install" && pwd)"
  SOL="$install/bin/sol"
  [ -x "$SOL" ] ||
    sol_under_test_die "no executable at $SOL; extract sol-<version>-linux-x86_64.tar.gz and set SOL_INSTALL to its sol-<version> prefix"
  local version
  if ! version="$("$SOL" --version 2>/dev/null)"; then
    sol_under_test_die "$SOL --version failed; the installed release must run on this host"
  fi
  case "$version" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) sol_under_test_die "$SOL reports '$version', which is a development build; a live qualification uses the installed release bundle (DEC-049)" ;;
  esac
  SOL_BUNDLE_VERSION="$version"
  SOL_SHARE_ROOT="$install/share/sol/$version"
  SOL_PLATFORM_ROOT="$SOL_SHARE_ROOT/platform"
  [ -f "$SOL_PLATFORM_ROOT/shared/components.json" ] ||
    sol_under_test_die "release $version has no platform bundle at $SOL_PLATFORM_ROOT"
  local runner_file="$install/share/sol/$version/migration-runner-image"
  [ -f "$runner_file" ] ||
    sol_under_test_die "release $version records no migration runner in $runner_file"
  SOL_RUNNER_IMAGE="$(head -n 1 "$runner_file")"
  case "$SOL_RUNNER_IMAGE" in
    *@sha256:*) ;;
    *) sol_under_test_die "release $version names migration runner '$SOL_RUNNER_IMAGE', which is not a digest reference" ;;
  esac
  # The revision the release was built from. A live qualification builds the
  # application under test from that revision -- never from whatever a checkout or
  # a moving ref happens to hold -- so a release that does not name one cannot be
  # qualified (sol-fab/sol#1280).
  local revision_file="$SOL_SHARE_ROOT/REVISION"
  [ -f "$revision_file" ] ||
    sol_under_test_die "release $version records no source revision in $revision_file; a live qualification binds the application it builds to the candidate, so the release must name the revision it contains"
  SOL_REVISION="$(head -n 1 "$revision_file")"
  case "$SOL_REVISION" in
    "" | *[!0-9a-f]*) sol_under_test_die "release $version records revision '$SOL_REVISION', which is not a 40-hex commit" ;;
  esac
  [ "${#SOL_REVISION}" -eq 40 ] ||
    sol_under_test_die "release $version records revision '$SOL_REVISION', which is not a 40-hex commit"
  sol_under_test_verify_candidate
  unset SOL_HOME
}

# One field of the candidate document the release machinery published.
sol_under_test_candidate_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

field, path = sys.argv[1], sys.argv[2]
try:
    with open(path) as handle:
        document = json.load(handle)
except Exception as error:
    print(f"the candidate document {path} is not readable JSON: {error}", file=sys.stderr)
    raise SystemExit(3)
value = document.get(field) if isinstance(document, dict) else None
if not isinstance(value, str) or not value:
    print(f"the candidate document {path} carries no {field}", file=sys.stderr)
    raise SystemExit(4)
print(value)
PY
}

# An install prefix says which release is on disk; only the candidate document
# says which candidate that release is. Without this the run would record its
# evidence against whatever prefix SOL_INSTALL happened to name -- an alpha.15
# attempt could provision with the alpha.14 CLI and file the result under
# alpha.15 (sol-fab/sol#1287).
sol_under_test_verify_candidate() {
  local path="${SOL_CANDIDATE:-}"
  local expected_version expected_revision expected_runner
  if [ -z "$path" ]; then
    sol_under_test_die "set SOL_CANDIDATE to the candidate document this run qualifies (the draft's candidate.json): an install prefix alone cannot say which candidate it holds, so the evidence would not name the candidate it belongs to"
  fi
  [ -f "$path" ] || sol_under_test_die "SOL_CANDIDATE=$path is not a file"
  expected_version="$(sol_under_test_candidate_field version "$path")" ||
    sol_under_test_die "the candidate document $path carries no usable version"
  expected_revision="$(sol_under_test_candidate_field revision "$path")" ||
    sol_under_test_die "the candidate document $path carries no usable revision"
  expected_runner="$(sol_under_test_candidate_field runner_image "$path")" ||
    sol_under_test_die "the candidate document $path carries no usable runner_image"
  [ "$SOL_BUNDLE_VERSION" = "$expected_version" ] ||
    sol_under_test_die "SOL_INSTALL holds release $SOL_BUNDLE_VERSION but the candidate is $expected_version: extract the candidate's own bundle and point SOL_INSTALL at it ($path)"
  [ "$SOL_REVISION" = "$expected_revision" ] ||
    sol_under_test_die "release $SOL_BUNDLE_VERSION was built from revision $SOL_REVISION but candidate $expected_version is revision $expected_revision: this install prefix is not that candidate"
  [ "$SOL_RUNNER_IMAGE" = "$expected_runner" ] ||
    sol_under_test_die "release $SOL_BUNDLE_VERSION pins migration runner $SOL_RUNNER_IMAGE but candidate $expected_version pins $expected_runner: this install prefix is not that candidate"
  # Compare the installed bytes with the archive covered by bundle_sha256.
  # Keep the downloaded archive beside candidate.json, as promotion does.
  python3 - "$path" "$SOL_INSTALL" <<'PYTHON' ||
import hashlib
import json
from pathlib import Path
import sys
import tarfile

candidate_path, install = map(Path, sys.argv[1:])
try:
    candidate = json.loads(candidate_path.read_text())
    archive = candidate_path.parent / candidate["bundle"]
    with archive.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != candidate["bundle_sha256"]:
        raise ValueError("candidate bundle_sha256 does not match the archive")
    with tarfile.open(archive) as bundle:
        for member in bundle:
            relative = Path(member.name).parts[1:]
            if not relative:
                continue
            if ".." in relative or Path(member.name).is_absolute():
                raise ValueError(f"invalid bundle member: {member.name}")
            installed = install.joinpath(*relative)
            if member.isfile():
                if installed.is_symlink():
                    raise ValueError(f"installed file is a symlink: {installed}")
                if installed.stat().st_mode & 0o111 != member.mode & 0o111:
                    raise ValueError(f"installed executable permissions differ: {installed}")
                with bundle.extractfile(member) as source, installed.open("rb") as target:
                    if hashlib.file_digest(source, "sha256").digest() != hashlib.file_digest(target, "sha256").digest():
                        raise ValueError(f"installed file differs from candidate bundle: {installed}")
            elif member.issym():
                if not installed.is_symlink() or installed.readlink() != Path(member.linkname):
                    raise ValueError(f"installed symlink differs from candidate bundle: {installed}")
except (OSError, ValueError, KeyError, tarfile.TarError) as error:
    print(f"sol-under-test: candidate bundle verification failed: {error}", file=sys.stderr)
    sys.exit(1)
PYTHON
    sol_under_test_die "keep the candidate's recorded archive beside SOL_CANDIDATE and extract that exact bundle into SOL_INSTALL"
  SOL_CANDIDATE_VERSION="$expected_version"
  SOL_CANDIDATE_REVISION="$expected_revision"
}

sol_under_test_record_identity() {
  local dir="$1"
  mkdir -p "$dir"
  {
    printf 'sol_install: %s\n' "$SOL_INSTALL"
    printf 'sol_version: %s\n' "$SOL_BUNDLE_VERSION"
    printf 'sol_revision: %s\n' "$SOL_REVISION"
    printf 'migration_runner_image: %s\n' "$SOL_RUNNER_IMAGE"
    printf 'candidate_document: %s\n' "${SOL_CANDIDATE:-none}"
  } >"$dir/sol-identity.txt"
}
