#!/bin/sh
set -eu
v="${SOL_RELEASE_VERSION:-}"
r="${SOL_RELEASE_REVISION:-}"

if [ -z "$v" ]; then
  version='None'
else
  if ! printf '%s' "$v" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
    echo "SOL_RELEASE_VERSION=$v is not a version (expected e.g. v0.1.0 or 0.1.0-rc.1)" >&2
    exit 1
  fi
  version="Some \"$v\""
fi

# The revision is the framework commit a generated workspace pins. A release
# build must name the tagged commit; a development build names its own HEAD.
# A build made outside a git checkout has no revision, and `sol new workspace`
# fails closed rather than emitting a moving ref.
if [ -z "$r" ]; then
  r="$(git rev-parse HEAD 2>/dev/null || true)"
fi
if [ -z "$r" ]; then
  revision='None'
else
  case "$r" in
    *[!0-9a-f]*)
      echo "SOL_RELEASE_REVISION=$r is not a lowercase 40-hex commit" >&2
      exit 1
      ;;
  esac
  if [ "${#r}" -ne 40 ]; then
    echo "SOL_RELEASE_REVISION=$r is not a 40-hex commit" >&2
    exit 1
  fi
  revision="Some \"$r\""
fi

printf 'let release_version = %s\n' "$version"
printf 'let revision = %s\n' "$revision"
