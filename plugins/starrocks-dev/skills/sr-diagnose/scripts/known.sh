#!/usr/bin/env bash
# Check whether a crash is an already-known/fixed issue, using the remote repo's
# git history. (Network issue/PR search is the agent's job via WebSearch.)
#   known.sh '<symbol or message>'        search commit messages + content
#   known.sh --file be/src/storage/x.cpp  recent commits touching a file
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

if [[ "${1:-}" == "--file" ]]; then
  file="${2:?usage: known.sh --file <repo/path>}"
  echo "════ recent commits touching $file ════"
  rsrc "git log -n 20 --format='%h %ad %an  %s' --date=short -- '$file'"
  echo; echo "════ commits NOT yet in your checkout (upstream ahead) touching it ════"
  rsrc "base=\$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null); \
        [ -n \"\$base\" ] && git log --format='%h %ad %an  %s' --date=short \"\$base\"..origin/main -- '$file' 2>/dev/null | head -20 || echo '(no upstream ref / fetch origin first)'"
  exit 0
fi

q="$*"
[[ -n "$q" ]] || sr_die "usage: known.sh '<symbol or message>'   |   known.sh --file <path>"

echo "════ HEAD ════"
rsrc "echo \"\$(git rev-parse --abbrev-ref HEAD)@\$(git rev-parse --short HEAD)  \$(git log -1 --format=%cd --date=short)\""

echo; echo "════ commit messages mentioning: $q ════"
rsrc "git log --all -n 25 --format='%h %ad %an  %s' --date=short --grep='$q' -i 2>/dev/null | head -25 || echo '(none)'"

echo; echo "════ commits whose DIFF touched: $q (often the fix) ════"
rsrc "git log --all -n 15 --format='%h %ad %s' --date=short -S '$q' 2>/dev/null | head -15 || echo '(none)'"

echo; echo "Cross-check upstream (not searchable here): WebSearch"
echo "  • StarRocks crash \"$q\""
echo "  • site:github.com/StarRocks/starrocks \"$q\""
echo "If a matching fix commit exists, check whether your HEAD already contains it:"
echo "  bash scripts/../../sr-connect/scripts/sr.sh --src 'git merge-base --is-ancestor <fixsha> HEAD && echo PRESENT || echo MISSING'"
