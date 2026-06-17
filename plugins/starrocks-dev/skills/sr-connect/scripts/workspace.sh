#!/usr/bin/env bash
# Manage parallel work profiles. Each profile is an INDEPENDENT build/deploy task —
# its own dev-env container, its own git worktree of the source, its own deploy dir
# and (auto-allocated) ports — so several features compile and run side by side:
#
#     bash scripts/workspace.sh create featA --branch feature/a
#     bash scripts/workspace.sh create featB --branch feature/b
#     SR_PROFILE=featA bash ../../sr-build/scripts/build.sh &   # two docker builds
#     SR_PROFILE=featB bash ../../sr-build/scripts/build.sh &   # in parallel
#
# A profile inherits the DEFAULT profile's connection + image + cache settings and
# overrides only what must differ (container name, source worktree, deploy dir).
# Because SR_M2 / SR_CCACHE are inherited, every profile's container mounts the same
# Maven + ccache caches (ccache namespaced per image), so a new profile's first build
# reuses the existing warm cache instead of starting cold.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# Always operate on the BASE (default) profile here: this script CREATES profiles,
# so it must read the default config for connection/image and write under profiles/.
unset SR_PROFILE
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

PROFILES_DIR="$SR_CFG_BASE/profiles"

usage() {
  cat >&2 <<'EOF'
usage: workspace.sh <command>
  list                               list the default profile + all named profiles
  create <name> [opts]               scaffold a profile: git worktree + config.env
      --branch <b>     branch to check out in the worktree (created off --base if new;
                       default: a new branch named <name>)
      --base <ref>     base ref for a newly created branch (default: current HEAD)
      --src <path>     host path for the worktree (default: <SR_WS_ROOT or $HOME/sr-ws>/<name>)
      --container <c>  container name        (default: sr-dev-<name>)
      --image <img>    dev-env image to pin  (default: inherit the base profile's SR_IMAGE)
      --deploy <dir>   deploy/run dir        (default: <base SR_DEPLOY_DIR>/<name>, else in-place)
  rm <name> [--keep-src] [--keep-container]
                       remove the profile config; also git-worktree-remove its source
                       and `docker rm -f` its container unless --keep-* is given
Profiles are then used by every skill via the SR_PROFILE env var, e.g.
  SR_PROFILE=<name> bash scripts/doctor.sh
EOF
  exit "${1:-2}"
}

# Read a single key out of a config.env file without sourcing it into our env.
cfg_get() { sed -n "s/^$2='\(.*\)'\$/\1/p" "$1" 2>/dev/null | tail -1; }

cmd_list() {
  echo "── default (SR_PROFILE unset) ──"
  if [[ -f "$SR_CFG_BASE/config.env" ]]; then
    printf '  host=%s docker=%s src=%s deploy=%s\n' \
      "$(cfg_get "$SR_CFG_BASE/config.env" SR_HOST)" \
      "$(cfg_get "$SR_CFG_BASE/config.env" SR_DOCKER)" \
      "$(cfg_get "$SR_CFG_BASE/config.env" SR_HOST_SRC)" \
      "$(cfg_get "$SR_CFG_BASE/config.env" SR_DEPLOY_DIR)"
  else
    echo "  (not configured — run setup.sh)"
  fi
  echo "── profiles ──"
  local found=0 d name f
  for d in "$PROFILES_DIR"/*/; do
    [[ -d "$d" ]] || continue
    f="$d/config.env"; [[ -f "$f" ]] || continue
    name=$(basename "$d"); found=1
    printf '  %-16s docker=%s src=%s deploy=%s\n' "$name" \
      "$(cfg_get "$f" SR_DOCKER)" "$(cfg_get "$f" SR_HOST_SRC)" "$(cfg_get "$f" SR_DEPLOY_DIR)"
  done
  [[ "$found" == 1 ]] || echo "  (none — create one with: workspace.sh create <name>)"
}

cmd_create() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || usage
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || sr_die "invalid profile name '$name' (use letters, digits, . _ -)"
  local branch="" base="" ws_src="" container="" deploy="" image=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)    branch="$2"; shift 2 ;;
      --base)      base="$2"; shift 2 ;;
      --src)       ws_src="$2"; shift 2 ;;
      --container) container="$2"; shift 2 ;;
      --image)     image="$2"; shift 2 ;;
      --deploy)    deploy="$2"; shift 2 ;;
      *) sr_die "unknown option '$1'" ;;
    esac
  done

  local cfg="$PROFILES_DIR/$name/config.env"
  [[ -e "$cfg" ]] && sr_die "profile '$name' already exists ($cfg). Remove it first: workspace.sh rm $name"
  [[ -n "${SR_HOST:-}" ]] || sr_die "no default config — run setup.sh first so a profile can inherit the connection."

  # Main source tree on the host = the default profile's worktree root.
  sr_resolve_host_src
  local main_src="$SR_HOST_SRC"
  rsh "git -C '$main_src' rev-parse --is-inside-work-tree >/dev/null 2>&1" \
    || sr_die "$main_src is not a git work tree on the remote — cannot add a worktree."

  branch="${branch:-$name}"
  if [[ -z "$ws_src" ]]; then
    local ws_root; ws_root="${SR_WS_ROOT:-$(sr_remote_home)/sr-ws}"
    ws_src="$ws_root/$name"
  fi
  while [[ "$ws_src" == *//* ]]; do ws_src="${ws_src//\/\//\/}"; done   # collapse // (cosmetic)
  container="${container:-sr-dev-$name}"
  if [[ -z "$deploy" ]]; then
    local base_deploy; base_deploy=$(cfg_get "$SR_CFG_BASE/config.env" SR_DEPLOY_DIR)
    [[ -n "$base_deploy" ]] && deploy="$base_deploy/$name"   # else empty => run in-place from the worktree's output/
  fi

  sr_log "creating worktree on remote: $ws_src  (branch $branch)"
  rsh "set -e
    cd '$main_src'
    if [ -e '$ws_src' ]; then echo 'starrocks-dev: $ws_src already exists, reusing as worktree' >&2;
      git worktree add '$ws_src' '$branch' 2>/dev/null || true
    elif git show-ref --verify --quiet 'refs/heads/$branch'; then
      git worktree add '$ws_src' '$branch'
    else
      git worktree add -b '$branch' '$ws_src' ${base:+'$base'}
    fi" || sr_die "git worktree add failed (branch '$branch' off '${base:-HEAD}'). Check the branch/base exist on the remote."

  # A git worktree's .git is a FILE pointing at the main repo's
  # .git/worktrees/<name> (an absolute HOST path), and that dir back-points to the
  # worktree's own absolute path. For git to work INSIDE the dev-env container both
  # absolute paths must resolve there too. So for a containerized profile we:
  #   (1) mount the worktree at the SAME path inside the container (SR_SRC=ws_src),
  #       not the default /root/starrocks — otherwise the worktree<->gitdir backlink
  #       mismatches and git reports "not a git repository";
  #   (2) bind-mount the main repo's shared .git (its git-common-dir) at its own host
  #       path, so .git/worktrees/<name> + the object DB are visible in the container.
  # Without this, build.sh's git version-stamping fails inside the container.
  local gitcommon=""
  if [[ -n "$container" ]]; then
    gitcommon=$(rsh "cd '$main_src' && readlink -f \"\$(git rev-parse --git-common-dir)\"" 2>/dev/null)
    [[ -n "$gitcommon" ]] || sr_die "could not resolve git-common-dir for $main_src"
  fi

  # Scaffold the profile config: start from the env (which srlib loaded from the
  # default config), override the per-task keys, then write via the shared writer.
  mkdir -p "$PROFILES_DIR/$name"
  SR_DOCKER="$container"
  SR_HOST_SRC="$ws_src"
  if [[ -n "$container" ]]; then
    SR_SRC="$ws_src"                                            # see (1) above
    # Stored unquoted: sr_write_config wraps the whole value in single quotes, and
    # sr_ensure_docker word-splits it into the docker-run line (like '--network host').
    local gitmount="-v $gitcommon:$gitcommon"                   # see (2) above
    case " ${SR_DOCKER_RUN_OPTS:-} " in
      *" $gitmount "*) ;;                                       # already present
      *) SR_DOCKER_RUN_OPTS="${SR_DOCKER_RUN_OPTS:+$SR_DOCKER_RUN_OPTS }$gitmount" ;;
    esac
  fi
  SR_DEPLOY_DIR="$deploy"
  # Pin a specific dev-env image for this profile (e.g. an OS-matched centos/ubuntu image);
  # otherwise inherit the base profile's SR_IMAGE. sr_ensure_docker pulls/creates from it.
  [[ -n "$image" ]] && SR_IMAGE="$image"
  SR_AUTO_PORTS="${SR_AUTO_PORTS:-1}"   # keep auto-ports so this cluster avoids the others'
  sr_write_config "$cfg"
  sr_log "wrote $cfg"
  cat >&2 <<EOF
starrocks-dev: profile '$name' ready.
  container : $container   (created on first build)
  image     : ${SR_IMAGE:-<inherited default>}
  source    : $ws_src   (branch $branch, shares .git with $main_src)
  deploy    : ${deploy:-<in-place from worktree output/>}
  ports     : auto-allocated on first deploy (won't collide with other profiles)
Use it:
  SR_PROFILE=$name bash $PLUGIN_ROOT/skills/sr-connect/scripts/doctor.sh
  SR_PROFILE=$name bash $PLUGIN_ROOT/skills/sr-build/scripts/build.sh
EOF
}

cmd_rm() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || usage
  local keep_src=0 keep_container=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-src)       keep_src=1; shift ;;
      --keep-container) keep_container=1; shift ;;
      *) sr_die "unknown option '$1'" ;;
    esac
  done
  local cfg="$PROFILES_DIR/$name/config.env"
  [[ -f "$cfg" ]] || sr_die "no such profile '$name' ($cfg not found)."

  local container src img
  container=$(cfg_get "$cfg" SR_DOCKER)
  src=$(cfg_get "$cfg" SR_HOST_SRC)
  img=$(cfg_get "$cfg" SR_IMAGE)

  if [[ "$keep_container" == 0 && -n "$container" ]]; then
    sr_log "removing container $container ..."
    rsh "docker rm -f '$container' >/dev/null 2>&1 || true"
  fi
  if [[ "$keep_src" == 0 && -n "$src" ]]; then
    sr_log "removing git worktree $src ..."
    # Build artifacts inside the worktree are written by the dev-env container as
    # ROOT, so the host user usually can't delete them — a plain `git worktree
    # remove` / `rm -rf` fails with "Permission denied" and leaves several GB behind.
    # So: (1) capture the main repo's git dir up front to prune metadata afterwards;
    # (2) try a normal host-side worktree remove (fast path when nothing was built);
    # (3) if the tree survives, delete it AS ROOT via a throwaway dev-env container
    # (mount the parent, rm the dir); (4) prune the now-dangling worktree metadata.
    local parent gitcommon
    parent=$(dirname "$src")
    gitcommon=$(rsh "cd '$src' 2>/dev/null && readlink -f \"\$(git rev-parse --git-common-dir 2>/dev/null)\"" 2>/dev/null)
    rsh "git -C '$src' worktree remove --force '$src' 2>/dev/null || true"
    rsh "if [ -e '$src' ]; then
           [ -n '$img' ] && docker run --rm -v '$parent':'$parent' '$img' rm -rf '$src' >/dev/null 2>&1
           rm -rf '$src' 2>/dev/null || true
         fi"
    [[ -n "$gitcommon" ]] && rsh "git --git-dir='$gitcommon' worktree prune 2>/dev/null || true"
    rsh "[ -e '$src' ] && echo 'starrocks-dev: WARNING: could not fully remove $src — delete it manually as root' >&2 || true"
  fi
  rm -rf "$PROFILES_DIR/$name"
  local kept=""
  [[ "$keep_src" == 1 ]]       && kept+=" (kept source)"
  [[ "$keep_container" == 1 ]] && kept+=" (kept container)"
  sr_log "profile '$name' removed.$kept"
}

cmd="${1:-list}"; shift || true
case "$cmd" in
  list)   cmd_list ;;
  create) cmd_create "$@" ;;
  rm|remove) cmd_rm "$@" ;;
  -h|--help|help) usage 0 ;;
  *) sr_die "unknown command '$cmd' (use: list | create | rm)" ;;
esac
