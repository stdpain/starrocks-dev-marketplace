#!/usr/bin/env bash
# Locate the source behind a crash/stack/issue. Reads a file arg or stdin ('-').
#   analyze.sh /tmp/crash.txt
#   analyze.sh /tmp/crash.txt --addr2line     # also symbolize raw BE addresses
#   pbpaste | analyze.sh -
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

DO_ADDR2LINE=0
crash=""
for a in "$@"; do
  case "$a" in
    --addr2line) DO_ADDR2LINE=1 ;;
    -) crash="-" ;;
    *) crash="$a" ;;
  esac
done
[[ -n "$crash" ]] || { [[ ! -t 0 ]] && crash="-"; }
[[ -n "$crash" ]] || sr_die "usage: analyze.sh <crash/stack file>   (or '-' for stdin)"
if [[ "$crash" == "-" ]]; then tmp=$(mktemp); cat > "$tmp"; crash="$tmp"; fi
[[ -f "$crash" ]] || sr_die "no such file: $crash"

echo "════ crash signature ════"
grep -nE 'SIG(SEGV|ABRT|BUS|FPE|ILL|TERM)|signal [0-9]+|Check failed|F[0-9]{4} .*\]|terminate called|AddressSanitizer|heap-(use-after-free|buffer-overflow)|stack-overflow|std::(bad_alloc|out_of_range|length_error|runtime_error|logic_error)|Memory.*(exceed|limit)|Out[Oo]f[Mm]emory|NullPointerException|StackOverflowError|ArrayIndexOutOfBounds|assert(ion)? .*failed' "$crash" \
  | head -25 || echo "(no obvious signature line — inspect manually)"

# --- Extract candidate tokens ---
# C++ qualified symbols (contain ::) and Java FQNs.
mapfile -t syms < <(grep -oE '[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_~]*)+' "$crash" \
  | grep -vE '^(std|__gnu_cxx|boost|google|absl)::' | sort -u | head -25)
mapfile -t javas < <(grep -oE '\b(com|org|io)\.[A-Za-z0-9_.$]+\.[A-Za-z0-9_$]+' "$crash" \
  | grep -E '\.starrocks\.|starrocks' | sort -u | head -15)
# file:line frames.
mapfile -t frames < <(grep -oE '[A-Za-z0-9_./-]+\.(cpp|cc|cxx|h|hpp|java):[0-9]+' "$crash" | sort -u | head -25)

echo; echo "════ implicated frames (file:line) → blame ════"
if ((${#frames[@]})); then
  for f in "${frames[@]}"; do
    path="${f%%:*}"; line="${f##*:}"
    # normalize: strip leading build dirs, keep repo-relative tail
    rel=$(printf '%s' "$path" | sed -E 's#^.*/(be/src/|fe/|gensrc/|java-extensions/)#\1#')
    found=$(rsrc "if [ -f '$rel' ]; then echo '$rel'; else git ls-files | grep -m1 -E '/$(basename "$path")\$' || true; fi" 2>/dev/null | tr -d '\r')
    if [[ -n "$found" ]]; then
      echo "• $found:$line"
      rsrc "git blame -L $line,$line --date=short -- '$found' 2>/dev/null | sed 's/^/    /'; echo '    last commit on file:'; git log -1 --format='      %h %ad %an  %s' --date=short -- '$found'" 2>/dev/null
    else
      echo "• $f  (not resolved in repo — maybe thirdparty/generated)"
    fi
  done
else
  echo "(no file:line frames in the trace)"
fi

echo; echo "════ implicated symbols → definition/usage in \$SR_SRC ════"
for s in "${syms[@]}" "${javas[@]}"; do
  [[ -z "$s" ]] && continue
  # search the leaf name to catch declarations across files
  leaf="${s##*::}"; leaf="${leaf##*.}"
  hits=$(rsrc "grep -rn --include='*.cpp' --include='*.cc' --include='*.h' --include='*.hpp' --include='*.java' -F '$leaf' be/src fe/fe-core/src gensrc java-extensions 2>/dev/null | head -4" 2>/dev/null)
  if [[ -n "$hits" ]]; then
    echo "• $s"
    printf '%s\n' "$hits" | sed 's/^/    /'
  fi
done

if [[ "$DO_ADDR2LINE" -eq 1 ]]; then
  echo; echo "════ addr2line (raw BE addresses) ════"
  mapfile -t addrs < <(grep -oE '0x[0-9a-fA-F]{6,}' "$crash" | sort -u | head -30)
  if ((${#addrs[@]})); then
    list="${addrs[*]}"
    # GNU addr2line is *extremely* slow on StarRocks' compressed .debug_* sections.
    # Prefer llvm-addr2line; otherwise decompress the sections once (cached copy)
    # with objcopy and run GNU addr2line on that. One invocation for all addresses.
    rsrc "set -e
      be=\$(ls \${STARROCKS_OUTPUT:-\$STARROCKS_HOME/output}/be/lib/starrocks_be 2>/dev/null | head -1 || true)
      [ -z \"\$be\" ] && be=\$(ls \$STARROCKS_HOME/be/build_*/src/exec/starrocks_be 2>/dev/null | head -1 || true)
      if [ -z \"\$be\" ]; then echo 'starrocks_be binary not found — build BE first (sr-build --be)'; exit 0; fi
      echo \"binary: \$be\"
      a2l=\$(command -v llvm-addr2line 2>/dev/null || ls /usr/lib/llvm-*/bin/llvm-addr2line 2>/dev/null | head -1 || true)
      if [ -n \"\$a2l\" ]; then
        echo \"using \$a2l (fast, handles compressed debug sections)\"
        \"\$a2l\" -Cfe \"\$be\" $list
      else
        tmp=/tmp/sr_be_decomp
        if [ ! -f \"\$tmp\" ] || [ \"\$be\" -nt \"\$tmp\" ]; then
          echo 'no llvm-addr2line; decompressing debug sections once (objcopy) ...'
          objcopy --decompress-debug-sections \"\$be\" \"\$tmp\" 2>/dev/null || cp \"\$be\" \"\$tmp\"
        fi
        addr2line -Cfe \"\$tmp\" $list
      fi"
  else
    echo "(no raw addresses found)"
  fi
fi

echo; echo "Next: bash scripts/known.sh '<symbol or message>'   then if new:   bash scripts/repro.sh ..."
