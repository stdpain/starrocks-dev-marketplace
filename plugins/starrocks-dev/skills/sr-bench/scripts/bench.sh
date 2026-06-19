#!/usr/bin/env bash
# sr-bench — a named registry of BENCHMARK / test clusters, plus connect & wake.
#
# Why a registry: benchmark clusters are long-lived things you hit repeatedly, reached
# THROUGH a jump host (a dedicated jumpserver, or the sr-connect dev host), usually with
# a SHARED account+password that you keep in env vars (never on disk). And they tend to
# get SUSPENDED, so their FE/BE need to be ssh'd into and started back up. This skill
# stores the topology (hosts/ports/jump/node inventory) under ~/.config/starrocks_dev/
# and reads the credentials from env vars at run time. It builds on scripts/srcluster.sh,
# so once a cluster is loaded it behaves exactly like sr-inspect (cl_mysql / cl_node_run),
# only the jump and creds come from the named entry instead of a --conn string.
#
#   export SR_BENCH_USER=root SR_BENCH_PASS=...           # the shared account+password
#   bash bench.sh add tpch --fe 10.0.0.21 --jump bastion01 \
#        --fe-nodes 10.0.0.21=/data/StarRocks/fe \
#        --be-nodes '10.0.0.22,10.0.0.23' --be-home /data/StarRocks/be
#   bash bench.sh ls
#   bash bench.sh tpch            # = conn: reachability + version + FE/BE health
#   bash bench.sh wake tpch       # ssh to each node, start any FE/BE that is down
#   bash bench.sh sql tpch 'SHOW BACKENDS'
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srcluster.sh"

BENCH_DIR="$SR_CFG_BASE/bench"
mkdir -p "$BENCH_DIR"; chmod 700 "$BENCH_DIR" 2>/dev/null || true

usage() {
  cat >&2 <<'EOF'
usage: bench.sh <command> [name] [args]

Registry (topology + credential VAR NAMES only — no secrets are stored):
  add  <name> [flags]   register a benchmark cluster (errors if it exists)
  set  <name> [flags]   update fields of an existing cluster (same flags as add)
  ls                    list registered clusters
  show <name>           print a cluster's stored fields + whether its cred vars are set
  rm   <name>           remove a cluster

Connect / operate (creds resolved from env at run time):
  conn   <name>         reachability + current_version() + SHOW FRONTENDS/BACKENDS (default)
  status <name>         conn, plus a per-node FE/BE process check (up / DOWN)
  wake   <name> [fe|be|all]   ssh to each node and start any FE/BE that is down (FEs first)
  sql    <name> '<SQL>'       run SQL on the cluster
  ssh    <name> <node> '<cmd>'  run a shell command on a node (through the jump)
  env    <name>         print export lines (SR_CL_*) to drive sr-inspect / sr-rollout

`bench.sh <name>` with no command is shorthand for `conn <name>`.

add/set flags:
  --fe <host>           FE host for the MySQL protocol (reachable FROM the jump)   [required]
  --port <p>            FE query port            (default 9030)
  --http-port <p>       FE http port             (default 8030)
  --db <name>           default database
  --jump <user@host[:port]>  dedicated jump/bastion. Omit to use the sr-connect dev host.
  --jump-key <path>     ssh key for the jump (else the shared password is used via sshpass)
  --user-var <VAR>      env var holding the shared login user   (default SR_BENCH_USER)
  --pass-var <VAR>      env var holding the shared password     (default SR_BENCH_PASS)
  --mysql-user <u>      MySQL user override (else the shared user, else root)
  --ssh-user <u>        node ssh user override (else the shared user)
  --ssh-port <p>        node ssh port            (default 22)
  --sudo / --no-sudo    run node ops under sudo (process check / log peek; NOT the start)
  --fe-nodes <list>     FE nodes for `wake`: comma/space list of host or host=/sr/home
  --be-nodes <list>     BE nodes for `wake`: comma/space list of host or host=/sr/home
  --fe-home <path>      default StarRocks home for FE nodes that omit '=home'
  --be-home <path>      default StarRocks home for BE nodes that omit '=home'

Credentials live ONLY in the environment (export the user-var/pass-var). The registry
files store the variable NAMES and topology, chmod 600. The jump is reached like the
dev host (key/agent, or the shared password via sshpass); the cluster MySQL and node
ssh use the shared account+password.
EOF
  exit "${1:-2}"
}

bench_file() { printf '%s/%s.env' "$BENCH_DIR" "$1"; }
bench_exists() { [[ -f "$(bench_file "$1")" ]]; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || sr_die "invalid cluster name '$1' (use letters, digits, . _ -)"; }

# --- add / set: parse flags into B_* then merge-write the entry file --------------
B_FE="" B_PORT="" B_HTTP="" B_DB="" B_JUMP="" B_JUMP_KEY="" B_USER_VAR="" B_PASS_VAR=""
B_MYSQL_USER="" B_SSH_USER="" B_SSH_PORT="" B_SUDO="" B_SUDO_SET=0
B_FE_NODES="" B_BE_NODES="" B_FE_HOME="" B_BE_HOME=""

parse_set_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fe)         B_FE="$2"; shift 2 ;;
      --port)       B_PORT="$2"; shift 2 ;;
      --http-port)  B_HTTP="$2"; shift 2 ;;
      --db)         B_DB="$2"; shift 2 ;;
      --jump)       B_JUMP="$2"; shift 2 ;;
      --jump-key)   B_JUMP_KEY="$2"; shift 2 ;;
      --user-var)   B_USER_VAR="$2"; shift 2 ;;
      --pass-var)   B_PASS_VAR="$2"; shift 2 ;;
      --mysql-user) B_MYSQL_USER="$2"; shift 2 ;;
      --ssh-user)   B_SSH_USER="$2"; shift 2 ;;
      --ssh-port)   B_SSH_PORT="$2"; shift 2 ;;
      --sudo)       B_SUDO=1; B_SUDO_SET=1; shift ;;
      --no-sudo)    B_SUDO=""; B_SUDO_SET=1; shift ;;
      --fe-nodes)   B_FE_NODES="$2"; shift 2 ;;
      --be-nodes)   B_BE_NODES="$2"; shift 2 ;;
      --fe-home)    B_FE_HOME="$2"; shift 2 ;;
      --be-home)    B_BE_HOME="$2"; shift 2 ;;
      -h|--help)    usage 0 ;;
      *)            sr_die "unknown flag '$1' for add/set (see --help)" ;;
    esac
  done
}

# write_entry <name> — merge B_* over whatever is already in the file, write it back.
write_entry() {
  local name="$1" f; f="$(bench_file "$name")"
  # load existing values (if any) so `set` only changes the fields you pass
  local cur_FE="" cur_PORT="9030" cur_HTTP="8030" cur_DB="" cur_JUMP="" cur_JUMP_KEY=""
  local cur_USER_VAR="SR_BENCH_USER" cur_PASS_VAR="SR_BENCH_PASS" cur_MYSQL_USER="" cur_SSH_USER=""
  local cur_SSH_PORT="22" cur_SUDO="" cur_FE_NODES="" cur_BE_NODES="" cur_FE_HOME="" cur_BE_HOME=""
  if [[ -f "$f" ]]; then
    # shellcheck disable=SC1090
    source "$f"
    cur_FE="${BENCH_FE:-}"; cur_PORT="${BENCH_PORT:-9030}"; cur_HTTP="${BENCH_HTTP_PORT:-8030}"
    cur_DB="${BENCH_DB:-}"; cur_JUMP="${BENCH_JUMP:-}"; cur_JUMP_KEY="${BENCH_JUMP_KEY:-}"
    cur_USER_VAR="${BENCH_USER_VAR:-SR_BENCH_USER}"; cur_PASS_VAR="${BENCH_PASS_VAR:-SR_BENCH_PASS}"
    cur_MYSQL_USER="${BENCH_MYSQL_USER:-}"; cur_SSH_USER="${BENCH_SSH_USER:-}"; cur_SSH_PORT="${BENCH_SSH_PORT:-22}"
    cur_SUDO="${BENCH_SUDO:-}"; cur_FE_NODES="${BENCH_FE_NODES:-}"; cur_BE_NODES="${BENCH_BE_NODES:-}"
    cur_FE_HOME="${BENCH_FE_HOME:-}"; cur_BE_HOME="${BENCH_BE_HOME:-}"
  fi
  # apply overrides
  [[ -n "$B_FE" ]]         && cur_FE="$B_FE"
  [[ -n "$B_PORT" ]]       && cur_PORT="$B_PORT"
  [[ -n "$B_HTTP" ]]       && cur_HTTP="$B_HTTP"
  [[ -n "$B_DB" ]]         && cur_DB="$B_DB"
  [[ -n "$B_JUMP" ]]       && cur_JUMP="$B_JUMP"
  [[ -n "$B_JUMP_KEY" ]]   && cur_JUMP_KEY="$B_JUMP_KEY"
  [[ -n "$B_USER_VAR" ]]   && cur_USER_VAR="$B_USER_VAR"
  [[ -n "$B_PASS_VAR" ]]   && cur_PASS_VAR="$B_PASS_VAR"
  [[ -n "$B_MYSQL_USER" ]] && cur_MYSQL_USER="$B_MYSQL_USER"
  [[ -n "$B_SSH_USER" ]]   && cur_SSH_USER="$B_SSH_USER"
  [[ -n "$B_SSH_PORT" ]]   && cur_SSH_PORT="$B_SSH_PORT"
  [[ "$B_SUDO_SET" == 1 ]] && cur_SUDO="$B_SUDO"
  [[ -n "$B_FE_NODES" ]]   && cur_FE_NODES="$B_FE_NODES"
  [[ -n "$B_BE_NODES" ]]   && cur_BE_NODES="$B_BE_NODES"
  [[ -n "$B_FE_HOME" ]]    && cur_FE_HOME="$B_FE_HOME"
  [[ -n "$B_BE_HOME" ]]    && cur_BE_HOME="$B_BE_HOME"
  [[ -n "$cur_FE" ]] || sr_die "a benchmark cluster needs an FE host — pass --fe <host>"
  ( umask 077
    local tmp="$f.tmp.$$"
    {
      echo "# sr-bench cluster '$name' — written by bench.sh (NO secrets; creds come from env vars)"
      printf "BENCH_NAME='%s'\n"       "$name"
      printf "BENCH_FE='%s'\n"         "$cur_FE"
      printf "BENCH_PORT='%s'\n"       "$cur_PORT"
      printf "BENCH_HTTP_PORT='%s'\n"  "$cur_HTTP"
      [[ -n "$cur_DB" ]]        && printf "BENCH_DB='%s'\n"         "$cur_DB"
      [[ -n "$cur_JUMP" ]]      && printf "BENCH_JUMP='%s'\n"       "$cur_JUMP"
      [[ -n "$cur_JUMP_KEY" ]]  && printf "BENCH_JUMP_KEY='%s'\n"   "$cur_JUMP_KEY"
      printf "BENCH_USER_VAR='%s'\n"   "$cur_USER_VAR"
      printf "BENCH_PASS_VAR='%s'\n"   "$cur_PASS_VAR"
      [[ -n "$cur_MYSQL_USER" ]] && printf "BENCH_MYSQL_USER='%s'\n" "$cur_MYSQL_USER"
      [[ -n "$cur_SSH_USER" ]]  && printf "BENCH_SSH_USER='%s'\n"   "$cur_SSH_USER"
      printf "BENCH_SSH_PORT='%s'\n"   "$cur_SSH_PORT"
      [[ -n "$cur_SUDO" ]]      && printf "BENCH_SUDO='%s'\n"       "$cur_SUDO"
      [[ -n "$cur_FE_NODES" ]]  && printf "BENCH_FE_NODES='%s'\n"   "$cur_FE_NODES"
      [[ -n "$cur_BE_NODES" ]]  && printf "BENCH_BE_NODES='%s'\n"   "$cur_BE_NODES"
      [[ -n "$cur_FE_HOME" ]]   && printf "BENCH_FE_HOME='%s'\n"    "$cur_FE_HOME"
      [[ -n "$cur_BE_HOME" ]]   && printf "BENCH_BE_HOME='%s'\n"    "$cur_BE_HOME"
    } > "$tmp"
    mv "$tmp" "$f"; chmod 600 "$f"
  )
}

# load_cluster <name> — source the entry, resolve creds from env, populate the srcluster.sh
# globals (FE PORT USER_ PASSWORD ... SSH_* CL_JUMP*). Exits if the cluster is unknown.
RESOLVED_USER="" RESOLVED_PASS=""
load_cluster() {
  local name="$1" f; f="$(bench_file "$name")"
  [[ -f "$f" ]] || sr_die "no benchmark cluster '$name'. List with: bench.sh ls   Add with: bench.sh add $name --fe <host> ..."
  # entry defaults, then file
  BENCH_PORT=9030 BENCH_HTTP_PORT=8030 BENCH_USER_VAR=SR_BENCH_USER BENCH_PASS_VAR=SR_BENCH_PASS BENCH_SSH_PORT=22
  BENCH_DB="" BENCH_JUMP="" BENCH_JUMP_KEY="" BENCH_MYSQL_USER="" BENCH_SSH_USER="" BENCH_SUDO=""
  BENCH_FE_NODES="" BENCH_BE_NODES="" BENCH_FE_HOME="" BENCH_BE_HOME="" BENCH_FE=""
  # shellcheck disable=SC1090
  source "$f"
  local shared_user="${!BENCH_USER_VAR:-}"
  RESOLVED_PASS="${!BENCH_PASS_VAR:-}"
  RESOLVED_USER="${BENCH_MYSQL_USER:-${shared_user:-root}}"
  [[ -n "$RESOLVED_PASS" ]] || sr_log "note: env var \$$BENCH_PASS_VAR is empty — export the shared benchmark password before connecting (export $BENCH_PASS_VAR=...)."
  # populate srcluster.sh globals
  FE="$BENCH_FE"; PORT="$BENCH_PORT"; HTTP_PORT="$BENCH_HTTP_PORT"; DB="$BENCH_DB"
  USER_="$RESOLVED_USER"; PASSWORD="$RESOLVED_PASS"
  SSH_USER="${BENCH_SSH_USER:-$shared_user}"; SSH_PASS="$RESOLVED_PASS"; SSH_KEY=""; SSH_PORT="$BENCH_SSH_PORT"
  SUDO="$BENCH_SUDO"
  CL_JUMP="$BENCH_JUMP"; CL_JUMP_KEY="$BENCH_JUMP_KEY"
  # jump auth: a key if given, else the shared password (via sshpass). When no jump is
  # set, CL_JUMP is empty and srcluster.sh falls back to the sr-connect dev host (rsh).
  if [[ -n "$CL_JUMP" && -z "$CL_JUMP_KEY" ]]; then CL_JUMP_PASS="$RESOLVED_PASS"; else CL_JUMP_PASS=""; fi
}

# nodes_of <fe|be> — emit "host<TAB>home" lines from BENCH_{FE,BE}_NODES (after load_cluster).
nodes_of() {
  local which="$1" list def
  if [[ "$which" == fe ]]; then list="$BENCH_FE_NODES"; def="$BENCH_FE_HOME"
  else list="$BENCH_BE_NODES"; def="$BENCH_BE_HOME"; fi
  local tok host home
  for tok in ${list//,/ }; do
    if [[ "$tok" == *=* ]]; then host="${tok%%=*}"; home="${tok#*=}"
    else host="$tok"; home="$def"; fi
    printf '%s\t%s\n' "$host" "$home"
  done
}

cmd="${1:-}"; [[ -n "$cmd" ]] || usage 0
case "$cmd" in
  add|set|ls|list|show|rm|remove|conn|status|wake|sql|ssh|env|-h|--help|help) shift ;;
  *) cmd="conn" ;;   # `bench.sh <name>` == `bench.sh conn <name>`
esac

case "$cmd" in
  -h|--help|help) usage 0 ;;

  add)
    name="${1:-}"; [[ -n "$name" ]] || sr_die "usage: bench.sh add <name> --fe <host> [flags]"
    valid_name "$name"; shift
    bench_exists "$name" && sr_die "cluster '$name' already exists — use 'set' to modify it, or 'rm' first."
    parse_set_flags "$@"; write_entry "$name"
    sr_log "registered benchmark cluster '$name' -> $(bench_file "$name")"
    ;;

  set)
    name="${1:-}"; [[ -n "$name" ]] || sr_die "usage: bench.sh set <name> [flags]"
    valid_name "$name"; shift
    bench_exists "$name" || sr_die "no cluster '$name' to set — add it first: bench.sh add $name --fe <host> ..."
    parse_set_flags "$@"; write_entry "$name"
    sr_log "updated benchmark cluster '$name'"
    ;;

  ls|list)
    shopt -s nullglob
    files=("$BENCH_DIR"/*.env)
    [[ ${#files[@]} -gt 0 ]] || { sr_log "no benchmark clusters registered yet. Add one: bench.sh add <name> --fe <host> ..."; exit 0; }
    printf '%-16s %-22s %-22s %s\n' NAME FE JUMP NODES
    for f in "${files[@]}"; do
      ( BENCH_FE="" BENCH_JUMP="" BENCH_FE_NODES="" BENCH_BE_NODES="" BENCH_NAME=""
        # shellcheck disable=SC1090
        source "$f"
        nfe=$(echo "${BENCH_FE_NODES//,/ }" | wc -w); nbe=$(echo "${BENCH_BE_NODES//,/ }" | wc -w)
        printf '%-16s %-22s %-22s %s\n' "${BENCH_NAME:-?}" "${BENCH_FE:-?}" "${BENCH_JUMP:-(dev host)}" "${nfe}FE/${nbe}BE" )
    done
    ;;

  show)
    name="${1:-}"; [[ -n "$name" ]] || sr_die "usage: bench.sh show <name>"
    bench_exists "$name" || sr_die "no cluster '$name'"
    echo "── $(bench_file "$name") ──"
    cat "$(bench_file "$name")"
    # report whether the cred vars are currently set (value masked)
    ( BENCH_USER_VAR=SR_BENCH_USER BENCH_PASS_VAR=SR_BENCH_PASS
      # shellcheck disable=SC1090
      source "$(bench_file "$name")"
      uv="$BENCH_USER_VAR"; pv="$BENCH_PASS_VAR"
      echo "── credentials (from env) ──"
      printf '  user  $%s = %s\n' "$uv" "$([[ -n "${!uv:-}" ]] && echo "${!uv}" || echo '(unset)')"
      printf '  pass  $%s = %s\n' "$pv" "$([[ -n "${!pv:-}" ]] && echo '***set***' || echo '(unset — export it before connecting)')" )
    ;;

  rm|remove)
    name="${1:-}"; [[ -n "$name" ]] || sr_die "usage: bench.sh rm <name>"
    bench_exists "$name" || sr_die "no cluster '$name'"
    rm -f "$(bench_file "$name")"; sr_log "removed benchmark cluster '$name'"
    ;;

  conn)
    name="${1:-}"; [[ -n "$name" ]] || sr_die "usage: bench.sh conn <name>   (or just: bench.sh <name>)"
    load_cluster "$name"; cl_need_fe
    pw_disp=""; [[ -n "$PASSWORD" ]] && pw_disp=" -p***"
    echo "── $name: connecting via $(cl_jump_desc) → $FE:$PORT as $USER_$pw_disp${DB:+ db=$DB} ──"
    cl_hostrun "command -v nc >/dev/null 2>&1 && (nc -z -w5 '$FE' '$PORT' && echo \"TCP $FE:$PORT reachable\" || echo \"NOT reachable from $(cl_jump_desc) — cluster may be SUSPENDED (try: bench.sh wake $name) or the host/port is wrong\") || echo '(nc not on the jump; skipping reachability probe)'"
    echo "── version / nodes ──"
    cl_mysql "SELECT current_version() AS version; SHOW FRONTENDS\\G SHOW BACKENDS\\G" \
      || sr_log "reached the jump but could not query the FE — it may be down (bench.sh wake $name) or the user/password is wrong."
    ;;

  status)
    name="${1:-}"; [[ -n "$name" ]] || sr_die "usage: bench.sh status <name>"
    load_cluster "$name"; cl_need_fe
    echo "── $name: FE $FE:$PORT via $(cl_jump_desc) ──"
    cl_mysql "SHOW FRONTENDS\\G SHOW BACKENDS\\G" || sr_log "FE not answering — process check below tells you which nodes are down."
    echo "── node process check ──"
    while IFS=$'\t' read -r host home; do
      [[ -n "$host" ]] || continue
      echo "FE $host${home:+ ($home)}:"
      cl_node_run "$host" 'p=$(pgrep -f com.starrocks.StarRocksFE|head -1); [ -n "$p" ] && echo "  up (pid $p)" || echo "  DOWN"' 2>&1 | sed 's/^/  /'
    done < <(nodes_of fe)
    while IFS=$'\t' read -r host home; do
      [[ -n "$host" ]] || continue
      echo "BE $host${home:+ ($home)}:"
      cl_node_run "$host" 'p=$(pgrep -x starrocks_be|head -1); [ -n "$p" ] && echo "  up (pid $p)" || echo "  DOWN"' 2>&1 | sed 's/^/  /'
    done < <(nodes_of be)
    ;;

  wake)
    name="${1:-}"; [[ -n "$name" ]] || sr_die "usage: bench.sh wake <name> [fe|be|all]"
    which="${2:-all}"
    load_cluster "$name"
    [[ -n "$BENCH_FE_NODES$BENCH_BE_NODES" ]] \
      || sr_die "cluster '$name' has no node inventory — wake needs it (FE may be down, so SHOW BACKENDS can't help). Add it: bench.sh set $name --fe-nodes <hosts> --be-nodes <hosts> --fe-home <path> --be-home <path>"
    # Start as the SSH login user (the service user), NEVER under sudo — a root-started
    # FE/BE leaves root-owned pid files that brick the next normal restart (see sr-rollout).
    SUDO=""
    wake_one() {  # <role> <host> <home>
      local role="$1" host="$2" home="$3" proc pgf bin
      if [[ "$role" == fe ]]; then proc='com.starrocks.StarRocksFE'; pgf="-f '$proc'"; bin='bin/start_fe.sh'
      else proc='starrocks_be'; pgf="-x '$proc'"; bin='bin/start_be.sh'; fi
      [[ -n "$home" ]] || { echo "  $role $host: no home configured (set --${role}-home or host=/path) — skipping"; return; }
      local script
      script=$(cat <<REMOTE
home='$home'
if pgrep $pgf >/dev/null 2>&1; then echo "$role $host: already up"; exit 0; fi
[ -d "\$home" ] || { echo "$role $host: home \$home not found" >&2; exit 1; }
cd "\$home" || exit 1
[ -x '$bin' ] || { echo "$role $host: no $bin under \$home" >&2; exit 1; }
echo "$role $host: starting ..."
'$bin' --daemon >/dev/null 2>&1
sleep 3
if pgrep $pgf >/dev/null 2>&1; then echo "$role $host: started"
else echo "$role $host: FAILED to start — check \$home/log/${role}.* on the node" >&2; exit 1; fi
REMOTE
)
      cl_node_run "$host" "$script" 2>&1 | sed 's/^/  /'
    }
    if [[ "$which" == fe || "$which" == all ]]; then
      echo "── waking FE nodes ──"
      while IFS=$'\t' read -r host home; do [[ -n "$host" ]] && wake_one fe "$host" "$home"; done < <(nodes_of fe)
    fi
    if [[ "$which" == be || "$which" == all ]]; then
      echo "── waking BE nodes ──"
      while IFS=$'\t' read -r host home; do [[ -n "$host" ]] && wake_one be "$host" "$home"; done < <(nodes_of be)
    fi
    sr_log "done. Verify with: bash bench.sh conn $name"
    ;;

  sql)
    name="${1:-}"; [[ -n "$name" && $# -ge 2 ]] || sr_die "usage: bench.sh sql <name> '<SQL>'"
    load_cluster "$name"; shift
    cl_mysql "$*"
    ;;

  ssh)
    name="${1:-}"; node="${2:-}"
    [[ -n "$name" && -n "$node" && $# -ge 3 ]] || sr_die "usage: bench.sh ssh <name> <node> '<command>'"
    load_cluster "$name"; shift 2
    cl_node_run "$node" "$*"
    ;;

  env)
    name="${1:-}"; [[ -n "$name" ]] || sr_die "usage: bench.sh env <name>"
    load_cluster "$name"
    # Emit export lines that REFERENCE the env vars (so no secret is printed), ready to
    # eval before running sr-inspect / sr-rollout against this cluster.
    echo "# eval these to point sr-inspect / sr-rollout at '$name' (no secrets are printed):"
    echo "export SR_CL_CONN='mysql -h $FE -P $PORT -u$USER_'"
    echo "export SR_CL_PASSWORD=\"\$$BENCH_PASS_VAR\""
    echo "export SR_CL_HTTP_PORT='$HTTP_PORT'${DB:+; export SR_CL_DB='$DB'}"
    echo "export SR_CL_SSH_USER='$SSH_USER' SR_CL_SSH_PASS=\"\$$BENCH_PASS_VAR\" SR_CL_SSH_PORT='$SSH_PORT'"
    [[ -n "$SUDO" ]] && echo "export SR_CL_SUDO=1"
    if [[ -n "$CL_JUMP" ]]; then
      echo "export SR_CL_JUMP='$CL_JUMP'"
      if [[ -n "$CL_JUMP_KEY" ]]; then echo "export SR_CL_JUMP_KEY='$CL_JUMP_KEY'"
      else echo "export SR_CL_JUMP_PASS=\"\$$BENCH_PASS_VAR\""; fi
    fi
    ;;

  *) sr_die "unknown command '$cmd' (see --help)" ;;
esac
