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

## Waiting for the build — don't blind-poll

A BE build takes minutes. **Rely on the wrapper's exit code / the background-task
completion notification — do NOT spawn an `until grep … ; do sleep ; done` loop to
watch the log.** Such loops auto-background, and if the grep pattern never matches
the wrapper's real output they spin forever and *look* like a hung/stuck task (the
classic symptom: the build finished with exit 0 long ago but a "waiter" task is
still alive). This has bitten us — the build was fine; the polling loop was the bug.

Do this instead:
- Launch with `run_in_background: true` and let the `<task-notification>`
  (with the real exit code) tell you it's done. That notification IS the signal.
- To peek at progress mid-run, just `Read` the output file once and stop — never loop.
- The wrapper's exit code is authoritative: **0 = success, non-zero = failure.**
  You normally don't need to grep at all.

Terminal markers the wrapper prints (both prefixed `starrocks-dev:`), if you must match:
- success → `starrocks-dev: build OK. Artifacts:`
- failure → `starrocks-dev: build failed (exit N).`

Note `./build.sh --be` runs make in **two passes** (compile, then a collect/install
pass that re-lists every `Built target …`), so a `[100%] Built target starrocks_be`
is **not** the end — wait for the `build OK` line or the exit code.

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
- Set `SR_CCACHE` (host dir, e.g. `$HOME/.ccache`) on the base config so the dev-env
  container mounts a **shared** ccache at `/root/.ccache`. The cache is namespaced per
  dev-env image and uses `hash_dir=false` + `CCACHE_BASEDIR=$SR_SRC`, so a new profile's
  worktree (a different source path) still hits the cache another profile warmed on the
  same image — instead of recompiling cold. Without `SR_CCACHE`, each profile's container
  has its own empty cache.
- Set `SR_MOLD` (host path to a **prebuilt mold** install prefix — the dir holding
  `bin/mold`) to link the BE with mold instead of the default gold linker. The install
  is bind-mounted read-only at `/opt/mold` when the container is created; for BE builds
  the wrapper puts mold on `PATH`, exposes an `ld.mold` executable, and exports
  `STARROCKS_LINKER=mold` so `be/CMakeLists.txt` emits `-fuse-ld=mold`. FE-only builds
  skip it. Because the mount is added at **container creation** time (like `SR_CCACHE`/
  `SR_M2`), a pre-existing container must be recreated to pick it up (`workspace.sh` for a
  profile, or `docker rm` the container so the next build recreates it). To override the
  linker for one build, pass `STARROCKS_LINKER=<x> bash scripts/build.sh --be`.
  **Gotcha:** `build.sh` sources `$STARROCKS_HOME/custom_env.sh` (via `env.sh`) *after*
  the wrapper sets `STARROCKS_LINKER`, so a line like `export STARROCKS_LINKER=""` in
  `custom_env.sh` silently overrides `SR_MOLD` (cmake then prints `using linker:` empty
  → default linker). If mold isn't taking effect, comment that line out. Verify with a
  cheap `--configure-only` run and look for `-- using linker: mold`.

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
