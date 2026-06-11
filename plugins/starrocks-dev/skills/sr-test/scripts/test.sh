#!/usr/bin/env bash
# Run StarRocks test suites on the remote dev host.
#   test.sh fe|be|java-ext|regression [extra runner args...]
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

suite="${1:-}"; shift || true
[[ -n "$suite" ]] || sr_die "usage: test.sh fe|be|java-ext|regression [args...]"

# Ensure the dev-env container exists/runs before testing (no-op if SR_DOCKER unset,
# in which case tests run directly on the host).
sr_ensure_docker

# Resolve job count for the build-and-test runners.
jobs="${SR_JOBS:-}"
if [[ -z "$jobs" ]]; then
  jobs=$(rsrc 'nproc 2>/dev/null || echo 4' | tr -d '[:space:]')
  [[ "$jobs" =~ ^[0-9]+$ ]] || jobs=4
fi
build_type="${BUILD_TYPE:-$SR_BUILD_TYPE}"

# Quote passthrough args for the remote shell.
passthru=""
for a in "$@"; do passthru+=" $(printf '%q' "$a")"; done

case "$suite" in
  fe)
    sr_log "FE unit tests${passthru:+ ($passthru)} -j$jobs${SR_DOCKER:+ in $SR_DOCKER}"
    rsrc "./run-fe-ut.sh -j $jobs${passthru}" ;;
  be)
    sr_log "BE unit tests${passthru:+ ($passthru)} BUILD_TYPE=$build_type -j$jobs${SR_DOCKER:+ in $SR_DOCKER}"
    rsrc "export BUILD_TYPE='$build_type'; ./run-be-ut.sh -j $jobs${passthru}" ;;
  java-ext|java-exts)
    sr_log "Java-extension unit tests${passthru:+ ($passthru)}"
    rsrc "./run-java-exts-ut.sh${passthru}" ;;
  regression)
    sr_log "regression tests (needs a running cluster; reads test/conf/sr.conf)${passthru:+ ($passthru)}"
    rsrc "cd test && ./run.sh${passthru}" ;;
  *)
    sr_die "unknown suite '$suite'. Use: fe | be | java-ext | regression" ;;
esac
rc=$?
[[ $rc -eq 0 ]] && sr_log "tests passed ✓" || sr_die "tests failed (exit $rc) — read the output above"
