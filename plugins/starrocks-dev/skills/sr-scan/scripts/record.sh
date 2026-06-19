#!/usr/bin/env bash
# sr-scan / record.sh — append a confirmed (or suspected) bug to a local markdown report.
# The report is the deliverable of a scan: a self-contained, copy-pasteable record of what
# the bug is, where it lives, how it was reproduced, and the minimal trigger.
#
#   record.sh add --title "lake compaction divides by zero on empty rowset" \
#     --status reproduced --component be/storage/lake \
#     --location be/src/storage/lake/compaction_task.cpp:142 --class divide-by-zero \
#     --method "failpoint:lake_compaction_empty" --signature "F0612 ... Check failed: n > 0" \
#     --trigger /tmp/repro.sql --root-cause "input_rowsets can be empty when ..." \
#     --fix "guard n==0 before the division"
#   record.sh list                         # show recorded findings + status
#
# Writes to ./bug-scan-findings.md by default (override with --file). The file lives with
# you (commit it / keep it in your scratchpad); record.sh never touches the remote host.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

FILE="bug-scan-findings.md"
# allow --file before the subcommand
while [[ "${1:-}" == --file ]]; do FILE="$2"; shift 2; done
cmd="${1:-}"; shift || true

usage() {
  cat >&2 <<'EOF'
usage: record.sh [--file FINDINGS.md] add  [fields]
       record.sh [--file FINDINGS.md] list

add fields (all optional except --title):
  --title T          one-line summary of the bug                      (required)
  --status S         reproduced | suspected | false-positive          (default: suspected)
  --component C      module, e.g. be/storage/lake or fe/planner
  --location L       file:line (function)
  --class K          bug class, e.g. null-deref / overflow / race / divide-by-zero
  --method M         repro method, e.g. SQLTest / gtest / failpoint:<name> / syscall:EIO / kfail / ebpf
  --signature SIG    the observed crash/error line(s)
  --trigger FILE     a .sql / .cpp file to embed verbatim as the minimal trigger
  --root-cause RC    why it happens
  --fix FIX          suggested fix
  --notes N          anything else

Default file: ./bug-scan-findings.md
EOF
  exit "${1:-2}"
}

case "$cmd" in
  list)
    [[ -f "$FILE" ]] || { sr_log "no findings file yet at $FILE"; exit 0; }
    echo "── $FILE ──"
    grep -nE '^## |(\*\*Status\*\*|- \*\*Status\*\*)' "$FILE" | sed 's/^/  /'
    ;;

  add)
    TITLE=""; STATUS="suspected"; COMP=""; LOC=""; CLASS=""; METHOD=""; SIG=""; TRIG=""; RC=""; FIX=""; NOTES=""
    while [[ $# -gt 0 ]]; do case "$1" in
      --title) TITLE="$2"; shift 2 ;; --status) STATUS="$2"; shift 2 ;;
      --component) COMP="$2"; shift 2 ;; --location) LOC="$2"; shift 2 ;;
      --class) CLASS="$2"; shift 2 ;; --method) METHOD="$2"; shift 2 ;;
      --signature) SIG="$2"; shift 2 ;; --trigger) TRIG="$2"; shift 2 ;;
      --root-cause) RC="$2"; shift 2 ;; --fix) FIX="$2"; shift 2 ;; --notes) NOTES="$2"; shift 2 ;;
      -h|--help) usage 0 ;;
      *) sr_die "unknown field '$1' (see --help)" ;;
    esac; done
    [[ -n "$TITLE" ]] || sr_die "--title is required"
    case "$STATUS" in reproduced|suspected|false-positive) ;; *) sr_die "--status must be reproduced|suspected|false-positive" ;; esac
    [[ -z "$TRIG" || -f "$TRIG" ]] || sr_die "no such --trigger file: $TRIG"

    # Create the file with a header if missing.
    if [[ ! -f "$FILE" ]]; then
      { echo "# StarRocks static-scan bug findings"
        echo
        echo "Found by the sr-scan skill. Each entry is self-contained: location, root cause,"
        echo "reproduction method, and the minimal trigger to reproduce it."
      } > "$FILE"
    fi
    n=$(grep -cE '^## [0-9]+\.' "$FILE" 2>/dev/null || true); n=$(( ${n:-0} + 1 ))
    ts=$(date '+%Y-%m-%d %H:%M')
    badge="🟠 suspected"; [[ "$STATUS" == reproduced ]] && badge="🔴 reproduced"; [[ "$STATUS" == false-positive ]] && badge="⚪ false-positive"

    {
      echo
      echo "## $n. $TITLE"
      echo
      echo "- **Status**: $badge"
      [[ -n "$COMP" ]]   && echo "- **Component**: \`$COMP\`"
      [[ -n "$LOC" ]]    && echo "- **Location**: \`$LOC\`"
      [[ -n "$CLASS" ]]  && echo "- **Bug class**: $CLASS"
      [[ -n "$METHOD" ]] && echo "- **Repro method**: $METHOD"
      echo "- **Recorded**: $ts"
      [[ -n "$RC" ]]     && { echo; echo "**Root cause**"; echo; echo "$RC"; }
      if [[ -n "$SIG" ]]; then echo; echo "**Observed signature**"; echo; echo '```'; printf '%s\n' "$SIG"; echo '```'; fi
      if [[ -n "$TRIG" ]]; then
        trig_ext="${TRIG##*.}"; echo; echo "**Minimal trigger** (\`$(basename "$TRIG")\`)"; echo
        echo "\`\`\`$trig_ext"; cat "$TRIG"; echo "\`\`\`"
      fi
      [[ -n "$FIX" ]]    && { echo; echo "**Suggested fix**"; echo; echo "$FIX"; }
      [[ -n "$NOTES" ]]  && { echo; echo "**Notes**: $NOTES"; }
    } >> "$FILE"

    sr_log "recorded finding #$n ($badge) -> $FILE"
    ;;

  ""|-h|--help|help) usage 0 ;;
  *) sr_die "unknown command '$cmd' (add | list)" ;;
esac
