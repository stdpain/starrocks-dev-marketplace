---
description: Deploy and run a StarRocks cluster from a freshly built output/ on the remote dev host — start/stop/restart FE and BE, register the BE with the FE, check status, and run SQL to verify. Use after sr-build, or to bring up / tear down / inspect a running dev cluster. Triggers — "start the starrocks cluster", "deploy starrocks", "restart BE", "register backend", "show backends", "启动集群", "重启 FE".
---

# StarRocks Remote Deploy

Brings up and manages a single-node StarRocks dev cluster from
`$SR_SRC/output/{fe,be}` on the remote host (inside `SR_DOCKER` if configured),
using the connection from **sr-connect**. Talks to the FE over the MySQL protocol
to register the BE and verify health.

## Usage

```bash
bash scripts/deploy.sh up          # sync+config, start FE+BE, register BE, status  ← most common
bash scripts/deploy.sh config      # (re)write ports/conf into the run dir, then restart to apply
bash scripts/deploy.sh ports       # re-probe free ports & re-pin (after a conflict on a shared box)
bash scripts/deploy.sh start [all|fe|be]
bash scripts/deploy.sh stop  [all|fe|be]
bash scripts/deploy.sh restart [all|fe|be]     # re-syncs rebuilt binaries, then restarts
bash scripts/deploy.sh status      # run root + SHOW FRONTENDS / SHOW BACKENDS + process check
bash scripts/deploy.sh register    # ALTER SYSTEM ADD BACKEND (idempotent)
bash scripts/deploy.sh sql 'SHOW DATABASES'    # run arbitrary SQL via the FE
bash scripts/deploy.sh logs [fe|be]            # tail the FE/BE log
```

## Where it runs — `SR_DEPLOY_DIR`

- **Set** (e.g. `SR_DEPLOY_DIR=$HOME/sr-run`): `up`/`restart` sync the built
  `output/{fe,be}` binaries into it and run the cluster from there. `meta`,
  `storage`, and `log` live under the deploy dir, so `build.sh --clean` or a
  rebuild of `output/` **never wipes your data**. Conf is copied once and then
  managed in place (not clobbered on re-sync).
- **Unset**: runs in-place from `$STARROCKS_HOME/output` (data under `output/`).

`meta_dir` / `storage_root_path` aren't hardcoded — they follow `STARROCKS_HOME`,
which the start scripts set to the run dir, so they always land beside the binaries.

## Host vs container — `SR_DEPLOY_IN_DOCKER`

When `SR_DOCKER` is set (you build in the dev-env container), `up` runs the cluster
inside that container by default (`SR_DEPLOY_IN_DOCKER=1`). Set
**`SR_DEPLOY_IN_DOCKER=0` to run the cluster directly on the HOST** while still
building in the container: the host source path becomes `STARROCKS_HOME` and every
lifecycle command runs on the host. Prefer host-run on a normal dev box — the
cluster survives a container rebuild and FE/BE bind the host's real NIC. (The BE
binary built in an Ubuntu dev-env runs fine on an Ubuntu host; check with
`ldd output/be/lib/starrocks_be` if unsure.)

## Ports on a shared box — `SR_AUTO_PORTS`

This is a mixed-use dev host, so the StarRocks default ports are often already
taken. With **`SR_AUTO_PORTS=1` (default)**, `up`/`config` probe the remote (in the
same network namespace the cluster runs in — inside the container when `SR_DOCKER`
is set) and bump each port to the next free one, starting from the configured
value. The chosen set is **pinned** to `<run-dir>/.sr-ports.env`, so every later
`start`/`restart`/`status`/`sql` reuses the *same* ports — they don't drift.

- Re-probe after a new conflict: `bash scripts/deploy.sh ports` (or
  `SR_REASSIGN_PORTS=1 bash scripts/deploy.sh up`), then `restart`.
- Pin exact ports instead (no probing): set `SR_AUTO_PORTS=0`.
- `status` prints the live ports and the `mysql -P<port>` line to connect.

## Config (extends sr-connect's config.env; all optional, sane defaults)

```
SR_DEPLOY_DIR=            # run from here instead of output/ (recommended for persistence)
SR_DEPLOY_IN_DOCKER=      # 0 = run cluster on host, 1 = in container (default if SR_DOCKER set)
SR_MYSQL_HOST=127.0.0.1   # FE host as seen from where mysql runs
SR_BE_HOST=               # EMPTY => remote `hostname -i` (correct default); avoid 127.0.0.1
SR_PRIORITY_NET=          # EMPTY => auto-pin FE+BE to the real NIC on multi-NIC hosts
SR_AUTO_PORTS=1           # 1: auto-pick free ports from the values below; 0: use them as-is

# Port search starts (StarRocks defaults)
SR_QUERY_PORT=9030  SR_HTTP_PORT=8030  SR_RPC_PORT=9020  SR_EDIT_LOG_PORT=9010
SR_BE_PORT=9060     SR_BE_HTTP_PORT=8040  SR_BE_HEARTBEAT=9050  SR_BE_BRPC_PORT=8060
```

The resolved ports are written into `fe.conf`/`be.conf` by `up`/`config` as a
managed block after a `# === starrocks-dev (managed) ===` marker — re-running
strips and rewrites only that block, so manual conf edits above it are kept.

## What `up` does

1. `prepare` — sync binaries into `SR_DEPLOY_DIR` (if set), resolve free ports
   (auto, pinned), and write the port block into `fe.conf`/`be.conf`.
2. `start_be.sh --daemon` then `start_fe.sh --daemon` from the run dir.
3. Waits for the FE query port to accept MySQL connections.
4. `register` — `SHOW BACKENDS`; if the BE (at `<be_host>:$SR_BE_HEARTBEAT`, where
   `be_host` defaults to the remote `hostname -i`) isn't present, `ALTER SYSTEM ADD
   BACKEND "..."`. Safe to run repeatedly.
5. `verify_be` — waits for the BE to go `Alive`; if it doesn't, reads `be.WARNING`,
   and on the classic host-mismatch (`not equal to backend localhost <ip>`) it
   auto-drops the wrong backend and re-adds it under the BE's real self-detected IP.
6. `status` — prints the run root, `SHOW FRONTENDS` / `SHOW BACKENDS`, and `Alive`.

## Key facts

- Start/stop scripts: `output/fe/bin/{start_fe,stop_fe}.sh`,
  `output/be/bin/{start_be,stop_be}.sh`; `--daemon` backgrounds them.
- Config files: `output/fe/conf/fe.conf`, `output/be/conf/be.conf`. Default meta
  dir is `output/fe/meta`, default BE storage is `output/be/storage` — both created
  on first start.
- Logs: `output/fe/log/fe.{out,log,warn.log}`, `output/be/log/be.{out,INFO}`.
- A BE only becomes `Alive` after it's registered with the FE — a fresh cluster
  shows the BE down until `register` runs. That's expected, not a failure.
- The registered BE address MUST equal the IP the BE detects for itself (its
  priority-network pick == `hostname -i`); otherwise the FE heartbeat is rejected
  (`not equal to backend localhost <ip>`) and the BE stays `Alive=false`. `up`
  defaults the address correctly and `verify_be` self-heals a mismatch — only set
  `SR_BE_HOST` explicitly if you need a specific NIC.
- On a multi-NIC host (real NIC + docker0) the FE can pick `172.17.0.1` while the BE
  picks the real NIC — they'd never agree. With `SR_PRIORITY_NET` empty, `up`/`config`
  auto-derive the real-NIC CIDR and pin both FE and BE to it. `hostname` is used for
  detection (works in a container and on a host); `ip(8)` only refines the netmask
  when present.
- Default credentials: user `root`, empty password.

## Notes for the agent

- First start of the FE can take 20–40s to elect itself leader before the query
  port answers — `up`/`status` poll for it; don't declare failure early.
- If the FE process is up but the port never opens, read `logs fe` — a port
  conflict or bad `priority_networks` (multi-NIC host) is the usual cause; fix it
  in `output/fe/conf/fe.conf` via `sr-connect`'s `sr.sh --src` and restart.
- **Ports are handled for you**: `SR_AUTO_PORTS=1` probes and pins free ports, so
  on this shared box you normally don't touch them. If a start still races and
  loses a port, run `deploy.sh ports` then `restart`. Only set explicit ports +
  `SR_AUTO_PORTS=0` when something external must reach the cluster on fixed ports.
- For OTHER conf knobs (memory limits, feature flags), edit `fe.conf`/`be.conf`
  *above* the managed marker via `sr.sh --src`, then `deploy.sh restart` — your
  edits are preserved.
- This deploys a **single-node dev cluster**. Multi-BE / multi-FE topologies are
  out of scope — register additional BEs manually with `deploy.sh sql 'ALTER SYSTEM ADD BACKEND "..."'`.
