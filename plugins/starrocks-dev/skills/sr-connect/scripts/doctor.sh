#!/usr/bin/env bash
# Verify the remote host is ready to build StarRocks. Prints a ✓/✗ report.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

fail=0
row() { printf '  %-22s %s\n' "$1" "$2"; }

sr_log "connecting to $(sr_target) ..."
if ! sr_conn_test >/dev/null 2>&1; then
  sr_die "cannot reach $(sr_target). Run sr-connect setup.sh and check SSH access."
fi
row "ssh" "✓ $(sr_conn_test)"

# Container check.
if [[ -n "${SR_DOCKER:-}" ]]; then
  if rsh "docker inspect -f '{{.State.Running}}' '$SR_DOCKER' 2>/dev/null" | grep -q true; then
    img=$(rsh "docker inspect -f '{{.Config.Image}}' '$SR_DOCKER' 2>/dev/null")
    row "dev-env container" "✓ $SR_DOCKER running ($img)"
  elif rsh "docker inspect '$SR_DOCKER' >/dev/null 2>&1"; then
    row "dev-env container" "• $SR_DOCKER exists but stopped — run sr-connect env-up.sh"
  else
    row "dev-env container" "• $SR_DOCKER absent — run sr-connect env-up.sh to pull+create"
  fi
fi

# Source tree — checked where the build sees it (inside the container if SR_DOCKER set).
if rsrc "test -d '$SR_SRC'" 2>/dev/null; then
  if rsrc "test -f '$SR_SRC/build.sh' && test -d '$SR_SRC/be' && test -d '$SR_SRC/fe'" 2>/dev/null; then
    info=$(rsrc 'echo "$(git rev-parse --abbrev-ref HEAD 2>/dev/null) @ $(git rev-parse --short HEAD 2>/dev/null)"')
    row "source ($SR_SRC)" "✓ StarRocks repo — $info"
  else
    row "source ($SR_SRC)" "✗ exists but missing build.sh / be / fe"; fail=1
  fi
else
  row "source ($SR_SRC)" "✗ not found at build path — check SR_SRC / SR_HOST_SRC mount"; fail=1
fi

# Toolchain (inside dev-env if SR_DOCKER set).
check_tool() {  # name  command
  local name="$1" cmd="$2" ver
  if ver=$(rsrc "$cmd" 2>/dev/null) && [[ -n "$ver" ]]; then
    row "$name" "✓ $ver"
  else
    row "$name" "✗ not found"; [[ "$3" == required ]] && fail=1
  fi
}
check_tool "java"   'java -version 2>&1 | head -1'                  required
check_tool "maven"  'mvn -v 2>/dev/null | head -1'                  required
check_tool "cmake"  'cmake --version 2>/dev/null | head -1'         required
check_tool "gcc/clang" 'gcc --version 2>/dev/null | head -1 || clang --version 2>/dev/null | head -1' required
check_tool "ccache" 'ccache --version 2>/dev/null | head -1'        optional

# Thirdparty.
tp=$(rsrc 'echo "${STARROCKS_THIRDPARTY:-}"' 2>/dev/null)
if [[ -n "$tp" ]] && rsrc "test -d '$tp/installed'" 2>/dev/null; then
  row "thirdparty" "✓ $tp"
else
  row "thirdparty" "✗ STARROCKS_THIRDPARTY unset or not built (run thirdparty/build-thirdparty.sh, or use the dev-env image)"; fail=1
fi

# Disk (host filesystem holding the source).
[[ -n "${SR_DOCKER:-}" ]] && sr_resolve_host_src 2>/dev/null || true
row "disk (source fs)" "$(rsh "df -h '${SR_HOST_SRC:-$SR_SRC}' 2>/dev/null | awk 'NR==2{print \$4\" free of \"\$2}'")"

echo
if [[ "$fail" -eq 0 ]]; then sr_log "remote is build-ready ✓"; else sr_die "remote NOT ready — fix the ✗ rows above"; fi
