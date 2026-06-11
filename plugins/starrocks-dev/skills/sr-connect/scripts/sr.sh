#!/usr/bin/env bash
# Run an ad-hoc command on the remote StarRocks dev host.
#   sr.sh '<cmd>'          run on the HOST
#   sr.sh --src '<cmd>'    run in $SR_SRC with STARROCKS_HOME set (and inside SR_DOCKER if configured)
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

if [[ "${1:-}" == "--src" ]]; then
  shift
  [[ -n "${1:-}" ]] || sr_die "usage: sr.sh --src '<command>'"
  rsrc "$1"
else
  [[ -n "${1:-}" ]] || sr_die "usage: sr.sh '<command>'   (or --src '<command>')"
  rsh "$1"
fi
