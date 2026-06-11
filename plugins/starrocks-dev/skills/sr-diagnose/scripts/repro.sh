#!/usr/bin/env bash
# Attempt to reproduce a StarRocks crash, then report the evidence + steps.
# Flow: (optional) build -> cluster up -> snapshot logs -> fire trigger -> watch
#       be.out/fe.log for the crash signature.
#
#   repro.sh --build asan --sql /tmp/repro.sql --match 'SIGSEGV|Check failed'
#   repro.sh --build asan --gtest 'SegmentIteratorTest.*' --match 'AddressSanitizer'
#   repro.sh --sql /tmp/repro.sql            # use an already-built/running cluster
#
# Exit 0 = signature observed (reproduced), non-0 = not reproduced.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

BUILD=""; SQL=""; GTEST=""; MATCH='SIG(SEGV|ABRT|BUS)|Check failed|terminate called|AddressSanitizer|core dumped|\*\*\* Aborted'; TIMEOUT=120
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD="$2"; shift 2 ;;
    --sql)   SQL="$2";   shift 2 ;;
    --gtest) GTEST="$2"; shift 2 ;;
    --match) MATCH="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) sr_die "unknown arg: $1" ;;
  esac
done
[[ -n "$SQL" || -n "$GTEST" ]] || sr_die "need a trigger: --sql <file> or --gtest <filter>"
[[ -z "$SQL" || -f "$SQL" ]]   || sr_die "no such SQL file: $SQL"

MH="${SR_MYSQL_HOST:-127.0.0.1}"
DEPLOY="$PLUGIN_ROOT/skills/sr-deploy/scripts/deploy.sh"
BUILDSH="$PLUGIN_ROOT/skills/sr-build/scripts/build.sh"

# Mirror deploy's run-root resolution so we tail the right logs and connect on the
# right (auto-allocated/pinned) port.
if [[ -n "${SR_DEPLOY_DIR:-}" ]]; then
  RP='OUT="${STARROCKS_OUTPUT:-$STARROCKS_HOME/output}"; RUN="'"$SR_DEPLOY_DIR"'";'
else
  RP='OUT="${STARROCKS_OUTPUT:-$STARROCKS_HOME/output}"; RUN="$OUT";'
fi
# Query port: prefer the port deploy pinned for this cluster, else config/default.
load_query_port() {
  local p; p=$(rsrc "$RP "'[ -f "$RUN/.sr-ports.env" ] && . "$RUN/.sr-ports.env" 2>/dev/null && printf %s "$QUERY_PORT"' 2>/dev/null)
  [[ "$p" =~ ^[0-9]+$ ]] && QP="$p" || QP="${SR_QUERY_PORT:-9030}"
}
QP="${SR_QUERY_PORT:-9030}"

# --- Optional build ---
if [[ -n "$BUILD" ]]; then
  case "$BUILD" in
    asan)    bt=Asan ;;
    debug)   bt=Debug ;;
    release) bt=Release ;;
    none)    bt="" ;;
    *) sr_die "--build must be asan|debug|release|none" ;;
  esac
  if [[ -n "$bt" ]]; then
    sr_log "building BE ($bt) for reproduction ..."
    BUILD_TYPE="$bt" bash "$BUILDSH" --be || sr_die "build failed — fix the build before reproducing"
  fi
fi

# --- gtest path: the test IS the trigger; no cluster needed ---
if [[ -n "$GTEST" ]]; then
  sr_log "running BE test trigger: --gtest_filter '$GTEST'"
  log=$(mktemp)
  # run-be-ut.sh defaults to ASan, which is what we want for memory crashes.
  bash "$PLUGIN_ROOT/skills/sr-test/scripts/test.sh" be --gtest_filter "$GTEST" 2>&1 | tee "$log"
  if grep -qE "$MATCH" "$log"; then
    echo; sr_log "✓ REPRODUCED — signature matched in test output:"; grep -nE "$MATCH" "$log" | head -10
    exit 0
  else
    sr_log "✗ not reproduced via gtest (no '$MATCH' in output). Try --build asan or a different filter."; exit 1
  fi
fi

# --- SQL path: bring cluster up, snapshot, fire, watch logs ---
sr_log "ensuring cluster is up ..."
bash "$DEPLOY" up >/dev/null || sr_die "cluster failed to come up — see: bash $DEPLOY logs fe"
load_query_port
sr_log "connecting on query port $QP"

# Snapshot current log sizes so we only read NEW lines after the trigger.
read -r FE0 BE0 < <(rsrc "$RP "'echo $(wc -l < "$RUN/fe/log/fe.log" 2>/dev/null || echo 0) $(wc -l < "$RUN/be/log/be.out" 2>/dev/null || echo 0)')
FE0="${FE0:-0}"; BE0="${BE0:-0}"

sr_log "firing SQL trigger ($SQL) ..."
b64=$(base64 < "$SQL" | tr -d '\n')
set +e
rsrc "echo $b64 | base64 -d > /tmp/sr_repro.sql && mysql -h'$MH' -P'$QP' -uroot < /tmp/sr_repro.sql"
sql_rc=$?
set -e
sr_log "mysql client exit: $sql_rc (a dropped connection / non-zero here often means the FE/BE just died)"

# Watch the new log tail for the crash signature.
sr_log "watching logs up to ${TIMEOUT}s for: $MATCH"
hit=""
for ((i=0; i<TIMEOUT; i+=3)); do
  new=$(rsrc "$RP "'tail -n +'"$((BE0+1))"' "$RUN/be/log/be.out" 2>/dev/null; tail -n +'"$((FE0+1))"' "$RUN/fe/log/fe.log" 2>/dev/null' 2>/dev/null)
  if printf '%s' "$new" | grep -qE "$MATCH"; then hit="$new"; break; fi
  sleep 3
done

echo
if [[ -n "$hit" ]]; then
  sr_log "✓ REPRODUCED — crash signature in the logs:"
  printf '%s\n' "$hit" | grep -nE "$MATCH" | head -10
  echo "── surrounding be.out tail ──"
  rsrc "$RP "'tail -n 40 "$RUN/be/log/be.out" 2>/dev/null'
  exit 0
else
  sr_log "✗ not reproduced within ${TIMEOUT}s."
  sr_log "Tips: build ASan (--build asan), minimize differently, or widen --match. Inspect: bash $DEPLOY logs be"
  exit 1
fi
