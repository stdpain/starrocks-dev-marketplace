---
description: Build StarRocks (FE/BE) on the remote dev host over SSH. Use to compile after editing source — full or incremental, FE-only, BE-only, or a single BE module — and to surface compile errors. Requires sr-connect to have configured the connection first. Triggers — "build starrocks", "compile FE/BE", "rebuild backend", "编译 starrocks", "build just the FE".
---

# StarRocks Remote Build

Compiles StarRocks on the remote dev host via `build.sh`, using the connection
configured by **sr-connect**. Runs inside the dev-env container when `SR_DOCKER`
is set. Output lands in `$SR_SRC/output/{fe,be}` on the remote.

Prefix `SR_PROFILE=<name>` to build a specific parallel profile (its own container
+ source worktree); two `SR_PROFILE=A …` / `SR_PROFILE=B …` builds run at once. See
sr-connect → **Parallel work** (`workspace.sh`).

## Usage

```bash
bash scripts/build.sh            # build both FE and BE (incremental)
bash scripts/build.sh --fe       # FE only (Java/Maven + Spark DPP)
bash scripts/build.sh --be       # BE only (C++/cmake)
bash scripts/build.sh --be --module storage   # one BE module (faster iteration)
bash scripts/build.sh --clean    # clean rebuild of the selected targets
```

Extra `build.sh` flags pass straight through, e.g.:
```bash
bash scripts/build.sh --be --without-pch          # skip precompiled headers
BUILD_TYPE=Asan bash scripts/build.sh --be        # ASan backend
```

## What the wrapper does

- Resolves parallelism: `-j $SR_JOBS` if set, else the remote `nproc`.
- Runs `sr_ensure_docker` first: if `SR_DOCKER` is set and the container is
  missing, it pulls `SR_IMAGE` and `docker run`s it with the source mounted
  (`SR_HOST_SRC` → `SR_SRC`) and `--ulimit nofile` raised — no manual setup needed.
- Exports `STARROCKS_HOME` (and `STARROCKS_THIRDPARTY` if configured) and runs
  `./build.sh` from `$SR_SRC` via `rsrc`, so it works equally inside the dev-env
  container or directly on the host.
- Honors `BUILD_TYPE` (env or `SR_BUILD_TYPE`: Release/Debug/Asan).
- Streams compiler output live and exits with `build.sh`'s real exit code.
- On success prints the resulting artifact paths under `output/`.

## Key facts (verified against build.sh)

- Targets: `--fe`, `--be`, `--spark-dpp`, `--hive-udf`, `--format-lib`. No target
  flag → builds **both FE and BE**.
- Incremental by default; `--clean` forces a fresh build of the chosen targets.
- `--be --module <name>` builds a single backend module — much faster when
  iterating on one area.
- Output dir is `${STARROCKS_OUTPUT:-$STARROCKS_HOME/output}` → `output/fe`,
  `output/be`. `sr-deploy` consumes exactly this.
- A first-ever BE build is slow (full C++ + thirdparty linkage); `ccache` makes
  subsequent builds far faster — `sr-connect doctor.sh` reports whether it's present.

## Notes for the agent

- If the build fails on a missing toolchain or unbuilt `STARROCKS_THIRDPARTY`,
  stop and run `sr-connect doctor.sh` — don't retry the build blindly.
- A stale `be/build_*` CMake cache (left by a different mount path or dev-env image)
  is auto-detected and reset before the BE build — you'll see `resetting stale BE
  cmake cache …`. This is normal after switching container/image; the BE just
  reconfigures from scratch (ccache keeps the recompile fast). No manual `--clean`.
- For a tight edit→compile loop on the backend, prefer `--be --module <name>`
  over a full `--be`.
- After a successful build, hand off to **sr-deploy** to start/restart the cluster.
- FE-only changes don't need a BE rebuild and vice-versa — build only what changed.
