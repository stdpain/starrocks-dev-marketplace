#!/usr/bin/env bash
# Deploy / manage a single-node StarRocks dev cluster on the remote host.
#
# Run location:
#   - SR_DEPLOY_DIR set  -> artifacts are synced there and the cluster runs from it
#                           (meta/storage/log live under it, so a rebuild/--clean of
#                           output/ never wipes your data).
#   - SR_DEPLOY_DIR unset-> runs in-place from $STARROCKS_HOME/output (data under output/).
# In both cases meta_dir / storage_root_path follow STARROCKS_HOME, which the
# start scripts set to the run dir automatically — so we only manage ports here.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

# Where the cluster RUNS. By default it follows SR_DOCKER (inside the dev-env
# container when that is set for builds). Set SR_DEPLOY_IN_DOCKER=0 to run the
# cluster directly on the HOST while still building in the container: the host
# source path becomes STARROCKS_HOME and every lifecycle command runs on the host.
# Recommended on most dev boxes — the cluster then survives a container rebuild and
# FE/BE bind the host's real NIC.
if [[ -n "${SR_DOCKER:-}" && "${SR_DEPLOY_IN_DOCKER:-1}" == 0 ]]; then
  sr_resolve_host_src                 # fill SR_HOST_SRC (from config, else remote $HOME/basename)
  SR_SRC="$SR_HOST_SRC"               # rsrc cd's here and exports STARROCKS_HOME
  unset SR_DOCKER                     # lifecycle + rsrc now run on the host, not the container
  sr_log "deploying on the HOST (SR_DEPLOY_IN_DOCKER=0): STARROCKS_HOME=$SR_SRC"
fi

MYSQL_HOST="${SR_MYSQL_HOST:-127.0.0.1}"
# BE registration address is resolved lazily (resolve_be_host): it must equal the
# IP the BE detects for itself, so it defaults to the remote `hostname -i`, not
# 127.0.0.1. An explicit SR_BE_HOST always wins.
BE_HOST="${SR_BE_HOST:-}"

# --- Cluster ports (StarRocks defaults; override any in config.env) ---
QUERY_PORT="${SR_QUERY_PORT:-9030}"     # FE  MySQL protocol
FE_HTTP="${SR_HTTP_PORT:-8030}"         # FE  http
FE_RPC="${SR_RPC_PORT:-9020}"           # FE  thrift rpc
FE_EDIT="${SR_EDIT_LOG_PORT:-9010}"     # FE  bdbje edit log
BE_PORT="${SR_BE_PORT:-9060}"           # BE  thrift
BE_HTTP="${SR_BE_HTTP_PORT:-8040}"      # BE  http
BE_HB="${SR_BE_HEARTBEAT:-9050}"        # BE  heartbeat
BE_BRPC="${SR_BE_BRPC_PORT:-8060}"      # BE  brpc

# Shared dev box -> port collisions are likely. With auto-ports on (default), the
# values above are treated as STARTING points: each is bumped to the next free port
# on the remote, then pinned to $RUN/.sr-ports.env so restarts stay stable.
AUTO_PORTS="${SR_AUTO_PORTS:-1}"

# RP: a remote shell prefix that defines OUT (build output) and RUN (run root).
if [[ -n "${SR_DEPLOY_DIR:-}" ]]; then
  RP='OUT="${STARROCKS_OUTPUT:-$STARROCKS_HOME/output}"; RUN="'"$SR_DEPLOY_DIR"'";'
else
  RP='OUT="${STARROCKS_OUTPUT:-$STARROCKS_HOME/output}"; RUN="$OUT";'
fi

PORT_NAMES=(QUERY_PORT FE_HTTP FE_RPC FE_EDIT BE_PORT BE_HTTP BE_HB BE_BRPC)

# Load pinned ports from the run dir into the port globals (so status/restart/sql
# all talk to the right ports). Returns 1 if no state file.
load_pinned() {
  local s; s=$(rsrc "$RP "'[ -f "$RUN/.sr-ports.env" ] && cat "$RUN/.sr-ports.env" || true' 2>/dev/null)
  [[ -n "$s" ]] || return 1
  local k v
  while IFS='=' read -r k v; do
    case " ${PORT_NAMES[*]} " in *" $k "*) [[ "$v" =~ ^[0-9]+$ ]] && printf -v "$k" '%s' "$v" ;; esac
  done <<< "$s"
  return 0
}

write_state() {
  local content; content=$(for n in "${PORT_NAMES[@]}"; do printf '%s=%s\n' "$n" "${!n}"; done)
  local b64; b64=$(printf '%s' "$content" | base64 | tr -d '\n')
  rsrc "$RP "'mkdir -p "$RUN"; printf %s "'"$b64"'" | base64 -d > "$RUN/.sr-ports.env"; echo "pinned ports -> $RUN/.sr-ports.env"'
}

# Remote snippet: bump each desired port to the next free one (and never reuse one
# already picked this round). Emits NAME=PORT lines.
build_alloc() {
  cat <<EOF
inuse() {
  if command -v ss >/dev/null 2>&1; then ss -ltnH 2>/dev/null | awk '{print \$4}' | sed 's/.*://' | grep -qx "\$1";
  elif command -v netstat >/dev/null 2>&1; then netstat -ltn 2>/dev/null | awk '{print \$4}' | sed 's/.*://' | grep -qx "\$1";
  else (exec 3<>/dev/tcp/127.0.0.1/\$1) 2>/dev/null && { exec 3>&-; return 0; } || return 1; fi
}
used=" "
# pick <varname> <start>: assign the first free port >= start (and not already
# picked this run) into <varname>. Runs in one shell so \$used persists.
pick() { local p=\$2; while inuse "\$p" || case "\$used" in *" \$p "*) true;; *) false;; esac; do p=\$((p+1)); done; used="\$used\$p "; printf -v "\$1" %s "\$p"; }
pick QUERY_PORT $QUERY_PORT
pick FE_HTTP    $FE_HTTP
pick FE_RPC     $FE_RPC
pick FE_EDIT    $FE_EDIT
pick BE_PORT    $BE_PORT
pick BE_HTTP    $BE_HTTP
pick BE_HB      $BE_HB
pick BE_BRPC    $BE_BRPC
for v in QUERY_PORT FE_HTTP FE_RPC FE_EDIT BE_PORT BE_HTTP BE_HB BE_BRPC; do echo "\$v=\${!v}"; done
EOF
}

# Decide the ports to use: reuse the pin unless reassigning; otherwise probe+pin.
resolve_ports() {
  [[ "$AUTO_PORTS" == 1 ]] || return 0
  if [[ "${SR_REASSIGN_PORTS:-0}" != 1 ]] && load_pinned; then
    sr_log "using pinned ports (query=$QUERY_PORT). Reallocate with: SR_REASSIGN_PORTS=1 ... or 'deploy.sh ports'"
    return 0
  fi
  sr_log "probing remote for free ports (starting from configured values) ..."
  local out k v; out=$(rsrc "$(build_alloc)") || sr_die "port probe failed on remote"
  while IFS='=' read -r k v; do
    case " ${PORT_NAMES[*]} " in *" $k "*) [[ "$v" =~ ^[0-9]+$ ]] && printf -v "$k" '%s' "$v" ;; esac
  done <<< "$out"
  sr_log "ports: FE query=$QUERY_PORT http=$FE_HTTP rpc=$FE_RPC edit=$FE_EDIT | BE be=$BE_PORT http=$BE_HTTP hb=$BE_HB brpc=$BE_BRPC"
  write_state
}

runsql() { rsrc "mysql -h'$MYSQL_HOST' -P'$QUERY_PORT' -uroot -N -e '$1'"; }

wait_for_fe() {
  sr_log "waiting for FE query port $MYSQL_HOST:$QUERY_PORT ..."
  local i
  for i in $(seq 1 40); do
    if rsrc "mysql -h'$MYSQL_HOST' -P'$QUERY_PORT' -uroot -N -e 'SELECT 1' >/dev/null 2>&1"; then
      sr_log "FE is up."; return 0
    fi
    sleep 3
  done
  sr_die "FE did not accept connections within ~120s. Check: bash scripts/deploy.sh logs fe"
}

# Sync build artifacts into SR_DEPLOY_DIR (no-op if it equals output). Refreshes
# binaries/libs each call; preserves conf (managed separately), meta, storage, log.
sync_deploy() {
  [[ -n "${SR_DEPLOY_DIR:-}" ]] || return 0
  sr_log "syncing artifacts -> $SR_DEPLOY_DIR ..."
  rsrc "$RP "'
    [ "$RUN" = "$OUT" ] && { echo "(deploy dir == output, nothing to sync)"; exit 0; }
    for c in fe be; do
      mkdir -p "$RUN/$c"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --exclude conf --exclude meta --exclude storage --exclude log \
          "$OUT/$c/" "$RUN/$c/"
      else
        for d in bin lib spark-dpp webroot www; do
          [ -d "$OUT/$c/$d" ] && { mkdir -p "$RUN/$c/$d"; cp -af "$OUT/$c/$d/." "$RUN/$c/$d/"; }
        done
        find "$OUT/$c" -maxdepth 1 -type f -exec cp -af {} "$RUN/$c/" \; 2>/dev/null || true
      fi
      [ -d "$RUN/$c/conf" ] || cp -a "$OUT/$c/conf" "$RUN/$c/conf"
      mkdir -p "$RUN/$c/log"
    done
    mkdir -p "$RUN/fe/meta" "$RUN/be/storage"
    echo "synced -> $RUN"'
}

# Write the managed port block into fe.conf/be.conf (idempotent: strips its own
# previous block first, so manual edits above the marker are preserved).
gen_conf() {
  # priority_networks: explicit SR_PRIORITY_NET wins; otherwise on a multi-NIC host
  # (e.g. real NIC + docker0) auto-pin BOTH FE and BE to the real NIC, so the FE
  # doesn't drift onto docker0 while the BE binds the physical NIC (which leaves the
  # BE stuck registering under a mismatched address).
  local PN="${SR_PRIORITY_NET:-}"
  if [[ -z "$PN" ]]; then
    resolve_cluster_net
    if [[ "${CLUSTER_NICS:-0}" -gt 1 && -n "${CLUSTER_CIDR:-}" ]]; then
      PN="$CLUSTER_CIDR"
      sr_log "auto priority_networks=$PN (multi-NIC host; pinning FE+BE to the real NIC)"
    fi
  fi
  local pn=""
  [[ -n "$PN" ]] && pn=$'\n'"priority_networks = $PN"
  local feb beb
  feb="# === starrocks-dev (managed) ===
http_port = $FE_HTTP
rpc_port = $FE_RPC
query_port = $QUERY_PORT
edit_log_port = $FE_EDIT$pn"
  beb="# === starrocks-dev (managed) ===
be_port = $BE_PORT
be_http_port = $BE_HTTP
heartbeat_service_port = $BE_HB
brpc_port = $BE_BRPC$pn"
  local fe64 be64
  fe64=$(printf '%s\n' "$feb" | base64 | tr -d '\n')
  be64=$(printf '%s\n' "$beb" | base64 | tr -d '\n')
  sr_log "writing ports: FE http=$FE_HTTP rpc=$FE_RPC query=$QUERY_PORT edit=$FE_EDIT | BE be=$BE_PORT http=$BE_HTTP hb=$BE_HB brpc=$BE_BRPC${PN:+ | priority_networks=$PN}"
  rsrc "$RP "'
    for pair in "fe:'"$fe64"'" "be:'"$be64"'"; do
      c="${pair%%:*}"; data="${pair#*:}"
      conf="$RUN/$c/conf/$c.conf"
      [ -f "$conf" ] || { echo "missing $conf — build/sync first"; continue; }
      sed -i "/^# === starrocks-dev (managed) ===$/,\$d" "$conf"
      printf "\n" >> "$conf"
      printf "%s" "$data" | base64 -d >> "$conf"
      printf "\n" >> "$conf"
      echo "configured $conf"
    done'
}

prepare() { sync_deploy; resolve_ports; gen_conf; }

start_be() { sr_log "starting BE ...";  rsrc "$RP \$RUN/be/bin/start_be.sh --daemon"; }
start_fe() { sr_log "starting FE ...";  rsrc "$RP \$RUN/fe/bin/start_fe.sh --daemon"; }
stop_be()  { sr_log "stopping BE ...";  rsrc "$RP \$RUN/be/bin/stop_be.sh || true"; }
stop_fe()  { sr_log "stopping FE ...";  rsrc "$RP \$RUN/fe/bin/stop_fe.sh || true"; }

# resolve_cluster_net — inspect (once) the network of wherever the cluster runs
# (host or container). Sets three globals:
#   CLUSTER_CIDR  first global IPv4 on a *real* NIC, e.g. 172.26.92.227/24
#                 (virtual ifaces docker0/br-/veth/… are skipped, so a docker
#                  bridge never wins over the physical NIC)
#   CLUSTER_IP    its address, e.g. 172.26.92.227 (falls back to `hostname -i`)
#   CLUSTER_NICS  count of global IPv4 addresses (>1 => multi-NIC / docker host)
resolve_cluster_net() {
  [[ -n "${_CLUSTER_RESOLVED:-}" ]] && return 0
  # Portable: rely on hostname(1), which is correct in both a container (its own IP)
  # and on a multi-NIC host (its primary/real NIC). ip(8) is often absent in the
  # dev-env container, so it's used only to refine the netmask when present.
  local out
  out=$(rsrc '
    ipi=$(hostname -i 2>/dev/null | tr " " "\n" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" | head -1)
    n=$(hostname -I 2>/dev/null | tr " " "\n" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" | grep -vE "^127\." | grep -c .)
    cidr=""
    if command -v ip >/dev/null 2>&1 && [ -n "$ipi" ]; then
      cidr=$(ip -o -4 addr show 2>/dev/null | tr " " "\n" | grep -E "^${ipi}/[0-9]+$" | head -1)
    fi
    echo "IP=$ipi"; echo "NICS=$n"; echo "CIDR=$cidr"')
  CLUSTER_IP=$(sed -n 's/^IP=//p'   <<<"$out" | tr -d '[:space:]')
  CLUSTER_NICS=$(sed -n 's/^NICS=//p' <<<"$out" | tr -dc '0-9')
  CLUSTER_CIDR=$(sed -n 's/^CIDR=//p' <<<"$out" | tr -d '[:space:]')
  # No exact netmask from ip(8)? Fall back to a /24 around the chosen IP — enough
  # for priority_networks to match that NIC.
  [[ -z "$CLUSTER_CIDR" && -n "$CLUSTER_IP" ]] && CLUSTER_CIDR="${CLUSTER_IP%.*}.0/24"
  _CLUSTER_RESOLVED=1
}

# resolve_be_host — the address the BE registers under MUST equal the IP the BE
# detects for itself (its priority-network pick == the real-NIC IP). If they
# differ the FE heartbeat is rejected ("not equal to backend localhost <ip>") and
# the BE never goes Alive. So default to the cluster's real-NIC IP, not 127.0.0.1.
resolve_be_host() {
  [[ -n "$BE_HOST" ]] && return 0
  resolve_cluster_net
  BE_HOST="${CLUSTER_IP:-127.0.0.1}"
}

register() {
  resolve_be_host
  sr_log "checking BE registration ($BE_HOST:$BE_HB) ..."
  if runsql "SHOW BACKENDS" | grep -q "$BE_HOST"; then
    sr_log "BE already registered."
  else
    sr_log "registering BE ..."
    runsql "ALTER SYSTEM ADD BACKEND \"$BE_HOST:$BE_HB\""
    sleep 3
  fi
}

# verify_be — wait for the BE to report Alive; if it never does, diagnose the
# classic host-mismatch from be.WARNING and self-heal by dropping the wrongly
# registered backend and re-adding it under the BE's real self-detected IP.
verify_be() {
  resolve_be_host
  local i
  for i in $(seq 1 12); do
    runsql "SHOW BACKENDS" 2>/dev/null | grep -qiE '(^|[[:space:]])true([[:space:]]|$)' && { sr_log "BE is Alive."; return 0; }
    sleep 5
  done
  sr_log "BE not Alive after ~60s — checking be.WARNING for a host mismatch ..."
  local realip
  realip=$(rsrc "$RP "'tail -n 300 "$(ls -t "$RUN"/be/log/be.WARNING* 2>/dev/null | head -1)" 2>/dev/null' \
            | sed -n 's/.*backend localhost \([0-9.][0-9.]*\).*/\1/p' | tail -1)
  if [[ -z "$realip" ]]; then
    sr_log "no host mismatch detected. Inspect: bash scripts/deploy.sh logs be"
    return 1
  fi
  sr_log "BE self-identifies as $realip but was registered under a different address — re-registering."
  # Drop any backend on our heartbeat port whose IP != the real one, then add it.
  local line ip hb
  while read -r line; do
    [[ -z "$line" ]] && continue
    ip=$(awk '{print $2}' <<<"$line"); hb=$(awk '{print $3}' <<<"$line")
    [[ "$hb" == "$BE_HB" && -n "$ip" && "$ip" != "$realip" ]] && \
      runsql "ALTER SYSTEM DROP BACKEND \"$ip:$hb\"" 2>/dev/null || true
  done < <(runsql "SHOW BACKENDS" 2>/dev/null)
  BE_HOST="$realip"
  runsql "SHOW BACKENDS" | grep -q "$realip" || runsql "ALTER SYSTEM ADD BACKEND \"$realip:$BE_HB\""
  for i in $(seq 1 12); do
    runsql "SHOW BACKENDS" 2>/dev/null | grep -qiE '(^|[[:space:]])true([[:space:]]|$)' && {
      sr_log "BE is Alive (registered as $realip)."
      sr_log "tip: persist it with  SR_BE_HOST=$realip  in $SR_CFG_FILE to skip this next time."
      return 0; }
    sleep 5
  done
  sr_log "BE still not Alive. Inspect: bash scripts/deploy.sh logs be"
  return 1
}

status() {
  resolve_be_host
  echo "── run root ──"; rsrc "$RP "'echo "$RUN"'
  echo "── ports ──"; echo "  FE query=$QUERY_PORT http=$FE_HTTP rpc=$FE_RPC edit=$FE_EDIT | BE be=$BE_PORT http=$BE_HTTP hb=$BE_HB brpc=$BE_BRPC (be_host=$BE_HOST)  (mysql -h$MYSQL_HOST -P$QUERY_PORT -uroot)"
  echo "── processes ──"
  rsrc 'ps -ef | grep -E "StarRocksFE|starrocks_be" | grep -v grep || echo "(no FE/BE processes)"'
  echo "── SHOW FRONTENDS ──"; runsql "SHOW FRONTENDS" || sr_log "(FE not reachable)"
  echo "── SHOW BACKENDS ──";  runsql "SHOW BACKENDS"  || sr_log "(FE not reachable)"
}

logs() {
  case "${1:-fe}" in
    fe) rsrc "$RP "'tail -n 120 "$RUN/fe/log/fe.log" 2>/dev/null; echo "--- fe.out ---"; tail -n 40 "$RUN/fe/log/fe.out" 2>/dev/null' ;;
    be) rsrc "$RP "'tail -n 120 "$(ls -t "$RUN"/be/log/be.INFO* 2>/dev/null | head -1)" 2>/dev/null; echo "--- be.out ---"; tail -n 40 "$RUN/be/log/be.out" 2>/dev/null' ;;
    *)  sr_die "usage: deploy.sh logs [fe|be]" ;;
  esac
}

cmd="${1:-up}"; shift || true

# Lifecycle runs inside the dev-env container when SR_DOCKER is set.
sr_ensure_docker

# Adopt already-pinned ports up front so status/restart/sql/logs use them too.
[[ "$AUTO_PORTS" == 1 ]] && load_pinned >/dev/null 2>&1 || true

case "$cmd" in
  up)
    prepare; start_be; start_fe; wait_for_fe; register; verify_be; status ;;
  config)
    prepare; sr_log "conf written. Restart to apply: bash scripts/deploy.sh restart" ;;
  ports)
    SR_REASSIGN_PORTS=1; resolve_ports; gen_conf
    sr_log "ports (re)assigned. Restart to apply: bash scripts/deploy.sh restart" ;;
  start)
    case "${1:-all}" in all) start_be; start_fe ;; fe) start_fe ;; be) start_be ;; *) sr_die "start [all|fe|be]";; esac ;;
  stop)
    case "${1:-all}" in all) stop_fe; stop_be ;; fe) stop_fe ;; be) stop_be ;; *) sr_die "stop [all|fe|be]";; esac ;;
  restart)
    case "${1:-all}" in
      all) stop_fe; stop_be; sleep 2; sync_deploy; start_be; start_fe; wait_for_fe; status ;;
      fe)  stop_fe; sleep 2; sync_deploy; start_fe; wait_for_fe ;;
      be)  stop_be; sleep 2; sync_deploy; start_be ;;
      *)   sr_die "restart [all|fe|be]";;
    esac ;;
  register) register; verify_be; status ;;
  status)   status ;;
  logs)     logs "${1:-fe}" ;;
  sql)
    [[ -n "${1:-}" ]] || sr_die "usage: deploy.sh sql 'SHOW DATABASES'"
    runsql "$1" ;;
  *) sr_die "unknown command '$cmd'. Use: up|config|ports|start|stop|restart|register|status|logs|sql" ;;
esac
