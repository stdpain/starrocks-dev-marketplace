#!/usr/bin/env bash
# Build StarRocks on the remote dev host. All args pass through to ./build.sh,
# with -j resolved from SR_JOBS or remote nproc, and BUILD_TYPE from env/SR_BUILD_TYPE.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

# Ensure the dev-env container exists/runs (pulls image + creates it if needed).
sr_ensure_docker

# Resolve job count.
jobs="${SR_JOBS:-}"
if [[ -z "$jobs" ]]; then
  jobs=$(rsrc 'nproc 2>/dev/null || echo 4' | tr -d '[:space:]')
  [[ "$jobs" =~ ^[0-9]+$ ]] || jobs=4
fi

build_type="${BUILD_TYPE:-$SR_BUILD_TYPE}"

# Is the backend (C++) part of this build? No target flag = both FE+BE; --be = BE;
# --fe alone = FE only (skip the BE-cache check).
be_targeted=1
if [[ " $* " == *" --fe "* && " $* " != *" --be "* ]]; then be_targeted=0; fi

# A BE CMakeCache from a previous mount path or a different dev-env toolchain points
# at a source dir / compiler that no longer exists, and cmake aborts with a cryptic
# "CMakeCache directory is different" / "not a full path to an existing compiler".
# Detect that up front and reset only the stale build dir, so the user gets a clean
# reconfigure instead of a raw CMake error. Untouched when the cache is still valid.
if [[ "$be_targeted" == 1 ]]; then
  rsrc '
    shopt -s nullglob
    for cache in be/build_*/CMakeCache.txt; do
      d=$(dirname "$cache"); reason=""
      # (1) source tree moved (e.g. the container mount path changed)
      home=$(sed -n "s/^CMAKE_HOME_DIRECTORY:[^=]*=//p" "$cache" | head -1)
      if [ -n "$home" ] && [ "$home" != "$STARROCKS_HOME/be" ]; then reason="source dir moved to $home"; fi
      # (2) toolchain changed: any recorded compiler tool path no longer exists
      #     (catches a different dev-env image, e.g. old gcc-toolset-10 paths)
      if [ -z "$reason" ]; then
        while IFS= read -r tool; do
          [ -n "$tool" ] && [ ! -e "$tool" ] && { reason="toolchain changed ($tool gone)"; break; }
        done < <(sed -n "s/^CMAKE_\(C\|CXX\)_COMPILER[A-Z_]*:FILEPATH=//p" "$cache")
      fi
      if [ -n "$reason" ]; then echo "starrocks-dev: resetting stale BE cmake cache $d — $reason"; rm -rf "$d"; fi
    done'
fi

# Prebuilt mold linker. When SR_MOLD is set the install prefix is bind-mounted at
# /opt/mold (see sr_ensure_docker). For a BE build, put mold's bin on PATH, make sure
# an `ld.mold` executable exists there (what `-fuse-ld=mold` looks up), and export
# STARROCKS_LINKER=mold so be/CMakeLists.txt emits `-fuse-ld=mold`.
#
# We resolve the linker on the HOST and set it EXPLICITLY in the container: the
# dev-env image itself exports STARROCKS_LINKER=lld, so a container-side `:-mold`
# default would never win. Setting SR_MOLD is an explicit opt-in to mold, so mold
# is forced — unless the user overrides per-invocation with STARROCKS_LINKER=<x>.
# FE-only builds skip this entirely.
mold_prelude=""
if [[ -n "${SR_MOLD:-}" && "$be_targeted" == 1 ]]; then
  mold_linker="${STARROCKS_LINKER:-mold}"
  mold_prelude="
    mold_bin=
    for c in /opt/mold/bin/mold /opt/mold/mold /opt/mold; do
      [ -x \"\$c\" ] && [ -f \"\$c\" ] && { mold_bin=\"\$c\"; break; }
    done
    [ -z \"\$mold_bin\" ] && mold_bin=\$(find /opt/mold -maxdepth 4 -type f -name mold -perm -u+x 2>/dev/null | head -1)
    if [ -n \"\$mold_bin\" ]; then
      mold_dir=\$(dirname \"\$mold_bin\")
      export PATH=\"\$mold_dir:\$PATH\"
      # -fuse-ld=mold resolves an executable named ld.mold on PATH.
      command -v ld.mold >/dev/null 2>&1 || ln -sf \"\$mold_bin\" \"\$mold_dir/ld.mold\" 2>/dev/null || ln -sf \"\$mold_bin\" /usr/local/bin/ld.mold 2>/dev/null || true
      export STARROCKS_LINKER='$mold_linker'
      echo \"starrocks-dev: BE linker = \$STARROCKS_LINKER (mold at \$mold_bin)\" >&2
    else
      echo \"starrocks-dev: WARNING SR_MOLD set but no mold binary found under /opt/mold — using default linker\" >&2
    fi
    "
fi

# Pass user args verbatim; quote each for the remote shell.
passthru=""
for a in "$@"; do passthru+=" $(printf '%q' "$a")"; done

sr_log "building on $(sr_target) [BUILD_TYPE=$build_type -j$jobs]${SR_DOCKER:+ in container $SR_DOCKER}${SR_MOLD:+ mold=$SR_MOLD}: ./build.sh${passthru}"

rsrc "${mold_prelude}export BUILD_TYPE='$build_type'; ./build.sh -j $jobs${passthru}"
rc=$?

if [[ $rc -eq 0 ]]; then
  sr_log "build OK. Artifacts:"
  rsrc 'out="${STARROCKS_OUTPUT:-$STARROCKS_HOME/output}"; ls -d "$out"/fe "$out"/be 2>/dev/null; du -sh "$out"/fe "$out"/be 2>/dev/null'
else
  sr_die "build failed (exit $rc). Re-read the compiler output above; if it is a toolchain/thirdparty error run sr-connect doctor.sh."
fi
