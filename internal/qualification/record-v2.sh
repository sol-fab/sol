#!/usr/bin/env bash
# Emit one provider's v2 qualification record from an explicit evidence manifest.
#
# The harness, not this adapter, decides which evidence establishes each claim.
# The adapter reads the attempt identity from attempt.txt/phase-verdicts.txt,
# takes the contract and evaluator identity from the checked-out harness and the
# verified evaluator artifact, hashes every named evidence file, and validates
# the emitted record through the same loader promotion uses.
#
# Usage:
#   SOL_QUALIFICATION_EVALUATOR=/path/to/qualification-release \
#     internal/qualification/record-v2.sh \
#       --provider aws --attempt-dir DIR --candidate candidate.json \
#       --manifest evidence-manifest.json --out aws-record.json
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
evaluator="${SOL_QUALIFICATION_EVALUATOR:-}"
provider="" attempt_dir="" candidate="" manifest="" out=""

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider) provider="${2:-}"; shift 2 ;;
    --attempt-dir) attempt_dir="${2:-}"; shift 2 ;;
    --candidate) candidate="${2:-}"; shift 2 ;;
    --manifest) manifest="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'record-v2: unknown argument %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

require() {
  local name="$1" value="$2"
  if [ -z "$value" ]; then
    printf 'record-v2: missing %s\n' "$name" >&2
    exit 2
  fi
}

require SOL_QUALIFICATION_EVALUATOR "$evaluator"
require --provider "$provider"
require --attempt-dir "$attempt_dir"
require --candidate "$candidate"
require --manifest "$manifest"
require --out "$out"
case "$provider" in
  aws | gcp) ;;
  *) printf 'record-v2: provider must be aws or gcp, not %s\n' "$provider" >&2; exit 2 ;;
esac
[ -x "$evaluator" ] || { printf 'record-v2: evaluator %s is not executable\n' "$evaluator" >&2; exit 2; }
[ -f "$attempt_dir/attempt.txt" ] || { printf 'record-v2: %s has no attempt.txt\n' "$attempt_dir" >&2; exit 2; }
[ -f "$attempt_dir/phase-verdicts.txt" ] || { printf 'record-v2: %s has no phase-verdicts.txt\n' "$attempt_dir" >&2; exit 2; }

exec "$evaluator" emit-record \
  --repository "$ROOT" \
  --attempt-dir "$attempt_dir" \
  --candidate "$candidate" \
  --manifest "$manifest" \
  --out "$out"
