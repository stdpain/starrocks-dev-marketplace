---
description: Register and operate named BENCHMARK / test clusters — long-lived StarRocks clusters you reach THROUGH a jump host (a dedicated jumpserver or the sr-connect dev host), log into with a SHARED account+password kept in env vars (never on disk), and that sometimes get SUSPENDED so their FE/BE must be ssh'd into and started back up. You register a cluster once (FE host/port, jump, node inventory + StarRocks homes, credential VAR names) and then refer to it by name: connect + health-check, run SQL, ssh to nodes, and `wake` downed FE/BE. Builds on the sr-inspect/sr-rollout live-cluster layer; credentials are read from SR_BENCH_USER / SR_BENCH_PASS at run time. Triggers — "add a benchmark cluster", "连上 benchmark 集群", "这个测试集群被 suspend 了把 FE/BE 拉起来", "wake the benchmark cluster", "register the tpch test cluster", "通过跳板机连基准测试集群", "list my benchmark clusters".
---

# StarRocks Benchmark Clusters

A **benchmark cluster** is a long-lived test cluster you hit again and again — unlike the
one-off `--conn` strings of **sr-inspect**/**sr-rollout**, you **register it once by name**
and then refer to it. Three things make these clusters special, and this skill handles all
three:

1. **Reached through a jump.** You can only log in via a **jumpserver/bastion** *or* the
   **dev host**. Every `mysql`/`ssh` runs on that jump (over a reused SSH ControlMaster),
   which reaches the cluster's FE/BE.
2. **Shared account+password, from env vars.** The same account+password usually opens the
   MySQL FE *and* every node's SSH. It lives **only in your environment** (`SR_BENCH_USER` /
   `SR_BENCH_PASS`); the registry stores the **variable names**, never the secret.
3. **They get suspended.** Cloud test boxes get suspended/resumed, so the FE/BE processes are
   often down even when the host is back. `wake` ssh's to each node and starts whatever is
   down — which is why the registry stores the **node inventory + StarRocks home** per cluster
   (when the FE is down you can't `SHOW BACKENDS` to discover them).

## Credentials — export once per session, never stored

```bash
export SR_BENCH_USER=root         # the shared login account
export SR_BENCH_PASS='…'          # the shared password (MySQL FE + node SSH)
```

The registry files under `~/.config/starrocks_dev/bench/<name>.env` (chmod 600) hold only
topology + the *names* of these env vars. A cluster can point at different var names
(`--user-var`/`--pass-var`) if it doesn't use the shared pair.

## Register a cluster

```bash
S=plugins/starrocks-dev/skills/sr-bench/scripts/bench.sh

# dedicated jumpserver, multi-node; FE node also runs on the FE host
bash $S add tpch \
  --fe 10.0.0.21 --port 9030 \
  --jump ops@bastion01 \
  --fe-nodes 10.0.0.21=/data/StarRocks/fe \
  --be-nodes '10.0.0.22,10.0.0.23,10.0.0.24' --be-home /data/StarRocks/be

# reachable from the sr-connect dev host instead of a bastion → just omit --jump
bash $S add ssb --fe 10.1.0.5 --be-nodes '10.1.0.6,10.1.0.7' --be-home /opt/sr/be
```

`add` errors if the name exists; use `set` to change fields, `rm` to delete. Node lists are
comma/space separated; each entry is `host` or `host=/starrocks/home` (the `=home` overrides
`--fe-home`/`--be-home` for that node).

## Use a cluster

```bash
bash $S ls                       # all registered clusters (FE, jump, node counts)
bash $S show tpch                # stored fields + whether $SR_BENCH_USER/PASS are set
bash $S tpch                     # = conn: reachability + current_version() + FRONTENDS/BACKENDS
bash $S status tpch              # conn + a per-node FE/BE process check (up / DOWN)
bash $S wake tpch                # ssh to each node, start any FE/BE that is down (FEs first)
bash $S wake tpch be             # only BEs (or: wake tpch fe)
bash $S sql tpch 'SHOW BACKENDS'
bash $S ssh tpch 10.0.0.22 'df -h /data; free -h'
```

Typical flow after a suspend: `conn` (or `status`) says NOT reachable / FE down → `wake` →
`conn` again to confirm version + all nodes Alive.

## Hand off to sr-inspect / sr-rollout

`env <name>` prints `export SR_CL_*` lines (referencing the cred vars, so **no secret is
echoed**) — `eval` them, then drive the live-cluster skills against the registered cluster,
jump and all:

```bash
eval "$(bash $S env tpch)"
bash ../sr-inspect/scripts/diag.sh explain 'SELECT ...'              # profiles, jstack/pstack, logs
SR_PROFILE=myfeat bash ../sr-rollout/scripts/rollout.sh plan         # roll a build onto it
SR_PROFILE=myfeat bash ../sr-rollout/scripts/rollout.sh --parallel apply --yes  # all BEs at once
```

Benchmark clusters often have many BE nodes, so `sr-rollout --parallel` (all BEs at once)
or `--jobs N` updates them concurrently instead of one-by-one — much faster, and the brief
simultaneous BE downtime is acceptable on a test cluster. FEs still roll sequentially.

This works because **sr-bench, sr-inspect and sr-rollout share `scripts/srcluster.sh`**, which
now understands an optional `SR_CL_JUMP` (dedicated bastion). With it unset the live-cluster
skills behave exactly as before, running on the sr-connect dev host.

## Commands

| Command | What it does |
|---|---|
| `add <name> [flags]` | Register a new cluster (fails if it exists). `--fe` is required. |
| `set <name> [flags]` | Update fields of an existing cluster (only the flags you pass). |
| `ls` / `show <name>` / `rm <name>` | List / inspect (with cred-var status) / delete. |
| `conn <name>` (default) | Reachability probe + `current_version()` + `SHOW FRONTENDS/BACKENDS`. |
| `status <name>` | `conn` plus a per-node FE/BE process check (up / DOWN). |
| `wake <name> [fe\|be\|all]` | SSH to each node, start any down FE/BE. FEs first, then BEs. |
| `sql <name> '<SQL>'` | Run SQL on the cluster. |
| `ssh <name> <node> '<cmd>'` | Shell on a node, through the jump. |
| `env <name>` | Print `export SR_CL_*` lines for sr-inspect/sr-rollout (no secret printed). |

## add / set flags

`--fe <host>` (required) · `--port` (9030) · `--http-port` (8030) · `--db` · `--jump
user@host[:port]` (omit → use the sr-connect dev host) · `--jump-key <path>` (else the shared
password reaches the jump via `sshpass`) · `--user-var` (SR_BENCH_USER) · `--pass-var`
(SR_BENCH_PASS) · `--mysql-user` · `--ssh-user` · `--ssh-port` (22) · `--sudo`/`--no-sudo` ·
`--fe-nodes`/`--be-nodes` (comma/space list of `host` or `host=/home`) · `--fe-home`/`--be-home`.

## Notes for the agent

- **Prerequisite when no `--jump`:** the cluster must be reachable from the **sr-connect dev
  host** (`SR_HOST`) — run sr-connect setup first. With a dedicated `--jump`, the dev host
  isn't involved; the jump is reached with a key (`--jump-key`) or the shared password (needs
  `sshpass` **on your local machine**).
- **`wake` starts FE/BE as the SSH login user, never under sudo** — a root-started process
  leaves root-owned `*.pid` files that brick the next normal restart (the same trap
  sr-rollout warns about). The shared account should therefore be the StarRocks **service
  user**. `--sudo` only affects the process check / log peek, not the start.
- **`wake` needs the node inventory** (`--fe-nodes`/`--be-nodes` + homes). It deliberately
  does *not* discover nodes via `SHOW BACKENDS`, because after a suspend the FE itself is
  usually down. If a `wake` says "no bin/start_*.sh", the stored home is wrong — fix it with
  `set --*-home`.
- **Secrets stay in env.** The registry never contains a password. `show` masks the password
  as `***set***`; `env` emits `"$SR_BENCH_PASS"` references, not the value; `conn` masks it
  as `-p***`. Prefer exporting the vars once over inlining secrets on the command line.
- **"NOT reachable" usually means suspended.** If `conn`'s probe fails or the FE won't answer,
  the cluster is very likely suspended — run `wake` before assuming the host/port is wrong.
- For deep perf/correctness work (EXPLAIN ANALYZE, query profiles, jstack/pstack) use the
  `env <name>` → sr-inspect bridge above rather than duplicating those here.
