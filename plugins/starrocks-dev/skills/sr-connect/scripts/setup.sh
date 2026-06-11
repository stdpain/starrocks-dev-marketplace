#!/usr/bin/env bash
# Write SR_* config to ~/.config/starrocks_dev/config.env, open the SSH
# ControlMaster, and print the remote identity. Idempotent / merging.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

# Persist every documented SR_* config key. srlib sources config.env, so any key
# NOT written here is silently lost on the next command — keep this list in sync
# with config.env.example. Merge semantics: srlib already loaded the existing file
# into the environment, so an unset key keeps its current value and any SR_* present
# in the environment (file value, or a one-off `SR_X=… bash setup.sh` override) is
# what gets written back.
KEYS=(
  # connection
  SR_HOST SR_USER SR_PORT SR_KEY SR_PROXY_JUMP SR_SRC
  # docker dev-env
  SR_DOCKER SR_IMAGE SR_HOST_SRC SR_NOFILE SR_M2 SR_DOCKER_RUN_OPTS
  # build
  SR_THIRDPARTY SR_JOBS SR_BUILD_TYPE
  # deploy
  SR_DEPLOY_DIR SR_DEPLOY_IN_DOCKER SR_MYSQL_HOST SR_BE_HOST SR_PRIORITY_NET SR_AUTO_PORTS
  SR_QUERY_PORT SR_HTTP_PORT SR_RPC_PORT SR_EDIT_LOG_PORT
  SR_BE_PORT SR_BE_HTTP_PORT SR_BE_HEARTBEAT SR_BE_BRPC_PORT
)

umask 077
tmp="$SR_CFG_FILE.tmp.$$"
{
  echo "# starrocks-dev config — written by sr-connect/setup.sh"
  for k in "${KEYS[@]}"; do
    v="${!k:-}"
    [[ -n "$v" ]] && printf "%s='%s'\n" "$k" "$v"
  done
} > "$tmp"
mv "$tmp" "$SR_CFG_FILE"
chmod 600 "$SR_CFG_FILE"
sr_log "wrote $SR_CFG_FILE"

[[ -n "${SR_HOST:-}" ]] || sr_die "SR_HOST not set. Pass it, e.g.: SR_HOST=dev01 SR_USER=root SR_SRC=/root/starrocks bash scripts/setup.sh"

sr_prime_known_hosts   # pre-trust jump host(s) + target so the first BatchMode connect won't fail on an unknown key

sr_log "testing connection to $(sr_target) ..."
if out=$(sr_conn_test); then
  sr_log "connected: $out"
else
  sr_die "could not connect to $(sr_target). Check, in order:
  - host key / jump host: ${SR_PROXY_JUMP:+via $SR_PROXY_JUMP — }try 'ssh ${SR_PROXY_JUMP:+-J $SR_PROXY_JUMP }$(sr_target)' once by hand to accept keys
  - auth: your key is authorized on the remote (ssh-add / ~/.ssh/config / SR_KEY)
  - reachability: SR_HOST/SR_PORT correct and the host is up"
fi
