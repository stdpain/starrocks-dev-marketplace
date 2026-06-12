#!/usr/bin/env bash
# sr-rollout — replace the binaries on a LIVE StarRocks cluster's nodes with the
# freshly built artifacts from a worktree profile's output/, THROUGH the dev host.
#
# Topology (same as sr-inspect): the target cluster is reachable from the dev host
# (SR_HOST, configured by sr-connect), which acts as the jump. Every mysql / ssh /
# tar runs ON the dev host over the existing SSH ControlMaster. The build artifacts
# live on the dev host at <profile SR_HOST_SRC>/output/{fe,be} — they are streamed
# (tar over ssh) onto each cluster node, which the dev host can reach.
#
# Source of the binaries: a worktree profile (SR_PROFILE=<name>). Build it FIRST with
# sr-build, ideally on an OS-matched dev-env image so the binary's glibc/ABI matches
# the cluster nodes (workspace.sh create --image <os-matched>). `plan` cross-checks the
# profile's image against each node's OS and warns on a mismatch.
#
# Strategy: FULL replacement, node by node. BEs are rolled first (FE stays up so each
# BE's Alive can be verified via SQL), then FEs. Each node: stop → back up current
# lib/bin → push new lib/bin → start → health-check. Backups under
# <node-home>/.sr-rollout-backup/<ts> enable `rollback`.
#
# Cluster connection params: a mysql connection string (--conn / SR_CL_CONN) parsed by
# srcluster.sh; node access via --ssh-user/--ssh-pass(+--sudo) like sr-inspect.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"      # profile config: SR_HOST / SR_HOST_SRC / SR_IMAGE / SR_SRC
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srcluster.sh"  # cluster helpers: cl_mysql / cl_node_run / cl_push_dir / ...

usage() {
  cat >&2 <<'EOF'
sr-rollout — push a worktree profile's freshly built output/ onto a live cluster's
nodes (full binary replacement), THROUGH the dev host.

  SR_PROFILE=<name> bash scripts/rollout.sh --conn '<mysql str>' \
      --ssh-user <u> --ssh-pass <pw> --sudo <command>

Binary source (REQUIRED): set SR_PROFILE to the worktree profile you built. Artifacts
are read from that profile's <SR_HOST_SRC>/output/{fe,be} on the dev host. (No profile
= the default profile's output/.)

Cluster source (same parsing as sr-inspect; lowest→highest: SR_CL_* env, --conn, flags):
  --conn '<str>'       a mysql connection string         (SR_CL_CONN)   ← primary input
  --fe/--port/--user/--password/--db ...                 (override parsed fields)
Node-SSH flags (for stop/start/push on each node — fixed account + password, +sudo):
  --ssh-user <u>       node ssh user                     (SR_CL_SSH_USER)
  --ssh-pass <pw>      node ssh password (sshpass)       (SR_CL_SSH_PASS)
  --ssh-key  <path>    node ssh key (instead of password)(SR_CL_SSH_KEY)
  --ssh-port <p>       node ssh port                     (SR_CL_SSH_PORT, default 22)
  --sudo               run node ops + extract under sudo (SR_CL_SUDO=1; assumes NOPASSWD)
Rollout options:
  --fe-home <path>     override the detected FE install dir on every node (SR_RO_FE_HOME)
  --be-home <path>     override the detected BE install dir on every node (SR_RO_BE_HOME)
  --yes                skip the confirmation prompt before apply (SR_RO_YES=1)

Commands:
  plan                 (default) list nodes, OS, detected install dirs, the profile's
                       build output + image, and warn on any OS/image mismatch. No changes.
  apply [all|be|fe]    full replacement on the nodes (default all = BEs then FEs).
  rollback [all|be|fe] restore each node's most recent .sr-rollout-backup.
  status               SHOW FRONTENDS / SHOW BACKENDS + current binary mtime per node.

Build first:  SR_PROFILE=<name> bash ../sr-build/scripts/build.sh
EOF
  exit "${1:-2}"
}

# ---- params: shared cluster/ssh flags via srcluster.sh; rollout-only flags here ----
FE_HOME="${SR_RO_FE_HOME:-}"; BE_HOME="${SR_RO_BE_HOME:-}"; ASSUME_YES="${SR_RO_YES:-}"
POS=()
while [[ $# -gt 0 ]]; do
  cl_take_flag "$1" "${2:-}"
  if [[ "$CL_TAKEN" == 1 ]]; then shift "$CL_SHIFT"; continue; fi
  case "$1" in
    --fe-home) FE_HOME="$2"; shift 2 ;;
    --be-home) BE_HOME="$2"; shift 2 ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) usage 0 ;;
    --)        shift; POS+=("$@"); break ;;
    -*)        sr_die "unknown option '$1' (see --help)" ;;
    *)         POS+=("$1"); shift ;;
  esac
done
cl_finalize_params

cmd="${POS[0]:-plan}"
role="${POS[1]:-all}"
case "$role" in all|be|fe) ;; *) sr_die "role must be all|be|fe, got '$role'" ;; esac

# ---- build output on the dev host ----
sr_resolve_host_src                       # fills SR_HOST_SRC (profile's source on the dev host)
OUT="$SR_HOST_SRC/output"

# out_check — confirm the profile's output/{fe,be} exists on the dev host; print a one
# line summary (binary mtimes) so the operator can see WHAT is about to ship.
out_check() {
  local need="$1"   # "fe", "be", or "fe be"
  local snippet='ok=1'
  for c in $need; do
    case "$c" in
      be) snippet+='; if [ -x "'"$OUT"'/be/lib/starrocks_be" ]; then echo "BE  output: '"$OUT"'/be (starrocks_be $(date -r "'"$OUT"'/be/lib/starrocks_be" +%F\ %T))"; else echo "MISSING '"$OUT"'/be/lib/starrocks_be"; ok=0; fi' ;;
      fe) snippet+='; if [ -d "'"$OUT"'/fe/lib" ]; then echo "FE  output: '"$OUT"'/fe/lib ($(ls "'"$OUT"'"/fe/lib/*.jar 2>/dev/null | wc -l) jars, newest $(date -r "$(ls -t "'"$OUT"'"/fe/lib/*.jar 2>/dev/null|head -1)" +%F\ %T 2>/dev/null))"; else echo "MISSING '"$OUT"'/fe/lib"; ok=0; fi' ;;
    esac
  done
  snippet+='; [ "$ok" = 1 ] || exit 7'
  cl_hostrun "$snippet" || sr_die "build output incomplete under $OUT — build the profile first: SR_PROFILE=${SR_PROFILE:-<name>} bash ../sr-build/scripts/build.sh"
}

# image_os — the OS token of the profile's dev-env image (the build environment).
image_os() {
  case "${SR_IMAGE:-}" in *dev-env-centos*) echo centos ;; *dev-env-ubuntu*) echo ubuntu ;; *) echo unknown ;; esac
}

# ---- node discovery & per-role home detection ----
# nodes_for_role [role] — emit "FE <ip>" / "BE <ip>" lines, filtered by the given role
# (defaults to the command-line $role: all|be|fe).
nodes_for_role() {
  local want="${1:-$role}" r ip
  cl_node_list | while read -r r ip; do
    [[ -n "$ip" ]] || continue
    case "$want" in all) ;; be) [[ "$r" == BE ]] || continue ;; fe) [[ "$r" == FE ]] || continue ;; esac
    echo "$r $ip"
  done
}

# detect_home <role> <node> — echo the install dir of the FE/BE on <node>, or "" if it
# can't be found. Honors --fe-home/--be-home overrides. Uses the running process:
#   BE: <home> = dirname(dirname(readlink /proc/<pid>/exe))  (exe = <home>/lib/starrocks_be)
#   FE: <home> = /proc/<pid>/cwd, normalized so it contains lib/  (start_fe cd's to home)
detect_home() {
  local r="$1" node="$2"
  if [[ "$r" == BE && -n "$BE_HOME" ]]; then echo "$BE_HOME"; return; fi
  if [[ "$r" == FE && -n "$FE_HOME" ]]; then echo "$FE_HOME"; return; fi
  local snip
  if [[ "$r" == BE ]]; then
    snip='pid=$(pgrep -x starrocks_be | head -1); [ -n "$pid" ] || exit 0
exe=$(readlink -f /proc/$pid/exe 2>/dev/null); [ -n "$exe" ] || exit 0
echo "$(dirname "$(dirname "$exe")")"'
  else
    snip='pid=$(pgrep -f com.starrocks.StarRocksFE | head -1); [ -n "$pid" ] || exit 0
home=$(readlink -f /proc/$pid/cwd 2>/dev/null)
[ "$(basename "$home")" = bin ] && home=$(dirname "$home")
if [ ! -d "$home/lib" ]; then
  d=$(tr "\0" " " < /proc/$pid/cmdline 2>/dev/null | grep -oE "[^ ]*/fe/lib" | head -1)
  [ -n "$d" ] && home=$(dirname "$d")
fi
echo "$home"'
  fi
  cl_node_run "$node" "$snip" 2>/dev/null | tr -d '[:space:]'
}

# node_alive <role> <ip> — echo true/false from SHOW FRONTENDS/BACKENDS for that ip.
node_alive() {
  local r="$1" ip="$2" tbl
  [[ "$r" == FE ]] && tbl=FRONTENDS || tbl=BACKENDS
  cl_mysql "SHOW $tbl\\G" 2>/dev/null | awk -v ip="$ip" '
    /^ *IP:/{cur=$2}
    /^ *Alive:/{if(cur==ip) print tolower($2)}' | head -1
}

# wait_alive <role> <ip> — poll until the node reports Alive, up to ~90s.
wait_alive() {
  local r="$1" ip="$2" i
  for i in $(seq 1 18); do
    [[ "$(node_alive "$r" "$ip")" == true ]] && { sr_log "  $r $ip is Alive."; return 0; }
    sleep 5
  done
  sr_log "  $r $ip did NOT come back Alive within ~90s — check logs (sr-inspect logs $ip $([[ $r == FE ]] && echo fe || echo be))."
  return 1
}

# ---- per-node operations ----
# Subdirs to swap for a full replacement (present-only ones are skipped).
BE_DIRS=(lib bin www)
FE_DIRS=(lib bin spark-dpp webroot)

stop_node()  { local r="$1" home="$2" node="$3"
  if [[ "$r" == BE ]]; then cl_node_run "$node" "'$home/bin/stop_be.sh' 2>/dev/null || pkill -x starrocks_be || true"
  else                      cl_node_run "$node" "'$home/bin/stop_fe.sh' 2>/dev/null || pkill -f com.starrocks.StarRocksFE || true"; fi
}
start_node() { local r="$1" home="$2" node="$3"
  if [[ "$r" == BE ]]; then cl_node_run "$node" "'$home/bin/start_be.sh' --daemon"
  else                      cl_node_run "$node" "'$home/bin/start_fe.sh' --daemon"; fi
}

# backup_node <home> <node> <dirs...> — copy current dirs into a fresh timestamped
# backup under <home>/.sr-rollout-backup/<ts>, and record it as the latest for rollback.
backup_node() {
  local home="$1" node="$2"; shift 2; local dirs="$*"
  local snip='set -e; home="'"$home"'"; ts=$(date +%Y%m%d-%H%M%S); bk="$home/.sr-rollout-backup/$ts"
mkdir -p "$bk"
for d in '"$dirs"'; do [ -e "$home/$d" ] && cp -a "$home/$d" "$bk/"; done
echo "$bk" > "$home/.sr-rollout-last-backup"
echo "    backed up [ '"$dirs"' ] -> $bk"'
  cl_node_run "$node" "$snip"
}

# rollout_node <role> <node> — the full per-node cycle.
rollout_node() {
  local r="$1" node="$2"
  local home; home=$(detect_home "$r" "$node")
  [[ -n "$home" ]] || { sr_log "  ! could not detect the $r install dir on $node — pass --$([[ $r == FE ]] && echo fe || echo be)-home <path>"; return 1; }
  local src dirs; if [[ "$r" == BE ]]; then src="$OUT/be"; dirs="${BE_DIRS[*]}"; else src="$OUT/fe"; dirs="${FE_DIRS[*]}"; fi
  sr_log "▶ $r $node  (home=$home)"
  backup_node "$home" "$node" $dirs
  stop_node "$r" "$home" "$node"
  local d
  for d in $dirs; do
    # only push subdirs that exist in the build output
    cl_hostrun "[ -e '$src/$d' ]" >/dev/null 2>&1 || { sr_log "    (skip $d — not in output)"; continue; }
    sr_log "    push $d ..."
    cl_push_dir "$node" "$src" "$d" "$home" || { sr_log "    ! push $d failed"; return 1; }
  done
  start_node "$r" "$home" "$node"
  wait_alive "$r" "$node"
}

rollback_node() {
  local r="$1" node="$2"
  local home; home=$(detect_home "$r" "$node")
  [[ -n "$home" ]] || { sr_log "  ! could not detect the $r install dir on $node — pass --$([[ $r == FE ]] && echo fe || echo be)-home <path>"; return 1; }
  sr_log "↩ $r $node  (home=$home)"
  local snip='set -e; home="'"$home"'"; bk=$(cat "$home/.sr-rollout-last-backup" 2>/dev/null || true)
[ -n "$bk" ] && [ -d "$bk" ] || { echo "    no backup recorded for this node"; exit 9; }
for d in "$bk"/*; do [ -e "$d" ] && cp -a "$d" "$home/"; done
echo "    restored from $bk"'
  cl_node_run "$node" "$snip" || { sr_log "    ! rollback failed on $node"; return 1; }
  stop_node "$r" "$home" "$node"; start_node "$r" "$home" "$node"; wait_alive "$r" "$node"
}

# run the cycle over BEs first (FE stays up to verify each), then FEs. Honors the
# command-line role filter (all|be|fe).
for_each_node() {
  local fn="$1"; local rc=0 bes="" fes="" r ip
  [[ "$role" != fe ]] && bes=$(nodes_for_role be)
  [[ "$role" != be ]] && fes=$(nodes_for_role fe)
  while read -r r ip; do [[ -n "$ip" ]] || continue; "$fn" "$r" "$ip" || rc=1; done <<< "$bes"
  while read -r r ip; do [[ -n "$ip" ]] || continue; "$fn" "$r" "$ip" || rc=1; done <<< "$fes"
  return $rc
}

confirm() {
  [[ -n "$ASSUME_YES" ]] && return 0
  printf 'starrocks-dev: %s  Type "yes" to proceed: ' "$1" >&2
  local ans; read -r ans </dev/tty 2>/dev/null || ans=""
  [[ "$ans" == yes ]] || sr_die "aborted (no confirmation). Re-run with --yes to skip this prompt."
}

# ---- commands ----
case "$cmd" in
  plan)
    cl_need_fe
    echo "── source (worktree profile '${SR_PROFILE:-default}') ──"
    echo "  dev host    : $(sr_target)"
    echo "  build image : ${SR_IMAGE:-<unset>}  (built on: $(image_os))"
    out_check "$([[ "$role" == fe ]] && echo fe || { [[ "$role" == be ]] && echo be || echo 'fe be'; })"
    echo "── target cluster nodes ──"
    img_os=$(image_os)
    nodes_for_role | while read -r r ip; do
      os=$(cl_node_os "$ip" 2>/dev/null || echo "?")
      home=$(detect_home "$r" "$ip"); home="${home:-<undetected — pass --${r,,}-home>}"
      warn=""
      [[ "$img_os" != unknown && "$os" != unknown && "$os" != "?" && "$os" != "$img_os" ]] \
        && warn="  ⚠ OS MISMATCH (binary built on $img_os, node is $os — glibc/ABI risk; rebuild on a $os dev-env image)"
      printf '  %s %-15s os=%-7s home=%s%s\n' "$r" "$ip" "$os" "$home" "$warn"
    done
    echo
    echo "Apply with:  SR_PROFILE=${SR_PROFILE:-<name>} bash scripts/rollout.sh --conn '...' --ssh-user .. --ssh-pass .. --sudo apply${role:+ $role}"
    ;;

  apply)
    cl_need_fe
    out_check "$([[ "$role" == fe ]] && echo fe || { [[ "$role" == be ]] && echo be || echo 'fe be'; })"
    sr_log "FULL replacement from profile '${SR_PROFILE:-default}' output ($OUT) onto role=$role nodes."
    confirm "About to stop, swap binaries on, and restart the cluster's $role node(s) — backups are taken first."
    for_each_node rollout_node
    rc=$?
    echo "── post-rollout status ──"
    cl_mysql "SELECT current_version() AS version; SHOW BACKENDS\\G SHOW FRONTENDS\\G" || true
    [[ $rc -eq 0 ]] && sr_log "rollout complete." || sr_die "rollout finished with errors — see above; rollback a node with: rollback"
    ;;

  rollback)
    cl_need_fe
    confirm "About to restore the most recent backup on each $role node and restart it."
    for_each_node rollback_node
    echo "── post-rollback status ──"
    cl_mysql "SHOW BACKENDS\\G SHOW FRONTENDS\\G" || true
    ;;

  status)
    cl_need_fe
    cl_mysql "SELECT current_version() AS version; SHOW FRONTENDS\\G SHOW BACKENDS\\G" || true
    echo "── installed binary mtime per node ──"
    nodes_for_role | while read -r r ip; do
      home=$(detect_home "$r" "$ip"); [[ -n "$home" ]] || { echo "  $r $ip  <home undetected>"; continue; }
      if [[ "$r" == BE ]]; then
        cl_node_run "$ip" 'echo "  BE '"$ip"'  starrocks_be $(date -r "'"$home"'/lib/starrocks_be" +%F\ %T 2>/dev/null)"' 2>/dev/null
      else
        cl_node_run "$ip" 'echo "  FE '"$ip"'  newest jar $(date -r "$(ls -t "'"$home"'"/lib/*.jar 2>/dev/null|head -1)" +%F\ %T 2>/dev/null)"' 2>/dev/null
      fi
    done
    ;;

  *) usage ;;
esac
