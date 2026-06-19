#!/usr/bin/env bash
# sr-scan / scan.sh — STATIC risk scan over a StarRocks module or execution flow on the
# remote dev host. It greps the source ($SR_SRC, in the dev-env container when SR_DOCKER
# is set) for high-signal bug patterns and groups the hits by bug class, then (with
# --hooks) enumerates the reproduction HOOKS in that code (failpoints, sync points, tests).
#
# The output is a TRIAGE WORKLIST, not a verdict: most hits are fine. The agent reads each
# candidate, follows the path, and decides whether it is a real bug before reproducing it.
#
#   scan.sh be/src/storage/lake                 # scan a module directory
#   scan.sh --files be/src/exprs/cast_expr.cpp  # scan specific files (comma-separated)
#   scan.sh --flow ChunkAggregator::aggregate   # scan files defining/using a symbol
#   scan.sh be/src/storage/lake --hooks          # also list failpoints/syncpoints/tests
#   scan.sh fe/fe-core/.../planner --lang java   # force the Java pattern set
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

usage() {
  cat >&2 <<'EOF'
usage: scan.sh <module-path> [opts]
   or: scan.sh --files a.cpp,b.cpp [opts]
   or: scan.sh --flow <Symbol> [scope-path] [opts]

Scans StarRocks source on the remote dev host for risky patterns, grouped by bug class.
Paths are RELATIVE to $SR_SRC (e.g. be/src/storage/lake, fe/fe-core/src/main/java/...).

  --files <a,b,..>   scan an explicit comma-separated file list
  --flow <Symbol>    scan files that define/reference <Symbol> (a function/class). An
                     optional path after it scopes the search (default: be/src fe/fe-core)
  --lang cpp|java|auto   pattern set (default auto: applies both)
  --max  <N>         max hits per pattern (default 30)
  --hooks            also enumerate failpoints / sync points / tests in the scope
  --hooks-only       only enumerate hooks (skip the pattern scan)

Next: read the candidates, keep the real ones, reproduce with inject.sh
(failpoint/syscall/ebpf/kfail) or sr-diagnose's repro.sh (SQL/gtest), then log confirmed
bugs with record.sh.
EOF
  exit "${1:-2}"
}

MODE=module; TARGET=""; SCOPE=""; FILES=""; LANGSEL=auto; MAX=30; HOOKS=0; HOOKS_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --files)      FILES="$2"; MODE=files; shift 2 ;;
    --flow)       TARGET="$2"; MODE=flow; shift 2 ;;
    --lang)       LANGSEL="$2"; shift 2 ;;
    --max)        MAX="$2"; shift 2 ;;
    --hooks)      HOOKS=1; shift ;;
    --hooks-only) HOOKS=1; HOOKS_ONLY=1; shift ;;
    -h|--help)    usage 0 ;;
    -*)           sr_die "unknown option '$1' (see --help)" ;;
    *)            if [[ "$MODE" == flow && -z "$SCOPE" && -n "$TARGET" ]]; then SCOPE="$1"
                  elif [[ -z "$TARGET" ]]; then TARGET="$1"
                  else sr_die "unexpected arg '$1'"; fi; shift ;;
  esac
done
[[ "$MAX" =~ ^[0-9]+$ ]] || sr_die "--max must be a number"
case "$LANGSEL" in cpp|java|auto) ;; *) sr_die "--lang must be cpp|java|auto" ;; esac
case "$MODE" in
  module) [[ -n "$TARGET" ]] || usage ;;
  files)  [[ -n "$FILES" ]] || usage ;;
  flow)   [[ -n "$TARGET" ]] || usage; [[ -n "$SCOPE" ]] || SCOPE="be/src fe/fe-core" ;;
esac

sr_ensure_docker  # source lives in the container when SR_DOCKER is set

# C++ / Java risk patterns: "label|||extended-regex". A hit is a place to LOOK, not a
# confirmed defect — the agent follows the path and decides.
read -r -d '' CPP_PATTERNS <<'PATS' || true
mem-unsafe|||\b(memcpy|memmove|memset|strcpy|strncpy|strcat|sprintf|alloca)[[:space:]]*\(
narrowing-cast|||(static_cast|reinterpret_cast)<[[:space:]]*(u?int(8|16|32)_t|int|unsigned|short|size_t)[[:space:]]*>\(
deref-after-cast|||(dynamic_cast|static_cast)<[^>;]*\*>\([^;]*\)[[:space:]]*->
throwing-conversion|||\b(std::)?(stoi|stol|stoll|stoul|stoull|stod|stof|stold)[[:space:]]*\(
container-at-throws|||(\.at\(|->at\()
empty-container-access|||\.(front|back|top)\(\)
unchecked-statusor|||(ValueOrDie\(|\.value\(\))
release-stripped-check|||\bDCHECK(_[A-Z]+)?\(
divide-by-variable|||[A-Za-z0-9_][[:space:]]*[/%][[:space:]]+[a-z_][A-Za-z0-9_.]*
size-arithmetic|||(\*[[:space:]]*sizeof\(|\bsizeof\([^)]*\)[[:space:]]*\*)
raw-resource|||(\bnew\b[^=;]*\[|\bmalloc\(|\bfree\()
todo-fixme|||(TODO|FIXME|XXX|HACK)\b
PATS

read -r -d '' JAVA_PATTERNS <<'PATS' || true
map-get-npe|||\.(get|remove|poll|peek)\([^)]*\)\.[A-Za-z]
boxing-or-optional-get|||\.get\(\)
parse-throws|||\b(Integer|Long|Double|Float|Short|Byte)\.(parse[A-Za-z]+|valueOf)\(
class-cast|||=[[:space:]]*\([[:space:]]*[A-Z][A-Za-z0-9_]*[[:space:]]*\)[[:space:]]*[a-z]
array-index|||\[[a-z_][A-Za-z0-9_]*\]
returns-null|||return[[:space:]]+null;
not-threadsafe|||(new[[:space:]]+SimpleDateFormat|static[[:space:]].*\b(HashMap|ArrayList|SimpleDateFormat)\b)
divide-by-variable|||[A-Za-z0-9_][[:space:]]*[/%][[:space:]]+[a-z_][A-Za-z0-9_.]*
substring|||\.substring\(
unchecked-cast-warn|||@SuppressWarnings\([^)]*unchecked
todo-fixme|||(TODO|FIXME|XXX|HACK)\b
PATS

# ---- build the remote script (base64-shipped by rsrc, so regex metachars are safe) ----
build_remote() {
  cat <<REMOTE
set -uo pipefail
MAX=$MAX; MODE='$MODE'
TARGET='$TARGET'; SCOPE='$SCOPE'; FILES='${FILES//,/ }'
EXCL='--exclude-dir=.git --exclude-dir=output --exclude-dir=build --exclude-dir=thirdparty --exclude-dir=target'
INC_C='--include=*.cpp --include=*.cc --include=*.h --include=*.hpp'
INC_J='--include=*.java'

case "\$MODE" in
  module) SCAN_PATHS="\$TARGET" ;;
  files)  SCAN_PATHS="\$FILES" ;;
  flow)   SCAN_PATHS=\$(grep -rlIE \$EXCL \$INC_C \$INC_J -e "\\b$TARGET\\b" \$SCOPE 2>/dev/null | head -60) ;;
esac
[ -n "\$SCAN_PATHS" ] || { echo "no files matched the scope"; exit 3; }

echo "════ scan scope ════"
echo "HEAD: \$(git rev-parse --abbrev-ref HEAD 2>/dev/null)@\$(git rev-parse --short HEAD 2>/dev/null)"
echo "files in scope: \$(grep -rlI '' \$EXCL \$INC_C \$INC_J \$SCAN_PATHS 2>/dev/null | wc -l)\$([ "\$MODE" = flow ] && echo " (reference '$TARGET')")"

run_set() {  # <label> <include-args> ; patterns on stdin as name|||regex
  local label="\$1" inc="\$2" name re hits c total=0
  echo; echo "════ \$label risk candidates (≤\$MAX/pattern — verify each) ════"
  while IFS= read -r line; do
    [ -n "\$line" ] || continue
    name="\${line%%|||*}"; re="\${line#*|||}"
    hits=\$(grep -rnIE \$EXCL \$inc -e "\$re" \$SCAN_PATHS 2>/dev/null | grep -vE '(_test|Test)\.(cpp|cc|java)' | head -\$MAX)
    if [ -n "\$hits" ]; then
      c=\$(printf '%s\n' "\$hits" | wc -l); total=\$((total+c))
      echo "── [\$name] (\$c) ──"; printf '%s\n' "\$hits" | sed 's/^/  /'
    fi
  done
  echo "  (\$label total: \$total)"
}
REMOTE

  if [[ "$HOOKS_ONLY" != 1 ]]; then
    [[ "$LANGSEL" == cpp || "$LANGSEL" == auto ]] && \
      printf "run_set CPP '%s' <<'EOPC'\n%s\nEOPC\n" '--include=*.cpp --include=*.cc --include=*.h --include=*.hpp' "$CPP_PATTERNS"
    [[ "$LANGSEL" == java || "$LANGSEL" == auto ]] && \
      printf "run_set JAVA '%s' <<'EOPJ'\n%s\nEOPJ\n" '--include=*.java' "$JAVA_PATTERNS"
  fi

  if [[ "$HOOKS" == 1 ]]; then
    cat <<'REMOTE'
echo; echo "════ reproduction hooks in scope ════"
echo "── failpoints (BE, controllable at runtime via SQL) ──"
grep -rnIE $EXCL $INC_C -e 'DEFINE_FAIL_POINT|FAIL_POINT_TRIGGER|PFAIL_POINT|SCOPED_FAIL_POINT|fail_point' $SCAN_PATHS 2>/dev/null | head -40 | sed 's/^/  /' || true
echo "── sync points (test-time interception) ──"
grep -rnIE $EXCL $INC_C -e 'SYNC_POINT|TEST_SYNC_POINT|DEBUG_SYNC|SyncPoint::' $SCAN_PATHS 2>/dev/null | head -30 | sed 's/^/  /' || true
echo "── existing tests referencing these file stems ──"
for b in $(printf '%s ' $SCAN_PATHS | xargs -n1 basename 2>/dev/null | sed -E 's/\.(cpp|cc|h|hpp|java)$//' | sort -u | head -20); do
  git ls-files "*${b}*_test.cpp" "*${b}*Test.java" 2>/dev/null
done | sort -u | head -30 | sed 's/^/  /' || true
REMOTE
  fi
}

rsrc "$(build_remote)"
