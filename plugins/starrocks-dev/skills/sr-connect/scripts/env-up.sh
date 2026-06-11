#!/usr/bin/env bash
# Bring up the remote Docker dev-env for building StarRocks: pull the image if
# missing, then create/start the container with the source mounted. Idempotent.
# No-op (with a hint) if SR_DOCKER is not configured — then you build on the host.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

if [[ -z "${SR_DOCKER:-}" ]]; then
  sr_log "SR_DOCKER is not set — no container to manage; builds run directly on the host."
  sr_log "To use a dev-env container, set SR_DOCKER / SR_IMAGE / SR_HOST_SRC / SR_SRC in $SR_CFG_FILE."
  exit 0
fi

sr_ensure_docker
sr_log "dev-env summary:"
rsh "docker ps --filter name='^${SR_DOCKER}$' --format '  {{.Names}}  {{.Image}}  {{.Status}}'"
sr_log "toolchain inside container:"
rsrc 'echo "  $(java -version 2>&1 | head -1)"; echo "  thirdparty=${STARROCKS_THIRDPARTY:-<image default unset>}"; echo "  src: $(pwd) -> $(git rev-parse --abbrev-ref HEAD 2>/dev/null)@$(git rev-parse --short HEAD 2>/dev/null)"'
