#!/usr/bin/env bash
# sr-inspect — connect to a LIVE StarRocks cluster THROUGH the dev host and inspect it
# for performance / correctness. You give a mysql connection string (--conn / SR_CL_CONN);
# the skill parses it and connects via the dev host (SR_HOST), which can reach the cluster.
# Every mysql / curl / ssh below runs ON the dev host over the existing SSH ControlMaster.
#
# Connection params are passed PER-INVOCATION (nothing stored). Export SR_CL_* once to
# avoid retyping in a session:
#   export SR_CL_CONN='mysql -h 10.0.0.21 -P 9030 -uroot -psecret'
#   export SR_CL_SSH_USER=ops SR_CL_SSH_PASS=secret SR_CL_SUDO=1
#   bash scripts/diag.sh conn
#   bash scripts/diag.sh sql 'SHOW BACKENDS'
#
# Shared cluster helpers (parse_conn, cl_mysql, cl_node_run, flag handling) live in
# scripts/srcluster.sh so sr-inspect and sr-rollout stay in sync.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srcluster.sh"

usage() {
  cat >&2 <<'EOF'
usage: diag.sh --conn '<mysql connection string>' <command> [args]
   or: diag.sh [cluster flags] <command> [args]

You give a mysql connection string; the skill parses it and connects to the cluster
THROUGH the dev host (every command below runs on the dev host). Example:
  diag.sh --conn 'mysql -h 10.0.0.21 -P 9030 -uroot -psecret' conn
  diag.sh --conn 'mysql -h 10.0.0.21 -uroot' sql 'SHOW BACKENDS'

Cluster source (lowest→highest precedence: SR_CL_* env, --conn string, explicit flags):
  --conn '<str>'       a mysql connection string to parse  (SR_CL_CONN)  ← primary input
  --fe <host>          override FE host (reachable FROM the dev host)     (SR_CL_FE)
  --port <p>           override MySQL query port           (SR_CL_PORT, default 9030)
  --user <u>           override MySQL user                 (SR_CL_USER, default root)
  --password <pw>      override MySQL password (MYSQL_PWD) (SR_CL_PASSWORD)
  --http-port <p>      FE HTTP port (for `profile`)        (SR_CL_HTTP_PORT, default 8030)
  --db <name>          default database                    (SR_CL_DB)
Node-SSH flags (for jstack/pstack/logs/ssh/sys — fixed account + password, +sudo):
  --ssh-user <u>       node ssh user                 (SR_CL_SSH_USER)
  --ssh-pass <pw>      node ssh password (sshpass)   (SR_CL_SSH_PASS)
  --ssh-key <path>     node ssh key (instead of pass)(SR_CL_SSH_KEY)
  --ssh-port <p>       node ssh port                 (SR_CL_SSH_PORT, default 22)
  --sudo               run node commands under sudo  (SR_CL_SUDO=1; assumes NOPASSWD)

Commands:
  conn                 connect via the dev host + reachability + FE/BE health (default)
  sql '<SQL>'          run SQL on the cluster (multiple ';'-separated stmts ok)
  explain '<query>'    EXPLAIN ANALYZE the query (real run — plan + per-operator timing)
  profile <query_id>   dump the query profile for <query_id> via the FE HTTP API
  ssh <node> '<cmd>'   run a shell command on a cluster node (through the dev host)
  jstack <fe-node>     thread dump of the FE (StarRocksFE) JVM on that node
  pstack <be-node>     all-thread C++ backtrace of starrocks_be on that node (use --sudo)
  logs <node> fe|be    tail the FE/BE log on that node (auto-locates via /proc/<pid>/cwd)
  sys <node>           quick system snapshot: uptime / mem / top / iostat

All work runs on the dev host which must reach the cluster. Run sr-connect setup first
if SR_HOST is not configured.
EOF
  exit "${1:-2}"
}

POS=()
while [[ $# -gt 0 ]]; do
  cl_take_flag "$1" "${2:-}"
  if [[ "$CL_TAKEN" == 1 ]]; then shift "$CL_SHIFT"; continue; fi
  case "$1" in
    -h|--help) usage 0 ;;
    --)        shift; POS+=("$@"); break ;;
    -*)        sr_die "unknown option '$1' (see --help)" ;;
    *)         POS+=("$1"); shift ;;
  esac
done
cl_finalize_params

cmd="${POS[0]:-conn}"
POS=("${POS[@]:1}")

case "$cmd" in
  conn)
    cl_need_fe
    pw_disp=""; [[ -n "$PASSWORD" ]] && pw_disp=" -p***"
    echo "── connecting through the dev host $(sr_target) → $FE:$PORT as $USER_$pw_disp${DB:+ db=$DB} ──"
    cl_hostrun "nc -z -w5 '$FE' '$PORT' && echo \"TCP $FE:$PORT reachable from dev host\" || echo \"NOT reachable from dev host — check the cluster host/port and that the dev host has a route to it\""
    echo "── version / nodes ──"
    cl_mysql "SELECT current_version() AS version; SHOW FRONTENDS\\G SHOW BACKENDS\\G" \
      || sr_log "connected to the dev host but could not query the cluster (check the user/password in the connection string and that the FE accepts connections)"
    ;;

  sql)
    [[ ${#POS[@]} -ge 1 ]] || sr_die "usage: diag.sh sql '<SQL>'"
    cl_mysql "${POS[*]}"
    ;;

  explain)
    [[ ${#POS[@]} -ge 1 ]] || sr_die "usage: diag.sh explain '<query>'"
    cl_mysql "EXPLAIN ANALYZE ${POS[*]}"
    ;;

  profile)
    cl_need_fe
    qid="${POS[0]:-}"
    [[ -n "$qid" ]] || sr_die "usage: diag.sh profile <query_id>   (get the id from SHOW PROFILELIST or the query's 'query_id')"
    pre=""
    [[ -n "$PASSWORD" ]] && pre="PW=\"\$(echo $(_b64 "$PASSWORD")|base64 -d)\"; " || pre="PW=''; "
    cl_hostrun "${pre}curl -s --max-time 25 -u '$USER_:'\"\$PW\" \"http://$FE:$HTTP_PORT/query_profile/$qid\""
    echo
    sr_log "if empty, the version may not expose /query_profile — try: diag.sh sql \"ANALYZE PROFILE FROM '$qid'\""
    ;;

  ssh)
    node="${POS[0]:-}"
    [[ -n "$node" && ${#POS[@]} -ge 2 ]] || sr_die "usage: diag.sh ssh <node> '<command>'"
    cl_node_run "$node" "${POS[*]:1}"
    ;;

  jstack)
    node="${POS[0]:-}"; [[ -n "$node" ]] || sr_die "usage: diag.sh jstack <fe-node>"
    cl_node_run "$node" '
pid=$(pgrep -f "com.starrocks.StarRocksFE" | head -1)
[ -n "$pid" ] || { echo "no FE (StarRocksFE) process found on this node" >&2; exit 1; }
owner=$(ps -o user= -p "$pid" | tr -d " ")
echo "== FE pid=$pid owner=$owner =="
sudo -n -u "$owner" jstack -l "$pid" 2>/dev/null \
  || jstack -l "$pid" 2>/dev/null \
  || { echo "jstack could not attach; sending SIGQUIT (dump appears in fe.out)"; kill -3 "$pid"; }
'
    ;;

  pstack)
    node="${POS[0]:-}"; [[ -n "$node" ]] || sr_die "usage: diag.sh pstack <be-node>   (add --sudo; ptrace needs root)"
    cl_node_run "$node" '
pid=$(pgrep -x starrocks_be | head -1)
[ -n "$pid" ] || { echo "no starrocks_be process on this node" >&2; exit 1; }
echo "== BE pid=$pid =="
gdb -p "$pid" -batch -ex "set pagination off" -ex "thread apply all bt" 2>/dev/null \
  || pstack "$pid" 2>/dev/null \
  || { echo "could not attach (need root: re-run with --sudo)"; exit 1; }
'
    ;;

  logs)
    node="${POS[0]:-}"; role="${POS[1]:-}"; lines="${POS[2]:-200}"
    [[ -n "$node" && ( "$role" == fe || "$role" == be ) ]] || sr_die "usage: diag.sh logs <node> fe|be [lines]"
    cl_node_run "$node" '
case "'"$role"'" in
  fe) pid=$(pgrep -f com.starrocks.StarRocksFE|head -1); name=fe.log ;;
  be) pid=$(pgrep -x starrocks_be|head -1);             name=be.INFO ;;
esac
[ -n "$pid" ] || { echo "no '"$role"' process on this node" >&2; exit 1; }
home=$(readlink -f /proc/$pid/cwd)
for d in "$home/log" "$home/../log" "$home"; do
  if [ -f "$d/$name" ]; then echo "== $d/$name (last '"$lines"') =="; tail -n '"$lines"' "$d/$name"; exit 0; fi
done
echo "could not locate $name under $home — pass an explicit path: diag.sh ssh <node> \"tail -n N /path/$name\"" >&2
exit 1
'
    ;;

  sys)
    node="${POS[0]:-}"; [[ -n "$node" ]] || sr_die "usage: diag.sh sys <node>"
    cl_node_run "$node" '
echo "== uptime ==";  uptime
echo "== mem ==";     free -h
echo "== top ==";     top -bn1 | head -25
echo "== iostat ==";  iostat -xz 1 2 2>/dev/null | tail -30 || echo "(iostat not installed)"
'
    ;;

  -h|--help|help) usage 0 ;;
  *) sr_die "unknown command '$cmd' (see --help)" ;;
esac
