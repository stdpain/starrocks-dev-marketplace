---
description: Connect to a LIVE StarRocks cluster THROUGH the dev host using a mysql connection string you provide, and inspect it for performance/correctness. You give a connection string like `mysql -h host -P 9030 -u user -ppw`; the skill parses it, connects via the dev host (which can reach the cluster), and runs SQL/EXPLAIN ANALYZE/query profiles plus jstack (FE) / pstack (BE) / logs / system metrics on cluster nodes over SSH. Connection params are passed per-invocation (nothing stored); node access uses a fixed ssh account+password (+sudo). Requires sr-connect to have configured the dev host. Triggers — "connect to this starrocks cluster with this connection string", "use this mysql -h ... to diagnose the cluster", "查这个集群", "用这个连接串连上集群排查", "通过开发机连这个集群", "jstack the FE / pstack the BE".
---

# StarRocks Live-Cluster Inspect

You hand it a **mysql connection string**; it connects to that **already-running**
cluster **through the dev host** and inspects it for performance or correctness issues.
(For the dev cluster you build with sr-deploy, use that skill — this one is for an
external test/staging/customer cluster.)

**You provide the connection string.** Pass it with `--conn`, e.g.
`--conn 'mysql -h 10.0.0.21 -P 9030 -uroot -psecret'`. The skill parses out the host,
port, user, password and database — both `-h10.0.0.21` and `-h 10.0.0.21` forms, the
`--host=`/`--port=`/`--user=`/`--password=`/`--database=` long forms, and a bare
trailing db name. (Passwords with spaces: use `--password` instead.)

**Topology — the dev host is the jump.** The cluster is reachable from the dev host
configured by **sr-connect** (`SR_HOST`), not necessarily from your laptop. So every
`mysql` / `curl` / `ssh` this skill runs is executed **on the dev host** over the
existing SSH ControlMaster — the connection string is interpreted from there. The dev
host already has the needed tools (`mysql`, `sshpass`, `curl`, `jstack`, `gdb`/`pstack`,
`nc`).

**Credentials — one-off, never stored.** The connection string and node-ssh creds are
passed per invocation; nothing is written to a config file. For convenience in a session
you may `export SR_CL_*` once (lives only in your shell):

```bash
export SR_CL_CONN='mysql -h 10.0.0.21 -P 9030 -uroot -psecret'
export SR_CL_SSH_USER=ops SR_CL_SSH_PASS=secret SR_CL_SUDO=1   # for node access
```

## Usage

```bash
C='mysql -h 10.0.0.21 -P 9030 -uroot -psecret'   # your connection string
bash scripts/diag.sh --conn "$C" conn                          # connect via dev host + reachability + FE/BE list
bash scripts/diag.sh --conn "$C" sql 'SHOW BACKENDS'
bash scripts/diag.sh --conn "$C" explain 'SELECT count(*) FROM t WHERE ...'
bash scripts/diag.sh --conn "$C" profile <query_id>            # query profile via FE HTTP
bash scripts/diag.sh --conn "$C" jstack --ssh-user ops --ssh-pass pw 10.0.0.10
bash scripts/diag.sh --conn "$C" pstack --ssh-user ops --ssh-pass pw --sudo 10.0.0.11
bash scripts/diag.sh --conn "$C" logs --ssh-user ops --ssh-pass pw 10.0.0.10 fe 500
bash scripts/diag.sh --conn "$C" ssh  --ssh-user ops --ssh-pass pw 10.0.0.11 'df -h; nproc'
bash scripts/diag.sh --conn "$C" sys  --ssh-user ops --ssh-pass pw 10.0.0.11
```

`conn` is the default command — `diag.sh --conn "$C"` alone connects and prints node health.

## Cluster source (precedence: `SR_CL_*` env < `--conn` string < explicit flag)

```
--conn '<string>'  a mysql connection string to parse           (SR_CL_CONN)  ← primary input
--fe <host>        override FE host (reachable FROM the dev host)(SR_CL_FE)
--port <p>         override MySQL query port                     (SR_CL_PORT, default 9030)
--user <u>         override MySQL user                           (SR_CL_USER, default root)
--password <pw>    override MySQL password (sent via MYSQL_PWD)  (SR_CL_PASSWORD)
--http-port <p>    FE HTTP port (for `profile`; not in the str)  (SR_CL_HTTP_PORT, default 8030)
--db <name>        override default database                     (SR_CL_DB)
```

## Node-SSH flags (for `ssh` / `jstack` / `pstack` / `logs` / `sys`)

```
--ssh-user <u>     ssh user on the cluster nodes            (SR_CL_SSH_USER)
--ssh-pass <pw>    ssh password — uses sshpass on dev host  (SR_CL_SSH_PASS)
--ssh-key <path>   ssh key instead of a password            (SR_CL_SSH_KEY)
--ssh-port <p>     node ssh port                            (SR_CL_SSH_PORT, default 22)
--sudo             run the node command under sudo          (SR_CL_SUDO=1)
```

`--sudo` assumes **passwordless** sudo for the ssh user (`sudo -n`). `pstack` needs
root (ptrace), so pass `--sudo` there. `jstack` auto-runs as the FE process owner via
`sudo -u <owner>` when possible.

## Commands

- **conn** (default) — connects to the cluster through the dev host using the parsed
  connection string: echoes the effective target, runs a `nc` reachability check from
  the dev host, then `SELECT current_version()` + `SHOW FRONTENDS/BACKENDS` so you
  immediately see whether the cluster is reachable and its nodes are healthy.
- **sql `'<SQL>'`** — runs SQL on the cluster (multiple `;`-separated statements ok;
  `\G` works). Use for `SHOW PROC`, `ADMIN SHOW CONFIG`, correctness spot-checks, etc.
- **explain `'<query>'`** — `EXPLAIN ANALYZE` (really executes the query) for the plan
  plus per-operator timing/rows — the first stop for a slow query. For the plan only,
  use `sql 'EXPLAIN <query>'`.
- **profile `<query_id>`** — fetches the full query profile from the FE HTTP API
  (`/query_profile/<id>`). Get the id from `sql 'SHOW PROFILELIST'`. If your version
  doesn't expose that endpoint, the command prints the SQL fallback to try.
- **ssh `<node> '<cmd>'`** — arbitrary shell on a node, hopping through the dev host.
- **jstack `<fe-node>`** — FE JVM thread dump (falls back to `kill -3` → `fe.out`).
- **pstack `<be-node>`** — all-thread C++ backtrace of `starrocks_be` (gdb, else pstack).
- **logs `<node> fe|be [lines]`** — tails `fe.log` / `be.INFO`, auto-located via the
  process's `/proc/<pid>/cwd`.
- **sys `<node>`** — uptime / mem / top / iostat snapshot for a quick resource read.

## Notes for the agent

- **Prerequisite:** sr-connect must be set up (a configured `SR_HOST`). This skill never
  connects from your laptop directly — it always goes dev host → cluster. If `conn`'s
  reachability line says NOT reachable, the cluster host/port is wrong or the dev host
  has no route to it; fix that before anything else.
- **Quoting is handled.** SQL text, passwords, and node commands are base64-wrapped end
  to end, so quotes / pipes / `$()` / newlines in your SQL or commands are safe.
- **Secrets in transcripts.** Prefer `export SR_CL_CONN=…` / `SR_CL_SSH_PASS=…` once over
  repeating the password-bearing connection string on every command line. `conn` masks
  the password as `-p***` in its output, never the real value.
- **Performance triage order:** `conn` (nodes alive?) → `sql 'SHOW PROC "/cluster_balance"'`
  / `SHOW BACKENDS` (skew, disk) → `explain` the slow query → `profile <id>` for the hot
  operator → `pstack`/`jstack` if a node is pegged or stuck → `sys`/`logs` for the box.
- **Correctness triage:** reproduce with `sql`, compare `explain` plans across sessions/
  versions, check `ADMIN SHOW CONFIG` and `SHOW VARIABLES` for a differing knob.
- This skill is **read-only by intent** — it runs whatever SQL/commands you give it, so
  don't hand it mutating SQL or node commands unless you mean to change the cluster.
- For reproducing/repro-building a crash on the DEV box from a stack trace, use
  **sr-diagnose** instead; this skill is for inspecting a live remote cluster.
