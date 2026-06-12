#!/usr/bin/env bash
# Shared helpers for talking to a LIVE StarRocks cluster THROUGH the dev host.
# Source this AFTER srlib.sh (it relies on rsh / sr_target / SR_IMAGE):
#     source "$PLUGIN_ROOT/scripts/srlib.sh"
#     source "$PLUGIN_ROOT/scripts/srcluster.sh"
#
# Connection model: the target cluster is reachable from the dev host (SR_HOST),
# which acts as the jump. Every mysql / sshpass / curl runs ON the dev host via the
# existing SSH ControlMaster. The cluster's own connection params are passed by the
# caller per-invocation (a mysql connection string, --conn, or SR_CL_* env) — nothing
# about the target cluster is persisted to disk.
#
# Consumed globals (initialized here from SR_CL_*, then refined by cl_take_flag /
# cl_finalize_params): FE PORT USER_ PASSWORD HTTP_PORT DB and, for node access,
# SSH_USER SSH_PASS SSH_KEY SSH_PORT SUDO.

# ---- cluster/ssh params: env base (lowest precedence) ----
FE="${SR_CL_FE:-}"; PORT="${SR_CL_PORT:-9030}"; USER_="${SR_CL_USER:-root}"
PASSWORD="${SR_CL_PASSWORD:-}"; HTTP_PORT="${SR_CL_HTTP_PORT:-8030}"; DB="${SR_CL_DB:-}"
CONN="${SR_CL_CONN:-}"
SSH_USER="${SR_CL_SSH_USER:-}"; SSH_PASS="${SR_CL_SSH_PASS:-}"; SSH_KEY="${SR_CL_SSH_KEY:-}"
SSH_PORT="${SR_CL_SSH_PORT:-22}"; SUDO="${SR_CL_SUDO:-}"

# Explicit-flag holders so a flag wins over the --conn string regardless of order.
F_FE=""; F_PORT=""; F_USER=""; F_PW=""; PW_SET=0; F_HTTP=""; F_DB=""
# Outputs of cl_take_flag.
CL_TAKEN=0; CL_SHIFT=0

# cl_take_flag <arg> <next> — if <arg> is a common cluster/ssh flag, record it and set
# CL_TAKEN=1 + CL_SHIFT=<args consumed>. Otherwise CL_TAKEN=0. Lets each script's arg
# loop delegate the shared flags and handle only its own.
cl_take_flag() {
  CL_TAKEN=1
  case "$1" in
    --conn)      CONN="$2";      CL_SHIFT=2 ;;
    --fe)        F_FE="$2";      CL_SHIFT=2 ;;
    --port)      F_PORT="$2";    CL_SHIFT=2 ;;
    --user)      F_USER="$2";    CL_SHIFT=2 ;;
    --password)  F_PW="$2"; PW_SET=1; CL_SHIFT=2 ;;
    --http-port) F_HTTP="$2";    CL_SHIFT=2 ;;
    --db)        F_DB="$2";      CL_SHIFT=2 ;;
    --ssh-user)  SSH_USER="$2";  CL_SHIFT=2 ;;
    --ssh-pass)  SSH_PASS="$2";  CL_SHIFT=2 ;;
    --ssh-key)   SSH_KEY="$2";   CL_SHIFT=2 ;;
    --ssh-port)  SSH_PORT="$2";  CL_SHIFT=2 ;;
    --sudo)      SUDO=1;         CL_SHIFT=1 ;;
    *)           CL_TAKEN=0;     CL_SHIFT=0 ;;
  esac
}

# parse_conn "<mysql cmdline>" — extract -h/-P/-u/-p/-D (and the long forms, plus a bare
# trailing db name) into FE/PORT/USER_/PASSWORD/DB. Only fields present are set. Tokens
# are whitespace-split; for a value with spaces use --password/--db instead.
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
      -p*)           PASSWORD="${t#-p}" ;;
      --password)    PASSWORD="${toks[++i]:-}" ;;
      --password=*)  PASSWORD="${t#--password=}" ;;
      -D)            DB="${toks[++i]:-}" ;;
      -D*)           DB="${t#-D}" ;;
      --database)    DB="${toks[++i]:-}" ;;
      --database=*)  DB="${t#--database=}" ;;
      -*)            ;;
      *)             [[ -z "$DB" ]] && DB="$t" ;;
    esac
    ((i++))
  done
}

# cl_finalize_params — apply precedence: SR_CL_* env (already in vars) < --conn string
# < explicit individual flags. Call once after the arg loop.
cl_finalize_params() {
  [[ -n "$CONN" ]] && parse_conn "$CONN"
  [[ -n "$F_FE" ]]     && FE="$F_FE"
  [[ -n "$F_PORT" ]]   && PORT="$F_PORT"
  [[ -n "$F_USER" ]]   && USER_="$F_USER"
  [[ "$PW_SET" == 1 ]] && PASSWORD="$F_PW"
  [[ -n "$F_HTTP" ]]   && HTTP_PORT="$F_HTTP"
  [[ -n "$F_DB" ]]     && DB="$F_DB"
}

cl_need_fe() {
  [[ -n "$FE" ]] || sr_die "no cluster host — pass a connection string: --conn 'mysql -h <host> -P <port> -u <user> -p<pw>' (or SR_CL_CONN / --fe). The host must be reachable FROM the dev host $(sr_target)."
}

_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# cl_hostrun "<cmd>" — execute an arbitrary command string ON the dev host. Shipped
# base64-encoded so any quoting / $() / pipes inside survive untouched.
cl_hostrun() { rsh "echo $(_b64 "$1") | base64 -d | bash"; }

# cl_mysql "<SQL>" — run SQL on the cluster from the dev host. Password via MYSQL_PWD
# (kept off the process command line) and base64-wrapped so any character is safe.
cl_mysql() {
  cl_need_fe
  local pre=""
  [[ -n "$PASSWORD" ]] && pre="export MYSQL_PWD=\"\$(echo $(_b64 "$PASSWORD")|base64 -d)\"; "
  local opts="-h'$FE' -P'$PORT' -u'$USER_' -A --table --connect-timeout=10"
  [[ -n "$DB" ]] && opts="$opts '$DB'"
  cl_hostrun "${pre}echo $(_b64 "$1") | base64 -d | mysql $opts"
}

# cl_node_check "<node>" — validate node + ssh creds. Call DIRECTLY (not inside $())
# so sr_die exits the script, before composing a command string with the helpers below.
cl_node_check() {
  [[ -n "$1" ]]        || sr_die "node host required"
  [[ -n "$SSH_USER" ]] || sr_die "--ssh-user (or SR_CL_SSH_USER) required for node access"
  [[ -n "$SSH_KEY" || -n "$SSH_PASS" ]] \
    || sr_die "node access needs --ssh-pass or --ssh-key (or SR_CL_SSH_PASS / SR_CL_SSH_KEY)"
}

# _cl_node_setup — echo the env-setup (an `export SSHPASS=...;`) that must run on the
# dev host BEFORE any sshpass call, or empty for key auth. Kept separate from the ssh
# command so it can precede a whole pipeline (`<setup> tar ... | <ssh> ...`) instead of
# landing after a pipe, where the leading `export` would detach from the pipeline.
_cl_node_setup() {
  [[ -z "$SSH_KEY" && -n "$SSH_PASS" ]] && printf 'export SSHPASS="$(echo %s|base64 -d)"; ' "$(_b64 "$SSH_PASS")"
}

# _cl_node_ssh "<node>" — echo the ssh command (key or sshpass) to reach <node> from
# the dev host, ready to have a quoted remote command appended OR be used as a pipe
# sink. Assumes cl_node_check already validated creds.
_cl_node_ssh() {
  local sopt="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p $SSH_PORT"
  if [[ -n "$SSH_KEY" ]]; then printf "ssh %s -i '%s' '%s@%s'" "$sopt" "$SSH_KEY" "$SSH_USER" "$1"
  else                        printf "sshpass -e ssh %s '%s@%s'"  "$sopt" "$SSH_USER" "$1"; fi
}

# cl_node_run "<node>" "<cmd>" — run a shell command on a cluster node, hopping through
# the dev host. Uses sshpass (password) or a key; optionally wraps in sudo.
cl_node_run() {
  local node="$1" inner="$2"
  cl_node_check "$node"
  local runner="bash"; [[ -n "$SUDO" ]] && runner="sudo -n bash"
  local nodecmd="echo $(_b64 "$inner") | base64 -d | $runner"
  cl_hostrun "$(_cl_node_setup)$(_cl_node_ssh "$node") \"$nodecmd\""
}

# cl_push_dir "<node>" "<src_parent>" "<name>" "<dst_parent>" — stream the directory
# <src_parent>/<name> from the DEV HOST into <dst_parent>/ on the node (tar over ssh,
# gzip in flight). Overwrites files under <dst_parent>/<name> but does not delete extras
# already there — back the target up first if you need a clean swap. Honors --sudo for
# the remote extract (needed when the install dir is owned by another user).
cl_push_dir() {
  local node="$1" src_parent="$2" name="$3" dst_parent="$4"
  cl_node_check "$node"
  local s=""; [[ -n "$SUDO" ]] && s="sudo -n "
  cl_hostrun "$(_cl_node_setup)tar -C '$src_parent' -czf - '$name' | $(_cl_node_ssh "$node") '${s}mkdir -p \"$dst_parent\" && ${s}tar -C \"$dst_parent\" -xzf -'"
}

# cl_node_os "<node>" — print 'ubuntu' or 'centos' (or the raw os-release ID) for a node.
cl_node_os() {
  local raw id
  raw=$(cl_node_run "$1" 'cat /etc/os-release 2>/dev/null') || return 1
  id=$(printf '%s\n' "$raw" | sed -n 's/^ID=//p' | tr -d '"' | head -1)
  case "$id" in
    ubuntu|debian)                 echo "ubuntu" ;;
    centos|rhel|rocky|almalinux)   echo "centos" ;;
    *)                             echo "${id:-unknown}" ;;
  esac
}

# cl_node_list — print one line per node: "FE <ip>" / "BE <ip>" from SHOW FRONTENDS/BACKENDS.
cl_node_list() {
  cl_need_fe
  cl_mysql "SHOW FRONTENDS\\G" 2>/dev/null | sed -n 's/^ *IP: *//p' | sed 's/^/FE /'
  cl_mysql "SHOW BACKENDS\\G"  2>/dev/null | sed -n 's/^ *IP: *//p' | sed 's/^/BE /'
}

# cl_image_for_os "<os>" — derive the dev-env image for the OS by swapping the os token
# in the default profile's SR_IMAGE, so the registry + tag stay aligned with the user's
# existing setup (e.g. 172.26.92.142:5000/starrocks/dev-env-ubuntu:latest ->
# .../dev-env-centos7:latest). A caller --image always overrides this.
cl_image_for_os() {
  local os="$1" base="${SR_IMAGE:-starrocks/dev-env-ubuntu:latest}"
  case "$os" in
    ubuntu) printf '%s' "${base/dev-env-centos7/dev-env-ubuntu}" ;;
    centos) printf '%s' "${base/dev-env-ubuntu/dev-env-centos7}" ;;
    *)      printf '%s' "$base" ;;
  esac
}
