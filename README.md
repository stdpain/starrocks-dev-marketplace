# starrocks-dev-marketplace

A Claude Code plugin marketplace for **remote StarRocks development over SSH**.
Claude runs locally and drives a remote dev host — editing, building, testing,
deploying, and debugging the StarRocks source tree that lives on that host
(optionally inside a `dev-env-ubuntu` container).

---

## The plugin: `starrocks-dev`

Seven composable skills sharing one SSH connection layer
(`plugins/starrocks-dev/scripts/srlib.sh`, plus `srcluster.sh` for live clusters):

| Skill | Stage | What it does |
|-------|-------|--------------|
| **sr-connect** | connection / env | Configure & verify SSH (direct or via jump host), bring up the Docker dev-env (pull image + mount source), check the remote toolchain/source, run ad-hoc remote commands. **Use first.** |
| **sr-build** | build | Compile FE (Maven) and BE (cmake) via `build.sh` — full, incremental, FE/BE-only, or a single module. |
| **sr-test** | test | FE / BE / Java-ext unit tests and SQL regression tests; single-class, gtest-filter, or single-module runs. |
| **sr-deploy** | deploy / run | Sync artifacts to a deploy dir, auto-pick free ports, start/stop/restart FE+BE, register the BE, run SQL to verify. |
| **sr-diagnose** | triage / repro | From a crash/stack/issue: locate the source, check if it's a known/fixed issue, and if not reproduce it (ASan build → trigger → capture) with exact steps. |
| **sr-inspect** | inspect | Connect to a **live** cluster through the dev host via a mysql connection string and inspect perf/correctness — SQL, EXPLAIN ANALYZE, query profiles, jstack/pstack/logs/sys on its nodes. |
| **sr-rollout** | rollout | Full-replace a **live** cluster's FE/BE binaries with a worktree profile's `output/`, node by node — OS-matched, with backup/rollback and Alive health-checks. |

Because these are **skills**, the usual way to use them is just to ask Claude in
plain language — *"connect to my starrocks dev box and build the BE"*, *"start the
cluster"*, *"reproduce this crash"* — and the matching skill triggers. The shell
commands below are the underlying primitives you (or Claude) can also run directly.

---

## How it works

- **Connection.** Plain SSH to one host, reusing an SSH **ControlMaster** socket so
  only the first command authenticates and the rest are instant for ~5 min. Jump
  hosts are supported via `SR_PROXY_JUMP` (or your `~/.ssh/config`).
- **Docker dev-env (optional).** If `SR_DOCKER` names a container, build/test/deploy
  run *inside* it. Missing container? It's created automatically — the image is
  pulled if absent and run with the source mounted and `--ulimit nofile` raised.
  Here `SR_SRC` is the path **inside** the container (e.g. `/root/starrocks`) and
  `SR_HOST_SRC` is the real path **on the host** (defaults to remote
  `$HOME/<basename SR_SRC>`); they're bind-mounted together.
- **Deploy.** With `SR_DEPLOY_DIR` set, built artifacts are synced there and the
  cluster runs from it, so `meta`/`storage` survive a rebuild. On a shared box,
  `SR_AUTO_PORTS=1` (default) probes free ports and **pins** them per cluster so
  restarts don't drift.

---

## Install

```text
/plugin marketplace add /home/public/starrocks-dev-marketplace
/plugin install starrocks-dev@starrocks-dev-marketplace
```

(Or point `/plugin marketplace add` at your clone/fork of this repo.)

---

## Configure

All skills read `~/.config/starrocks_dev/config.env` (chmod 600). Start from the
template:

```bash
cp plugins/starrocks-dev/config.env.example ~/.config/starrocks_dev/config.env
chmod 600 ~/.config/starrocks_dev/config.env
$EDITOR ~/.config/starrocks_dev/config.env
```

> Keep real hosts, registry addresses, internal paths, and keys **only** in that
> private file — never commit them. Any `SR_*` env var overrides the file, so you
> can also do `SR_HOST=foo bash scripts/...` for one-off targets.

### Key reference

| Key | Purpose | Default |
|-----|---------|---------|
| `SR_HOST` | hostname/IP or `~/.ssh/config` alias | — (required) |
| `SR_USER` | ssh user (omit if alias sets it) | — |
| `SR_PORT` | ssh port | `22` |
| `SR_KEY` | identity file | ssh default |
| `SR_PROXY_JUMP` | jump host `user@jump[:port]` (or `j1,j2`) | — |
| `SR_SRC` | source path the build uses (in-container if `SR_DOCKER`) | — (required) |
| `SR_DOCKER` | dev-env container name | — (host build if unset) |
| `SR_IMAGE` | dev-env image (private registry ok) | `starrocks/dev-env-ubuntu:latest` |
| `SR_HOST_SRC` | host source path to mount → `SR_SRC` | remote `$HOME/<basename SR_SRC>` |
| `SR_NOFILE` | container `ulimit nofile` | `655350` |
| `SR_M2` | host `~/.m2` to mount as `/root/.m2` | — |
| `SR_DOCKER_RUN_OPTS` | extra `docker run` opts (e.g. `--network host`) | — |
| `SR_THIRDPARTY` | `STARROCKS_THIRDPARTY` override | image default |
| `SR_JOBS` | build/test parallelism | remote `nproc` |
| `SR_BUILD_TYPE` | `Release`/`Debug`/`Asan` | `Release` |
| `SR_DEPLOY_DIR` | run cluster from here (persists data) | in-place `output/` |
| `SR_AUTO_PORTS` | auto-pick + pin free ports | `1` |
| `SR_QUERY_PORT` … `SR_BE_BRPC_PORT` | port search starts | StarRocks defaults |
| `SR_MYSQL_HOST` / `SR_BE_HOST` | FE host / BE address to register | `127.0.0.1` |
| `SR_PRIORITY_NET` | CIDR for multi-NIC hosts | — |

---

## Quick start

```bash
P=plugins/starrocks-dev/skills

# 1. Configure + test the connection (writes config.env, opens ControlMaster)
SR_HOST=dev01 SR_USER=root \
SR_DOCKER=sr-dev-main SR_IMAGE=<registry>/starrocks/dev-env-ubuntu:latest \
SR_SRC=/root/starrocks \
  bash $P/sr-connect/scripts/setup.sh

# 2. Bring up the dev-env container (pull + mount), then health-check the env
bash $P/sr-connect/scripts/env-up.sh
bash $P/sr-connect/scripts/doctor.sh

# 3. Build
bash $P/sr-build/scripts/build.sh --be          # or --fe / (no flag = both)

# 4. Deploy + verify
bash $P/sr-deploy/scripts/deploy.sh up
bash $P/sr-deploy/scripts/deploy.sh sql 'SHOW BACKENDS'

# 5. Test
bash $P/sr-test/scripts/test.sh be --gtest_filter 'SomeTest.*'
```

---

## Per-skill usage

### sr-connect

```bash
S=plugins/starrocks-dev/skills/sr-connect/scripts
bash $S/setup.sh        # write config.env + test connection (merges; re-run to update)
bash $S/env-up.sh       # pull image + create/start the dev-env container (idempotent)
bash $S/doctor.sh       # ✓/✗ report: ssh, container, source, toolchain, thirdparty, disk
bash $S/sr.sh '<cmd>'           # run a command on the HOST
bash $S/sr.sh --src '<cmd>'     # run in $SR_SRC (inside the container if SR_DOCKER set)
```
Use `sr.sh --src` to edit remote source (`sed`/`python`/heredoc) — the mount makes
edits land on the host too.

### sr-build

```bash
B=plugins/starrocks-dev/skills/sr-build/scripts/build.sh
bash $B                       # FE + BE (incremental)
bash $B --fe                  # FE only
bash $B --be                  # BE only
bash $B --be --module storage # one BE module (fast iteration)
bash $B --clean               # clean rebuild of the chosen targets
BUILD_TYPE=Asan bash $B --be  # ASan backend
```
Extra `build.sh` flags pass straight through. The dev-env container is created on
demand before building.

### sr-test

```bash
T=plugins/starrocks-dev/skills/sr-test/scripts/test.sh
bash $T fe                              # all FE unit tests
bash $T fe --test com.starrocks.X       # one FE class/method
bash $T be                              # all BE unit tests (gtest, ASan)
bash $T be --gtest_filter 'JsonTest.*'  # gtest filter
bash $T be --module storage             # one BE module's tests
bash $T java-ext                        # Java extension UTs
bash $T regression [run.sh args]        # SQL regression vs a running cluster
```
`regression` needs a live cluster (`sr-deploy up`) and `test/conf/sr.conf` pointed
at it.

### sr-deploy

```bash
D=plugins/starrocks-dev/skills/sr-deploy/scripts/deploy.sh
bash $D up               # sync+config, start FE+BE, register BE, status  ← most common
bash $D status           # run root + ports + SHOW FRONTENDS/BACKENDS + processes
bash $D ports            # re-probe & re-pin free ports (after a conflict), then restart
bash $D restart [all|fe|be]   # re-syncs rebuilt binaries, then restarts
bash $D stop  [all|fe|be]
bash $D logs  [fe|be]
bash $D sql 'SHOW DATABASES'
bash $D config           # rewrite ports/conf only (then restart to apply)
```
Ports are auto-picked and pinned to `<run-dir>/.sr-ports.env`; `status` prints the
live `mysql -P<port>` line to connect.

### sr-diagnose

```bash
G=plugins/starrocks-dev/skills/sr-diagnose/scripts
bash $G/analyze.sh /tmp/crash.txt             # locate: signature, frames→source, blame
bash $G/analyze.sh /tmp/crash.txt --addr2line # symbolize raw BE addresses (llvm-addr2line)
bash $G/known.sh 'SegmentIterator::next'      # search repo history for the fix
bash $G/known.sh --file be/src/storage/x.cpp
bash $G/repro.sh --build asan --sql /tmp/repro.sql --match 'SIGSEGV|Check failed'
bash $G/repro.sh --build asan --gtest 'SomeTest.*' --match 'AddressSanitizer'
```
Workflow: **locate → is-it-known → reproduce → report**. `repro.sh` builds, brings
the cluster up (auto-ports), fires the trigger, and watches the logs for the crash
signature (exit 0 = reproduced). Also cross-check upstream GitHub issues/PRs.

### sr-inspect

Connect to an **already-running** cluster **through the dev host** using a mysql
connection string you provide (nothing is stored — pass `--conn`, or `export SR_CL_*`
once per session). Node access (`jstack`/`pstack`/`logs`/`sys`) uses a fixed ssh
account + password (+`--sudo`).

```bash
I=plugins/starrocks-dev/skills/sr-inspect/scripts/diag.sh
C='mysql -h 10.0.0.21 -P 9030 -uroot -psecret'   # your connection string
bash $I --conn "$C" conn                          # connect via dev host + reachability + FE/BE list
bash $I --conn "$C" sql 'SHOW BACKENDS'
bash $I --conn "$C" explain 'SELECT count(*) FROM t WHERE ...'   # EXPLAIN ANALYZE
bash $I --conn "$C" profile <query_id>            # query profile via the FE HTTP API
bash $I --conn "$C" --ssh-user ops --ssh-pass pw --sudo jstack <fe-node>
bash $I --conn "$C" --ssh-user ops --ssh-pass pw --sudo logs <node> be
```

### sr-rollout

Full-replace a **live** cluster's FE/BE binaries with a **worktree profile's**
`output/` (build it first with sr-build), **through the dev host** — BEs first (FE
stays up to verify), then FEs. Each node: stop → back up lib/bin → push new lib/bin →
start → verify Alive. `plan` warns if a node's OS doesn't match the profile's dev-env
image. Backups enable `rollback`.

```bash
R=plugins/starrocks-dev/skills/sr-rollout/scripts/rollout.sh
C='mysql -h 10.0.0.21 -P 9030 -uroot -psecret'

SR_PROFILE=myfeat bash ../sr-build/scripts/build.sh        # build the profile (OS-matched image)
SR_PROFILE=myfeat bash $R --conn "$C" --ssh-user ops --ssh-pass pw --sudo plan          # dry-run + OS/image check
SR_PROFILE=myfeat bash $R --conn "$C" --ssh-user ops --ssh-pass pw --sudo apply --yes   # full replace (BEs→FEs)
SR_PROFILE=myfeat bash $R --conn "$C" --ssh-user ops --ssh-pass pw --sudo status        # versions + binary mtime/node
SR_PROFILE=myfeat bash $R --conn "$C" --ssh-user ops --ssh-pass pw --sudo rollback      # restore latest backup
```
Build for the cluster's OS by pinning a matching image on the profile:
`bash ../sr-connect/scripts/workspace.sh create <name> --image <…dev-env-centos7…>`.

---

## End-to-end examples

**First-time setup + a BE change, deployed and tested**
```bash
P=plugins/starrocks-dev/skills
bash $P/sr-connect/scripts/setup.sh        # (with SR_* exported)
bash $P/sr-connect/scripts/doctor.sh
# ...edit source via sr.sh --src or your editor over the mount...
bash $P/sr-build/scripts/build.sh --be
bash $P/sr-deploy/scripts/deploy.sh restart be
bash $P/sr-test/scripts/test.sh be --gtest_filter 'YourTest.*'
```

**Diagnose a crash report**
```bash
G=plugins/starrocks-dev/skills/sr-diagnose/scripts
bash $G/analyze.sh /tmp/crash.txt --addr2line     # what & where
bash $G/known.sh 'CrashingFunc'                   # already fixed?
bash $G/repro.sh --build asan --sql /tmp/min.sql --match 'AddressSanitizer'
```

**Build a fix in a worktree profile and roll it out to a live cluster**
```bash
P=plugins/starrocks-dev/skills
C='mysql -h 10.0.0.21 -P 9030 -uroot -psecret'
# OS-matched profile so the binary's glibc/ABI matches the cluster nodes
bash $P/sr-connect/scripts/workspace.sh create fix --branch hotfix --image <…/dev-env-centos7:latest>
SR_PROFILE=fix bash $P/sr-build/scripts/build.sh
SR_PROFILE=fix bash $P/sr-rollout/scripts/rollout.sh --conn "$C" --ssh-user ops --ssh-pass pw --sudo plan
SR_PROFILE=fix bash $P/sr-rollout/scripts/rollout.sh --conn "$C" --ssh-user ops --ssh-pass pw --sudo apply --yes
```

---

## Security

This repo is intended to be public. Real hosts, jump hosts, private-registry
addresses, internal paths, and SSH keys live **only** in your private
`~/.config/starrocks_dev/config.env` (and are git-ignored if placed in-tree). The
checked-in template uses placeholders only. The SSH ControlMaster socket and any
secrets are never printed by the scripts.

---

## Layout

```text
.claude-plugin/marketplace.json        # marketplace manifest
plugins/starrocks-dev/
├── .claude-plugin/plugin.json         # plugin manifest
├── config.env.example                 # config template (copy to ~/.config/starrocks_dev/)
├── scripts/srlib.sh                   # shared SSH/docker/file-transfer layer
├── scripts/srcluster.sh               # shared LIVE-cluster helpers (sr-inspect / sr-rollout)
└── skills/
    ├── sr-connect/   (setup, env-up, doctor, sr, workspace)
    ├── sr-build/     (build)
    ├── sr-test/      (test)
    ├── sr-deploy/    (deploy)
    ├── sr-diagnose/  (analyze, known, repro)
    ├── sr-inspect/   (diag)
    └── sr-rollout/   (rollout)
```
Each skill's `SKILL.md` has the full option list, behavior notes, and triggers.
