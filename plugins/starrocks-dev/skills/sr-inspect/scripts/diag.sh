#!/usr/bin/env bash
# sr-inspect — connect to a LIVE StarRocks cluster THROUGH the dev host and inspect
# it for performance / correctness. The target cluster is reachable from the dev
# host (SR_HOST configured by sr-connect), which acts as the jump/gateway: every
# mysql / curl / ssh below runs ON the dev host via the existing SSH ControlMaster.
#
# Cluster connection params are passed PER-INVOCATION (nothing is stored on disk).
# For convenience in a session you may `export SR_CL_*` once instead of re-flagging:
#
#   export SR_CL_FE=10.0.0.21 SR_CL_PORT=9030 SR_CL_USER=root SR_CL_PASSWORD=...
#   export SR_CL_SSH_USER=ops SR_CL_SSH_PASS=... SR_CL_SUDO=1
#   bash scripts/diag.sh conn
#   bash scripts/diag.sh sql 'SHOW BACKENDS'
#   bash scripts/diag.sh jstack 10.0.0.10
#
# These env vars live only in your shell — they are never written to a config file.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

usage() {
  cat >&2 <<'EOF'
usage: diag.sh --conn '<mysql connection string>' <command> [args]
   or: diag.sh [cluster flags] <command> [args]

You give a mysql connection string; the skill parses it and connects to the cluster
THROUGH the dev host (every command below runs on the dev host). Example:
  diag.sh --conn 'mysql -h 10.0.0.21 -P 9030 -uroot -psecret' conn
  diag.sh --conn 'mysql -h 10.0.0.21 -uroot' sql 'SHOW BACKENDS'

Cluster source (lowest→highest precedence: SR_CL_* env, --conn string, explicit flags):
  --conn '<str>'       a mysql connection string to parse  (SR_CL_CONN)
  --fe <host>          FE host as reachable FROM the dev host        (SR_CL_FE)
  --port <p>           FE MySQL query port           (SR_CL_PORT, default 9030)
  --user <u>           MySQL user                    (SR_CL_USER, default root)
  --password <pw>      MySQL password                (SR_CL_PASSWORD; sent via MYSQL_PWD)
  --http-port <p>      FE HTTP port                  (SR_CL_HTTP_PORT, default 8030)
  --db <name>          default database              (SR_CL_DB)
Node-SSH flags (for jstack/pstack/logs/ssh/sys — fixed account + password, +sudo):
  --ssh-user <u>       node ssh user                 (SR_CL_SSH_USER)
  --ssh-pass <pw>      node ssh password (sshpass)   (SR_CL_SSH_PASS)
  --ssh-key <path>     node ssh key (instead of pass)(SR_CL_SSH_KEY)
  --ssh-port <p>       node ssh port                 (SR_CL_SSH_PORT, default 22)
  --sudo               run node commands under sudo  (SR_CL_SUDO=1; assumes NOPASSWD)

Commands:
  conn                 print ready-to-paste connection strings + reachability + FE/BE list
  sql '<SQL>'          run SQL on the cluster (multiple ';'-separated stmts ok)
  explain '<query>'    EXPLAIN ANALYZE the query (real run — plan + per-operator timing)
  profile <query_id>   dump the query profile for <query_id> via the FE HTTP API
  ssh <node> '<cmd>'   run a shell command on a cluster node (through the dev host)
  jstack <fe-node>     thread dump of the FE (StarRocksFE) JVM on that node
  pstack <be-node>     all-thread C++ backtrace of starrocks_be on that node (use --sudo)
  logs <node> fe|be    tail the FE/BE log on that node (auto-locates via /proc/<pid>/cwd)
  sys <node>           quick system snapshot: uptime / mem / top / iostat

All work runs on the dev host ($(sr_target 2>/dev/null || echo '<SR_HOST>')) which must
reach the cluster. Run sr-connect setup first if SR_HOST is not configured.
EOF
  exit "${1:-2}"
}

# ---- params ----
# The PRIMARY input is a mysql connection string (--conn / SR_CL_CONN), which the
# skill parses and uses to reach the cluster THROUGH the dev host. Individual
# --fe/--port/--user/... flags are an alternative and always override the parsed
# string; SR_CL_* env vars are the lowest-precedence fallback.
FE="${SR_CL_FE:-}"; PORT="${SR_CL_PORT:-9030}"; USER_="${SR_CL_USER:-root}"
PASSWORD="${SR_CL_PASSWORD:-}"; HTTP_PORT="${SR_CL_HTTP_PORT:-8030}"; DB="${SR_CL_DB:-}"
CONN="${SR_CL_CONN:-}"
SSH_USER="${SR_CL_SSH_USER:-}"; SSH_PASS="${SR_CL_SSH_PASS:-}"; SSH_KEY="${SR_CL_SSH_KEY:-}"
SSH_PORT="${SR_CL_SSH_PORT:-22}"; SUDO="${SR_CL_SUDO:-}"

# Explicit-flag holders (empty/0 = not given) so flags can override the parsed string
# regardless of argument order.
F_FE=""; F_PORT=""; F_USER=""; F_PW=""; PW_SET=0; F_HTTP=""; F_DB=""

# parse_conn "<mysql cmdline>" — extract -h/-P/-u/-p/-D (and the long forms, plus a
# bare trailing db name) from a mysql connection string into FE/PORT/USER/PASSWORD/DB.
# Only fields present in the string are set. Tokens are whitespace-split; if a value
# contains spaces, pass it with --password/--db instead.
parse_conn() {
  local -a toks; read -ra toks <<< "$1"
  local i=0 n=${#toks[@]} t
  while (( i < n )); do
    t="${toks[i]}"
    case "$t" in
      mysql|mysqlsh|mariadb) ;;
      -h)            FE="${toks[++i]:-}" ;;
      -h*)           FE="${t#-h}" ;;
      --host)        FE="${toks[++i]:-}" ;;
      --host=*)      FE="${t#--host=}" ;;
      -P)            PORT="${toks[++i]:-}" ;;
      -P*)           PORT="${t#-P}" ;;
      --port)        PORT="${toks[++i]:-}" ;;
      --port=*)      PORT="${t#--port=}" ;;
      -u)            USER_="${toks[++i]:-}" ;;
      -u*)           USER_="${t#-u}" ;;
      --user)        USER_="${toks[++i]:-}" ;;
      --user=*)      USER_="${t#--user=}" ;;
      -p*)           PASSWORD="${t#-p}" ;;            # attached form -psecret (preferred)
      --password)    PASSWORD="${toks[++i]:-}" ;;
      --password=*)  PASSWORD="${t#--password=}" ;;
      -D)            DB="${toks[++i]:-}" ;;
      -D*)           DB="${t#-D}" ;;
      --database)    DB="${toks[++i]:-}" ;;
      --database=*)  DB="${t#--database=}" ;;
      -*)            ;;                                # ignore other mysql flags (-A, --table, ...)
      *)             [[ -z "$DB" ]] && DB="$t" ;;      # bare trailing db name
    esac
    ((i++))
  done
}

POS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --conn)      CONN="$2"; shift 2 ;;
    --fe)        F_FE="$2"; shift 2 ;;
    --port)      F_PORT="$2"; shift 2 ;;
    --user)      F_USER="$2"; shift 2 ;;
    --password)  F_PW="$2"; PW_SET=1; shift 2 ;;
    --http-port) F_HTTP="$2"; shift 2 ;;
    --db)        F_DB="$2"; shift 2 ;;
    --ssh-user)  SSH_USER="$2"; shift 2 ;;
    --ssh-pass)  SSH_PASS="$2"; shift 2 ;;
    --ssh-key)   SSH_KEY="$2"; shift 2 ;;
    --ssh-port)  SSH_PORT="$2"; shift 2 ;;
    --sudo)      SUDO=1; shift ;;
    -h|--help)   usage 0 ;;
    --)          shift; POS+=("$@"); break ;;
    -*)          sr_die "unknown option '$1' (see --help)" ;;
    *)           POS+=("$1"); shift ;;
  esac
done

# Precedence: parsed connection string overrides the SR_CL_* env base, then explicit
# individual flags override the string.
[[ -n "$CONN" ]] && parse_conn "$CONN"
[[ -n "$F_FE" ]]   && FE="$F_FE"
[[ -n "$F_PORT" ]] && PORT="$F_PORT"
[[ -n "$F_USER" ]] && USER_="$F_USER"
[[ "$PW_SET" == 1 ]] && PASSWORD="$F_PW"
[[ -n "$F_HTTP" ]] && HTTP_PORT="$F_HTTP"
[[ -n "$F_DB" ]]   && DB="$F_DB"

cmd="${POS[0]:-conn}"
POS=("${POS[@]:1}")

_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# hostrun "<cmd>" — execute an arbitrary command string ON the dev host. Shipped
# base64-encoded so any quoting / $() / pipes inside survive untouched.
hostrun() { rsh "echo $(_b64 "$1") | base64 -d | bash"; }

need_fe() {
  [[ -n "$FE" ]] || sr_die "no cluster host — pass a connection string: --conn 'mysql -h <host> -P <port> -u <user> -p<pw>' (or SR_CL_CONN / --fe). The host must be reachable FROM the dev host $(sr_target)."
}

# mysql_run "<SQL>" — run SQL on the cluster from the dev host. Password is passed
# via MYSQL_PWD (kept off the process command line) and base64-wrapped so any
# character is safe.
mysql_run() {
  need_fe
  local pre=""
  [[ -n "$PASSWORD" ]] && pre="export MYSQL_PWD=\"\$(echo $(_b64 "$PASSWORD")|base64 -d)\"; "
  local opts="-h'$FE' -P'$PORT' -u'$USER_' -A --table --connect-timeout=10"
  [[ -n "$DB" ]] && opts="$opts '$DB'"
  hostrun "${pre}echo $(_b64 "$1") | base64 -d | mysql $opts"
}

# node_run "<node>" "<cmd>" — run a shell command on a cluster node, hopping through
# the dev host. Uses sshpass (password) or a key; optionally wraps in sudo.
node_run() {
  local node="$1" inner="$2"
  [[ -n "$node" ]]     || sr_die "node host required"
  [[ -n "$SSH_USER" ]] || sr_die "--ssh-user (or SR_CL_SSH_USER) required for node access"
  local runner="bash"; [[ -n "$SUDO" ]] && runner="sudo -n bash"
  # Command to run on the NODE (base64-wrapped; pipes/quotes preserved).
  local nodecmd="echo $(_b64 "$inner") | base64 -d | $runner"
  local sopt="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p $SSH_PORT"
  local conn
  if [[ -n "$SSH_KEY" ]]; then
    conn="ssh $sopt -i '$SSH_KEY' '$SSH_USER@$node' \"$nodecmd\""
  elif [[ -n "$SSH_PASS" ]]; then
    conn="export SSHPASS=\"\$(echo $(_b64 "$SSH_PASS")|base64 -d)\"; sshpass -e ssh $sopt '$SSH_USER@$node' \"$nodecmd\""
  else
    sr_die "node access needs --ssh-pass or --ssh-key (or SR_CL_SSH_PASS / SR_CL_SSH_KEY)"
  fi
  hostrun "$conn"
}

case "$cmd" in
  conn)
    need_fe
    pw_disp=""; [[ -n "$PASSWORD" ]] && pw_disp=" -p***"
    echo "── connecting through the dev host $(sr_target) → $FE:$PORT as $USER_$pw_disp${DB:+ db=$DB} ──"
    hostrun "nc -z -w5 '$FE' '$PORT' && echo \"TCP $FE:$PORT reachable from dev host\" || echo \"NOT reachable from dev host — check the cluster host/port and that the dev host has a route to it\""
    echo "── version / nodes ──"
    mysql_run "SELECT current_version() AS version; SHOW FRONTENDS\\G SHOW BACKENDS\\G" \
      || sr_log "connected to the dev host but could not query the cluster (check the user/password in the connection string and that the FE accepts connections)"
    ;;

  sql)
    [[ ${#POS[@]} -ge 1 ]] || sr_die "usage: diag.sh sql '<SQL>'"
    mysql_run "${POS[*]}"
    ;;

  explain)
    [[ ${#POS[@]} -ge 1 ]] || sr_die "usage: diag.sh explain '<query>'"
    mysql_run "EXPLAIN ANALYZE ${POS[*]}"
    ;;

  profile)
    need_fe
    qid="${POS[0]:-}"
    [[ -n "$qid" ]] || sr_die "usage: diag.sh profile <query_id>   (get the id from SHOW PROFILELIST or the query's 'query_id')"
    pre=""
    [[ -n "$PASSWORD" ]] && pre="PW=\"\$(echo $(_b64 "$PASSWORD")|base64 -d)\"; " || pre="PW=''; "
    hostrun "${pre}curl -s --max-time 25 -u '$USER_:'\"\$PW\" \"http://$FE:$HTTP_PORT/query_profile/$qid\""
    echo
    sr_log "if empty, the version may not expose /query_profile — try: diag.sh sql \"ANALYZE PROFILE FROM '$qid'\""
    ;;

  ssh)
    node="${POS[0]:-}"
    [[ -n "$node" && ${#POS[@]} -ge 2 ]] || sr_die "usage: diag.sh ssh <node> '<command>'"
    node_run "$node" "${POS[*]:1}"
    ;;

  jstack)
    node="${POS[0]:-}"; [[ -n "$node" ]] || sr_die "usage: diag.sh jstack <fe-node>"
    node_run "$node" '
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
    node_run "$node" '
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
    node_run "$node" '
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
    node_run "$node" '
echo "== uptime ==";  uptime
echo "== mem ==";     free -h
echo "== top ==";     top -bn1 | head -25
echo "== iostat ==";  iostat -xz 1 2 2>/dev/null | tail -30 || echo "(iostat not installed)"
'
    ;;

  -h|--help|help) usage 0 ;;
  *) sr_die "unknown command '$cmd' (see --help)" ;;
esac
