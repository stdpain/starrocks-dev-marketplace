# starrocks-dev-marketplace

A Claude Code plugin marketplace for **remote StarRocks development over SSH**.
Claude runs locally and drives a remote dev host — editing, building, testing,
deploying, and debugging the StarRocks source tree that lives on that host
(optionally inside a `dev-env-ubuntu` container).

---

## The plugin: `starrocks-dev`

Eleven composable skills sharing one SSH connection layer
(`plugins/starrocks-dev/scripts/srlib.sh`, plus `srcluster.sh` for live clusters):

| Skill | Stage | What it does |
|-------|-------|--------------|
| **sr-connect** | connection / env | Configure & verify SSH (direct or via jump host), bring up the Docker dev-env (pull image + mount source), check the remote toolchain/source, run ad-hoc remote commands. Profiles for parallel work — and for a **second dev host reached through the main one** as an SSH jump (`workspace.sh add-host`). **Use first.** |
| **sr-build** | build | Compile FE (Maven) and BE (cmake) via `build.sh` — full, incremental, FE/BE-only, or a single module. |
| **sr-test** | test | FE / BE / Java-ext unit tests and SQL regression tests; single-class, gtest-filter, or single-module runs. |
| **sr-deploy** | deploy / run | Sync artifacts to a deploy dir, auto-pick free ports, start/stop/restart FE+BE, register the BE, run SQL to verify. |
| **sr-diagnose** | triage / repro | From a crash/stack/issue: locate the source, check if it's a known/fixed issue, and if not reproduce it (ASan build → trigger → capture) with exact steps. |
| **sr-inspect** | inspect | Connect to a **live** cluster through the dev host via a mysql connection string and inspect perf/correctness — SQL, EXPLAIN ANALYZE, query profiles, jstack/pstack/logs/sys on its nodes. |
| **sr-rollout** | rollout | Full-replace a **live** cluster's FE/BE binaries with a worktree profile's `output/`, node by node — OS-matched, with backup/rollback and Alive health-checks. |
| **sr-backport** | backport | Cherry-pick a merged PR onto a release branch in an isolated worktree, surface conflicts for Claude to resolve, then build + run related UTs on the **branch-matching** dev-env image (backport to 4.1 → 4.1 image). Stops at a verified local commit; you review & push. |
| **sr-bench** | benchmark clusters | Register **benchmark/test clusters** by name — reached through a jump host (a bastion or the dev host), logged into with a **shared account+password from env vars** (never stored). Connect + health-check, run SQL, ssh to nodes, and **`wake`** to start FE/BE that a suspend left down. |
| **sr-scan** | static bug hunt | **Proactively hunt bugs**: statically scan a module/flow for risky patterns, reason about each path, then **prove** the real ones by reproducing — SQLTest/regression, StarRocks **failpoint**, **strace** syscall-error injection, **eBPF** probe, or **Linux kernel fault injection** — and record each confirmed bug to markdown. |

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
- **Live & benchmark clusters.** sr-inspect / sr-rollout / sr-bench operate on an
  *already-running* cluster reached **through a jump** — by default the dev host
  (`SR_HOST`), or a dedicated bastion (`SR_CL_JUMP` / a sr-bench `--jump`). Every
  `mysql`/`ssh` runs on that jump over the same ControlMaster; the cluster's own
  account+password is passed per-invocation (a `--conn` string, or read from env
  vars by sr-bench) and **never stored**.
- **Bug hunting (sr-scan).** Scanning is a remote `grep` over the source for risk
  patterns; *proving* a finding means forcing the error path on a throwaway dev
  cluster. The reproduction methods escalate in privilege — a **SQLTest** needs
  nothing special; a **failpoint** needs a fault-injection BE build; **strace**
  syscall injection needs `CAP_SYS_PTRACE`; **kernel fault injection** / **eBPF**
  need a fault-injection kernel and host root. Each method sets up the fault, fires
  the trigger via sr-diagnose's `repro.sh`, then **always tears the fault down**.

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

**Benchmark clusters (sr-bench)** aren't config.env keys — they're a separate named
registry under `~/.config/starrocks_dev/bench/<name>.env` (topology + credential
*variable names*, no secrets). Their shared login is read from the environment at run
time: `export SR_BENCH_USER=root SR_BENCH_PASS=…`. See the [sr-bench](#sr-bench) section.

**Bug-hunt reproduction (sr-scan)** can need extra capabilities the dev-env container
lacks by default: strace syscall injection needs `SR_DOCKER_RUN_OPTS='--cap-add=SYS_PTRACE'`
(recreate the container after setting it), and kernel fault injection / eBPF need host root
on a fault-injection kernel. See the [sr-scan](#sr-scan) section.

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
SR_PROFILE=myfeat bash $R --conn "$C" --ssh-user ops --ssh-pass pw --sudo --parallel apply --yes  # roll ALL BEs at once
SR_PROFILE=myfeat bash $R --conn "$C" --ssh-user ops --ssh-pass pw --sudo status        # versions + binary mtime/node
SR_PROFILE=myfeat bash $R --conn "$C" --ssh-user ops --ssh-pass pw --sudo rollback      # restore latest backup
```
`--parallel` (all BEs at once) / `--jobs N` (N at a time) speed up many-BE **benchmark**
clusters; FEs always roll one at a time. Build for the cluster's OS by pinning a matching
image on the profile: `bash ../sr-connect/scripts/workspace.sh create <name> --image <…dev-env-centos7…>`.

---

### sr-backport

Backport a **merged** PR onto a release branch: resolve the PR's merge commit
(GitHub REST API), create an isolated worktree profile pinned to the **branch-matching
dev-env image** (backport to `branch-4.1` → the 4.1 image), and cherry-pick. Conflicts
are copied out for Claude to resolve, then pushed back and committed. `verify` builds
the changed FE/BE on that image and runs related unit tests. **Nothing is pushed** —
it stops at a verified local commit on `backport/<target>/pr-<N>` for you to review.

```bash
B=plugins/starrocks-dev/skills/sr-backport/scripts/backport.sh
bash $B prepare --pr https://github.com/StarRocks/starrocks/pull/12345 --branch 4.1
#   → profile bp-4.1-pr12345, image …/dev-env-ubuntu:branch-4.1; clean or "CONFLICTED: …"
SR_PROFILE=bp-4.1-pr12345 bash $B pull  ./bp     # copy conflicted files out (Claude edits them)
SR_PROFILE=bp-4.1-pr12345 bash $B resolve ./bp   # push back + git add (rejects leftover markers)
SR_PROFILE=bp-4.1-pr12345 bash $B continue       # finish the cherry-pick
SR_PROFILE=bp-4.1-pr12345 bash $B verify         # build changed FE/BE on the 4.1 image + related UTs
SR_PROFILE=bp-4.1-pr12345 bash $B diff           # review, then push yourself
```
The image tag follows `SR_BP_IMAGE_TPL` (`{base}:{branch}` by default, or `{base}:{ver}`
for registries tagged `…:4.1`); override per-run with `prepare --image <ref>`.

---

### sr-bench

Register **benchmark/test clusters** by name and operate them. They're reached through a
**jump** (a dedicated bastion via `--jump`, or — when omitted — the sr-connect dev host),
logged into with a **shared account+password** kept in env vars and never written to disk;
the registry stores only topology + the cred **variable names**. Because these clusters get
**suspended**, the registry also keeps a **node inventory + StarRocks home** so `wake` can
ssh in and start whatever FE/BE is down (when the FE itself is down, `SHOW BACKENDS` can't
discover them).

```bash
S=plugins/starrocks-dev/skills/sr-bench/scripts/bench.sh
export SR_BENCH_USER=root SR_BENCH_PASS='…'        # shared creds — env only, never stored

bash $S add tpch --fe 10.0.0.21 --jump ops@bastion01 \
     --fe-nodes 10.0.0.21=/data/sr/fe --be-nodes '10.0.0.22,10.0.0.23' --be-home /data/sr/be
bash $S ls                              # all clusters (FE, jump, node counts)
bash $S tpch                            # = conn: reachability + version + FRONTENDS/BACKENDS
bash $S status tpch                     # conn + per-node FE/BE up/DOWN
bash $S wake tpch                       # ssh to each node, start any down FE/BE (FEs first)
bash $S sql tpch 'SHOW BACKENDS'
eval "$(bash $S env tpch)"              # then drive sr-inspect / sr-rollout against it
```

`wake` starts FE/BE as the SSH login user (never sudo, to avoid root-owned pid files). Omit
`--jump` for clusters reachable from the dev host; with `--jump` the bastion is reached by
key (`--jump-key`) or the shared password (needs `sshpass` locally).

---

### sr-scan

**Hunt** for bugs instead of waiting for a crash: scan a module/flow, reason about each risky
path, then **prove** the real ones by reproducing and record them. Four phases — scan →
analyze → reproduce → record.

```bash
S=plugins/starrocks-dev/skills/sr-scan/scripts
bash $S/scan.sh be/src/storage/lake --hooks         # risk candidates + repro hooks (failpoints/tests)
bash $S/scan.sh --flow ChunkAggregator::aggregate   # scan one function's flow
# ...read candidates, follow the path, keep the real ones, then reproduce the cheapest faithful way:
bash ../sr-diagnose/scripts/repro.sh --build asan --sql /tmp/t.sql --match 'Check failed'   # SQLTest
bash $S/inject.sh failpoint run --enable '<SQL>' --disable '<SQL>' --sql /tmp/t.sql          # internal error path
bash $S/inject.sh syscall --proc be --syscall pwrite64 --errno EIO --when 3 --sql /tmp/t.sql # fail a syscall
bash $S/inject.sh kfail --type fail_make_request --probability 100 --sql /tmp/t.sql          # kernel fault inj.
bash $S/inject.sh ebpf --script probe.bt --sql /tmp/t.sql                                    # eBPF observe/inject
bash $S/record.sh add --title "..." --status reproduced --location be/...:NN --method syscall:EIO --trigger /tmp/t.sql
```

Each `inject.sh` method sets up the fault, fires the trigger via sr-diagnose's `repro.sh`
(watching `be.out`/`fe.log`), then tears it down. Only **reproduced** findings are
high-confidence; unproven ones are recorded as `suspected`. Needs a throwaway dev cluster up
(`sr-deploy up`) for runtime reproduction. For triaging an *existing* crash, use sr-diagnose.

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

**Hunt for a bug in a module and prove it**
```bash
P=plugins/starrocks-dev/skills
bash $P/sr-deploy/scripts/deploy.sh up                                  # throwaway dev cluster
bash $P/sr-scan/scripts/scan.sh be/src/storage/lake --hooks            # 1) scan → candidates + hooks
# 2) read the candidates, follow the path, form a hypothesis, then 3) reproduce:
bash $P/sr-scan/scripts/inject.sh syscall --proc be --syscall pwrite64 --errno EIO --when 2 \
     --sql /tmp/trigger.sql --match 'status_code|Check failed'
# 4) record the confirmed bug
bash $P/sr-scan/scripts/record.sh add --title "EIO on segment flush is swallowed" \
     --status reproduced --component be/storage/lake --location be/src/storage/lake/x.cpp:88 \
     --class unchecked-status --method syscall:EIO --trigger /tmp/trigger.sql
```

**Wake a suspended benchmark cluster and inspect it**
```bash
P=plugins/starrocks-dev/skills
export SR_BENCH_USER=root SR_BENCH_PASS='…'                 # shared creds — env only
bash $P/sr-bench/scripts/bench.sh status tpch               # FE down / nodes DOWN → suspended
bash $P/sr-bench/scripts/bench.sh wake tpch                 # ssh in, start FE then BEs
bash $P/sr-bench/scripts/bench.sh tpch                      # confirm version + all nodes Alive
eval "$(bash $P/sr-bench/scripts/bench.sh env tpch)"        # hand off to sr-inspect
bash $P/sr-inspect/scripts/diag.sh explain 'SELECT ...'     # profile a slow benchmark query
```

---

## Security

This repo is intended to be public. Real hosts, jump hosts, private-registry
addresses, internal paths, and SSH keys live **only** in your private
`~/.config/starrocks_dev/config.env` (and are git-ignored if placed in-tree). The
checked-in template uses placeholders only. The SSH ControlMaster socket and any
secrets are never printed by the scripts. sr-bench keeps cluster credentials out of
its registry too — only the env-var *names* are stored.

Some skills are **destructive by design** — sr-rollout swaps live binaries, and sr-scan
runs arbitrary SQL and injects faults (syscall/kernel/eBPF) into the cluster. Point them
at a throwaway dev or test cluster, never one you care about.

---

## Layout

```text
.claude-plugin/marketplace.json        # marketplace manifest
plugins/starrocks-dev/
├── .claude-plugin/plugin.json         # plugin manifest
├── config.env.example                 # config template (copy to ~/.config/starrocks_dev/)
├── scripts/srlib.sh                   # shared SSH/docker/file-transfer layer
├── scripts/srcluster.sh               # shared LIVE-cluster helpers (sr-inspect / sr-rollout / sr-bench)
└── skills/
    ├── sr-connect/   (setup, env-up, doctor, sr, workspace)
    ├── sr-build/     (build)
    ├── sr-test/      (test)
    ├── sr-deploy/    (deploy)
    ├── sr-diagnose/  (analyze, known, repro)
    ├── sr-inspect/   (diag)
    ├── sr-rollout/   (rollout)
    ├── sr-backport/  (backport)
    ├── sr-bench/     (bench)
    └── sr-scan/      (scan, inject, record)
```
Each skill's `SKILL.md` has the full option list, behavior notes, and triggers.
