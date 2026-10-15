#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
version="" runner="" setup_image="" out="" binary="" support_refs="" revision=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --runner-image) runner="$2"; shift 2 ;;
    --setup-image) setup_image="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --binary) binary="$2"; shift 2 ;;
    --support-refs) support_refs="$2"; shift 2 ;;
    --revision) revision="$2"; shift 2 ;;
    *) echo "build-release-bundle: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$version" ] && [ -n "$runner" ] && [ -n "$setup_image" ] && [ -n "$out" ] || {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
if ! [[ "$runner" =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "build-release-bundle: --runner-image must be a digest reference (<image>@sha256:<64 hex>), got $runner" >&2
  exit 2
fi
# The database setup image is public, so unlike the runner there is nothing to publish -- but it
# still has to be *shipped*, because a release uses only its own assets: a deploy that provisions
# a database must not depend on an ambient variable being set on the operator's machine (#1427).
if ! [[ "$setup_image" =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "build-release-bundle: --setup-image must be a digest reference (<image>@sha256:<64 hex>), got $setup_image" >&2
  exit 2
fi

if [ -z "$binary" ]; then
  (cd "$root" && SOL_RELEASE_VERSION="$version" dune build cli/bin/main.exe)
  binary="$root/_build/default/cli/bin/main.exe"
fi
reported="$("$binary" --version)"
if [ "$reported" != "$version" ]; then
  echo "build-release-bundle: $binary reports version '$reported', not $version -- build it with SOL_RELEASE_VERSION=$version" >&2
  exit 1
fi

# The bundle names the revision it was built from, so a live qualification can
# bind the application it builds and runs to the exact candidate it is gathering
# evidence for rather than to whatever a checkout or a moving ref happens to hold
# (sol-fab/sol#1280). A bundle assembled from a modified tree could not honestly
# name one revision, so it is refused rather than recorded.
head_revision="$(git -C "$root" rev-parse HEAD 2>/dev/null)" || {
  echo "build-release-bundle: $root is not a git work tree, so it cannot name the revision it contains" >&2
  exit 1
}
if [ -n "$revision" ] && [ "$revision" != "$head_revision" ]; then
  echo "build-release-bundle: --revision $revision is not the checked-out revision $head_revision" >&2
  exit 1
fi
revision="$head_revision"
if [ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]; then
  echo "build-release-bundle: $root has modified tracked files, so the bundle would name revision $revision while containing other content" >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
prefix="$stage/sol-$version"
share="$prefix/share/sol/$version"
mkdir -p "$prefix/bin" "$share"
install -m 0755 "$binary" "$prefix/bin/sol"
printf '%s\n' "$version" >"$share/VERSION"
printf '%s\n' "$revision" >"$share/REVISION"
printf '%s\n' "$runner" >"$share/migration-runner-image"
printf '%s\n' "$setup_image" >"$share/setup-image"
if [ -n "$support_refs" ]; then cp "$support_refs" "$share/SUPPORT_REFS"; fi
git -C "$root" ls-files -z -- platform | (cd "$root" && xargs -0 cp --parents -t "$share")

mkdir -p "$out"
archive="$out/sol-$version-linux-x86_64.tar.gz"
tar -C "$stage" -czf "$archive" "sol-$version"
echo "$archive"
