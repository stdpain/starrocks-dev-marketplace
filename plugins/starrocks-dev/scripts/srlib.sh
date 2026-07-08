#!/usr/bin/env bash
# Shared helpers for the starrocks-dev skills (sr-connect / sr-build / sr-deploy).
# Source this; do not run it directly:  source "$PLUGIN_ROOT/scripts/srlib.sh"
#
# Connection model: plain SSH to a single remote dev host. The StarRocks source
# tree lives on that host at $SR_SRC and Claude edits/builds/deploys it remotely.
# An SSH ControlMaster socket is reused so repeated commands don't re-handshake.

set -uo pipefail

# Config layout — profiles enable parallel work.
#   $SR_CFG_BASE/                         base dir (shared state lives here)
#   $SR_CFG_BASE/config.env               the DEFAULT profile (SR_PROFILE unset)
#   $SR_CFG_BASE/profiles/<name>/config.env   a named profile (SR_PROFILE=<name>)
#   $SR_CFG_BASE/cm-<user>@<host>:<port>  SSH ControlMaster socket(s)
# Each profile is an INDEPENDENT task — its own container (SR_DOCKER), source
# worktree (SR_HOST_SRC), deploy dir and ports — so several features can be built
# and deployed in parallel with `SR_PROFILE=featA bash build.sh` &
# `SR_PROFILE=featB bash build.sh`. Leaving SR_PROFILE unset uses the default
# profile exactly as before (backward compatible). The ControlMaster socket stays
# in the base dir on purpose: it is keyed per host, so parallel profiles targeting
# the same dev box share one multiplexed SSH connection instead of re-handshaking.
SR_CFG_BASE="${SR_CFG_BASE:-$HOME/.config/starrocks_dev}"
mkdir -p "$SR_CFG_BASE"; chmod 700 "$SR_CFG_BASE" 2>/dev/null || true
if [[ -n "${SR_PROFILE:-}" ]]; then
  [[ "$SR_PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] \
    || { printf 'starrocks-dev: invalid SR_PROFILE %q (use letters, digits, . _ -)\n' "$SR_PROFILE" >&2; exit 1; }
  SR_CFG_DIR="$SR_CFG_BASE/profiles/$SR_PROFILE"
else
  SR_CFG_DIR="$SR_CFG_BASE"
fi
SR_CFG_FILE="$SR_CFG_DIR/config.env"
mkdir -p "$SR_CFG_DIR"
chmod 700 "$SR_CFG_DIR" 2>/dev/null || true

# Load config.env (key=value). Real env vars take precedence: the file is the
# stored default, but a one-off `SR_X=… bash scripts/...` (or `SR_X=` to disable a
# key, e.g. SR_DOCKER=) overrides it. Sourcing alone would clobber the env, so we
# snapshot any SR_* already set, source the file, then restore the snapshot.
if [[ -f "$SR_CFG_FILE" ]]; then
  declare -A _SR_ENV_OVERRIDE=()
  for _k in $(compgen -v | grep '^SR_' || true); do
    case "$_k" in SR_CFG_DIR|SR_CFG_FILE|SR_CFG_BASE|SR_PROFILE) continue ;; esac
    _SR_ENV_OVERRIDE["$_k"]=1
    printf -v "_SR_VAL_$_k" '%s' "${!_k}"
  done
  set -a
  # shellcheck disable=SC1090
  source "$SR_CFG_FILE"
  set +a
  for _k in "${!_SR_ENV_OVERRIDE[@]}"; do
    _vn="_SR_VAL_$_k"; printf -v "$_k" '%s' "${!_vn}"
  done
  unset _k _vn _SR_ENV_OVERRIDE ${!_SR_VAL_@}
fi

# Host-global keys inherited from the BASE config by an active profile when the
# profile didn't set them. A profile's config.env is a snapshot taken at create
# time, so a profile created BEFORE these keys were added to the base would never
# see them otherwise. SR_CCACHE / SR_CCACHE_SIZE describe ONE host-level shared
# cache (namespaced per image), so they belong to the whole box, not a snapshot.
# GUARD: only inherit when the profile targets the SAME dev host as the base. A
# cross-host profile (created by `workspace.sh add-host`, reached THROUGH the main
# host as a jump) lives on a different filesystem — the base's SR_CCACHE path is
# meaningless there, and mounting it would point ccache at a bogus dir on the wrong
# box. Such a profile keeps its own (or no) cache.
if [[ -n "${SR_PROFILE:-}" && -f "$SR_CFG_BASE/config.env" ]]; then
  _base_host=$(sed -n "s/^SR_HOST='\(.*\)'\$/\1/p" "$SR_CFG_BASE/config.env" | tail -1)
  if [[ -n "${SR_HOST:-}" && "${SR_HOST:-}" == "$_base_host" ]]; then
    for _gk in SR_CCACHE SR_CCACHE_SIZE; do
      if [[ -z "${!_gk:-}" ]]; then
        _gv=$(sed -n "s/^$_gk='\(.*\)'\$/\1/p" "$SR_CFG_BASE/config.env" | tail -1)
        [[ -n "$_gv" ]] && printf -v "$_gk" '%s' "$_gv"
      fi
    done
    unset _gk _gv
  fi
  unset _base_host
fi

# Defaults (only applied if unset).
SR_PORT="${SR_PORT:-22}"
SR_BUILD_TYPE="${SR_BUILD_TYPE:-Release}"
# Docker dev-env defaults.
SR_IMAGE="${SR_IMAGE:-starrocks/dev-env-ubuntu:latest}"
# SR_HOST_SRC: source path on the HOST (used for the `-v` mount). If unset it is
# resolved at runtime (sr_resolve_host_src) to remote $HOME/basename(SR_SRC) —
# e.g. /home/<user>/starrocks — because the in-container build path SR_SRC
# (e.g. /root/starrocks) differs from the host path. Set it explicitly to override.
SR_NOFILE="${SR_NOFILE:-655350}"
# Shared-ccache size cap, per dev-env image (see SR_CCACHE).
SR_CCACHE_SIZE="${SR_CCACHE_SIZE:-80G}"
# SR_DOCKER          — container name; when set, build/test/deploy run inside it
# SR_M2              — host ~/.m2 path to mount as /root/.m2 (Maven cache reuse)
# SR_CCACHE          — host dir holding the shared C++ ccache. Mounted as /root/.ccache,
#                      namespaced per dev-env image so all profiles on the same toolchain
#                      share one warm cache (different OS images stay isolated). Inherited
#                      by every profile, so set it once on the base config.
# SR_CCACHE_SIZE     — ccache max_size cap, PER dev-env image (default 80G).
# SR_DOCKER_RUN_OPTS — extra `docker run` opts, e.g. '--network host' or '-p 9030:9030'

sr_log()  { printf 'starrocks-dev: %s\n' "$*" >&2; }
sr_die()  { printf 'starrocks-dev: %s\n' "$*" >&2; exit 1; }

# Every documented SR_* config key, in the order written to config.env. Keep in
# sync with config.env.example. NOTE: SR_PROFILE / SR_CFG_* are NOT here — they
# select WHICH config file is active and must never be persisted into one.
SR_CONFIG_KEYS=(
  # connection
  SR_HOST SR_USER SR_PORT SR_KEY SR_PROXY_JUMP SR_SRC
  # docker dev-env
  SR_DOCKER SR_IMAGE SR_HOST_SRC SR_NOFILE SR_M2 SR_CCACHE SR_CCACHE_SIZE SR_DOCKER_RUN_OPTS
  # build
  SR_THIRDPARTY SR_JOBS SR_BUILD_TYPE
  # backport (sr-backport): dev-env image tag template per target branch
  SR_BP_IMAGE_TPL
  # deploy
  SR_DEPLOY_DIR SR_DEPLOY_IN_DOCKER SR_MYSQL_HOST SR_BE_HOST SR_PRIORITY_NET SR_AUTO_PORTS
  SR_QUERY_PORT SR_HTTP_PORT SR_RPC_PORT SR_EDIT_LOG_PORT
  SR_BE_PORT SR_BE_HTTP_PORT SR_BE_HEARTBEAT SR_BE_BRPC_PORT
)

# sr_write_config <path> — write the SR_CONFIG_KEYS currently set in the env to
# <path> (chmod 600). Merge semantics are the caller's job: srlib already sourced
# the existing file into the env, so an unset key keeps its current value and any
# SR_* present in the env (file value, or a one-off override) is what gets written.
# Used by setup.sh (default/active profile) and workspace.sh (scaffold a profile).
sr_write_config() {
  local path="$1" tmp k v
  ( umask 077
    tmp="$path.tmp.$$"
    {
      echo "# starrocks-dev config — written by sr-connect"
      for k in "${SR_CONFIG_KEYS[@]}"; do
        v="${!k:-}"
        [[ -n "$v" ]] && printf "%s='%s'\n" "$k" "$v"
      done
    } > "$tmp"
    mv "$tmp" "$path"
    chmod 600 "$path"
  )
}

# sr_remote_home — the remote host's $HOME (cached for the process).
sr_remote_home() {
  [[ -n "${_SR_REMOTE_HOME:-}" ]] && { printf '%s' "$_SR_REMOTE_HOME"; return 0; }
  _SR_REMOTE_HOME=$(rsh 'printf %s "$HOME"')
  printf '%s' "$_SR_REMOTE_HOME"
}

# sr_resolve_host_src — fill SR_HOST_SRC if unset.
# Default = remote host's $HOME / basename(SR_SRC), e.g. /home/<user>/starrocks.
sr_resolve_host_src() {
  [[ -n "${SR_HOST_SRC:-}" ]] && return 0
  local home; home=$(sr_remote_home)
  [[ -n "$home" ]] || sr_die "could not resolve remote \$HOME for SR_HOST_SRC — set it explicitly in $SR_CFG_FILE."
  [[ -n "${SR_SRC:-}" ]] || sr_die "SR_SRC unset — cannot derive SR_HOST_SRC."
  SR_HOST_SRC="$home/$(basename "$SR_SRC")"
  sr_log "SR_HOST_SRC defaulted to remote \$HOME/$(basename "$SR_SRC"): $SR_HOST_SRC"
}

sr_target() {
  if [[ -n "${SR_USER:-}" ]]; then printf '%s@%s' "$SR_USER" "$SR_HOST"
  else printf '%s' "${SR_HOST:?SR_HOST not set}"; fi
}

# Build the global SSH option array once. Uses a persistent ControlMaster so the
# first connection authenticates and the rest are instant for ~5 min.
_sr_build_ssh_opts() {
  [[ -n "${SR_HOST:-}" ]] || sr_die "SR_HOST is empty. Run sr-connect setup first (writes $SR_CFG_FILE)."
  SSH_OPTS=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ControlMaster=auto
    -o "ControlPath=$SR_CFG_BASE/cm-%r@%h:%p"
    -o ControlPersist=300
    -p "$SR_PORT"
  )
  [[ -n "${SR_KEY:-}" ]]        && SSH_OPTS+=(-i "$SR_KEY")
  # ProxyJump (bastion). Value like 'user@jump:port' or a comma list 'j1,j2'.
  [[ -n "${SR_PROXY_JUMP:-}" ]] && SSH_OPTS+=(-o "ProxyJump=$SR_PROXY_JUMP")
}

# rsh "<cmd>" — run a raw shell command on the remote HOST. Streams stdout/stderr,
# returns the remote exit code.
rsh() {
  [[ -n "${SSH_OPTS+x}" ]] || _sr_build_ssh_opts
  ssh "${SSH_OPTS[@]}" "$(sr_target)" "$1"
}

# rsrc "<cmd>" — run a command with STARROCKS_HOME set and cwd = $SR_SRC. If
# SR_DOCKER names a dev-env container, the command runs inside it (the source is
# assumed bind-mounted at the same $SR_SRC path, which is the standard dev-env setup).
# The command is shipped base64-encoded so quoting/metacharacters never break.
rsrc() {
  [[ -n "${SR_SRC:-}" ]] || sr_die "SR_SRC is empty. Set the remote StarRocks source path in $SR_CFG_FILE."
  local inner b64
  inner="export STARROCKS_HOME='$SR_SRC'"
  [[ -n "${SR_THIRDPARTY:-}" ]] && inner+="; export STARROCKS_THIRDPARTY='$SR_THIRDPARTY'"
  inner+="; cd '$SR_SRC' || exit 1; $1"
  b64=$(printf '%s' "$inner" | base64 | tr -d '\n')
  if [[ -n "${SR_DOCKER:-}" ]]; then
    rsh "docker exec -i '$SR_DOCKER' bash -lc 'echo $b64 | base64 -d | bash'"
  else
    rsh "echo $b64 | base64 -d | bash -l"
  fi
}

# rput <local> <remote>  /  rget <remote> <local> — copy files over the same SSH
# transport (rsync if available, else scp). Paths are HOST paths.
_sr_scp_opts() {
  SCP_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -P "$SR_PORT")
  [[ -n "${SR_KEY:-}" ]]        && SCP_OPTS+=(-i "$SR_KEY")
  [[ -n "${SR_PROXY_JUMP:-}" ]] && SCP_OPTS+=(-o "ProxyJump=$SR_PROXY_JUMP")
}
rput() {
  _sr_scp_opts
  if command -v rsync >/dev/null 2>&1; then
    local rsh_cmd="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p $SR_PORT"
    [[ -n "${SR_KEY:-}" ]]        && rsh_cmd+=" -i $SR_KEY"
    [[ -n "${SR_PROXY_JUMP:-}" ]] && rsh_cmd+=" -o ProxyJump=$SR_PROXY_JUMP"
    rsync -az -e "$rsh_cmd" "$1" "$(sr_target):$2"
  else
    scp "${SCP_OPTS[@]}" -r "$1" "$(sr_target):$2"
  fi
}
rget() {
  _sr_scp_opts
  scp "${SCP_OPTS[@]}" -r "$(sr_target):$1" "$2"
}

# sr_ensure_docker — make sure the dev-env container is up, creating it if needed.
# No-op when SR_DOCKER is unset (building directly on the host). Idempotent:
#   running        -> nothing
#   exists, stopped-> docker start
#   absent         -> pull image if missing, then docker run with source mount.
# Mirrors the project's standard invocation:
#   docker run --name <c> --ulimit nofile=N:N -v <host_src>:<container_src> -dit <image> /bin/bash
sr_ensure_docker() {
  [[ -n "${SR_DOCKER:-}" ]] || return 0
  if rsh "docker inspect -f '{{.State.Running}}' '$SR_DOCKER' 2>/dev/null" 2>/dev/null | grep -q true; then
    : # already running
  elif rsh "docker inspect '$SR_DOCKER' >/dev/null 2>&1"; then
    sr_log "starting existing container $SR_DOCKER ..."
    rsh "docker start '$SR_DOCKER'" >/dev/null || sr_die "docker start $SR_DOCKER failed"
  else
    # Need to create it.
    [[ -n "${SR_IMAGE:-}" ]] || sr_die "container $SR_DOCKER absent and SR_IMAGE unset."
    [[ -n "${SR_SRC:-}" ]]   || sr_die "SR_SRC unset (in-container source path to mount to, e.g. /root/starrocks)."
    sr_resolve_host_src   # SR_HOST_SRC defaults to the remote host's $HOME
    if ! rsh "docker image inspect '$SR_IMAGE' >/dev/null 2>&1"; then
      sr_log "image $SR_IMAGE not present — pulling (first time, may take a while) ..."
      rsh "docker pull '$SR_IMAGE'" || sr_die "docker pull $SR_IMAGE failed (check registry access / VPN)."
    fi
    local mounts="-v '$SR_HOST_SRC':'$SR_SRC'"
    [[ -n "${SR_M2:-}" ]] && mounts+=" -v '$SR_M2':/root/.m2"
    # Shared ccache. The cache dir is namespaced by dev-env IMAGE (= toolchain/OS),
    # NOT by profile: every profile on the same image shares one warm cache, while
    # a different OS image lands in a separate dir so toolchains never cross-pollute.
    # base_dir is set per container to SR_SRC (via CCACHE_BASEDIR) and hash_dir=false,
    # so the same source built from different worktree paths still hits.
    local cc_opts=""
    if [[ -n "${SR_CCACHE:-}" ]]; then
      local cctag cdir
      cctag=$(printf '%s' "$SR_IMAGE" | tr -c 'A-Za-z0-9._-' '_')
      cdir="$SR_CCACHE/$cctag"
      rsh "mkdir -p '$cdir' && cat > '$cdir/ccache.conf' <<'CCACHE_CONF'
max_size = $SR_CCACHE_SIZE
hash_dir = false
compiler_check = content
sloppiness = time_macros,include_file_mtime,include_file_ctime,pch_defines
CCACHE_CONF" || sr_die "failed to prepare shared ccache dir $cdir on the remote host."
      mounts+=" -v '$cdir':/root/.ccache"
      # CCACHE_DIR pins the location (ccache 4.x otherwise defaults to ~/.cache/ccache);
      # CCACHE_BASEDIR rewrites absolute paths under the source root to relative before
      # hashing, so base and named profiles (different SR_SRC) share cache entries.
      cc_opts="-e CCACHE_DIR=/root/.ccache -e CCACHE_BASEDIR='$SR_SRC'"
      sr_log "ccache: shared $cdir -> /root/.ccache (image-namespaced, basedir=$SR_SRC)"
    fi
    sr_log "creating container $SR_DOCKER from $SR_IMAGE (mount $SR_HOST_SRC -> $SR_SRC) ..."
    rsh "docker run --name '$SR_DOCKER' --ulimit nofile=${SR_NOFILE}:${SR_NOFILE} $mounts $cc_opts ${SR_DOCKER_RUN_OPTS:-} -dit '$SR_IMAGE' /bin/bash" >/dev/null \
      || sr_die "docker run failed for $SR_DOCKER"
    sr_log "container $SR_DOCKER is up."
  fi
  sr_mark_git_safe   # the mounted source is owned by the host user, not container root
}

# sr_mark_git_safe — register $SR_SRC as a git "safe.directory" wherever commands
# run (inside the container when SR_DOCKER is set). Without this, git refuses to
# operate on the bind-mounted tree ("detected dubious ownership"), which breaks
# build.sh's version-stamping step. Idempotent: only adds the entry if missing.
sr_mark_git_safe() {
  [[ -n "${SR_SRC:-}" ]] || return 0
  rsrc 'git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$STARROCKS_HOME" \
        || git config --global --add safe.directory "$STARROCKS_HOME"' >/dev/null 2>&1 || true
}

# sr_prime_known_hosts — pre-trust the jump host(s) and target so the first
# BatchMode connection doesn't abort on an unknown host key. The jump host is the
# usual culprit: under BatchMode=yes a never-seen jump key can't be accepted
# interactively, and the connection dies with a cryptic "Connection closed by
# UNKNOWN port 65535". ssh-keyscan adds them up front. Best-effort and idempotent.
sr_prime_known_hosts() {
  command -v ssh-keyscan >/dev/null 2>&1 || return 0
  local kh="$HOME/.ssh/known_hosts" host port entry
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh" 2>/dev/null || true
  local scan=()
  # jump host(s) first — value is 'user@host[:port]' or a comma list 'j1,j2'
  if [[ -n "${SR_PROXY_JUMP:-}" ]]; then
    local IFS=','; local jumps=($SR_PROXY_JUMP); unset IFS
    for entry in "${jumps[@]}"; do
      entry="${entry##*@}"                       # strip user@
      host="${entry%%:*}"; port="${entry##*:}"
      [[ "$port" == "$host" ]] && port=22
      scan+=("$port $host")
    done
  fi
  scan+=("${SR_PORT:-22} ${SR_HOST:-}")
  local pair
  for pair in "${scan[@]}"; do
    port="${pair%% *}"; host="${pair#* }"
    [[ -n "$host" ]] || continue
    ssh-keygen -F "$host" >/dev/null 2>&1 && continue   # already trusted
    ssh-keyscan -T 5 -p "$port" "$host" 2>/dev/null >> "$kh" || true
  done
}

# sr_conn_test — verify the connection and print one identity line.
sr_conn_test() {
  rsh 'echo "OK $(hostname) $(uname -sm) docker=$(command -v docker >/dev/null && echo yes || echo no)"'
}
