#!/usr/bin/env bash
# The shared runner sources this file as the scenario. Provider mechanics live in
# gcp.sh; the ordering and evidence live in scenario.sh.
set -uo pipefail
PROVIDER=gcp
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scenario.sh"
