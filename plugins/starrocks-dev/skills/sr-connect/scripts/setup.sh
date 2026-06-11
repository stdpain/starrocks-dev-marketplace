#!/usr/bin/env bash
# Write SR_* config to ~/.config/starrocks_dev/config.env, open the SSH
# ControlMaster, and print the remote identity. Idempotent / merging.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

# Persist every documented SR_* config key (the list + writer live in srlib so
# setup.sh and workspace.sh stay in sync). Merge semantics: srlib already loaded the
# existing file into the env, so an unset key keeps its current value and any SR_*
# present in the env (file value, or a one-off `SR_X=… bash setup.sh` override) is
# what gets written back. With SR_PROFILE=<name> set, SR_CFG_FILE points at that
# profile's config — so setup.sh edits the active profile, not always the default.
sr_write_config "$SR_CFG_FILE"
sr_log "wrote $SR_CFG_FILE${SR_PROFILE:+ (profile: $SR_PROFILE)}"

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
