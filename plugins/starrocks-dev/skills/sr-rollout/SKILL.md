---
description: Roll out a worktree profile's freshly built binaries onto a LIVE StarRocks cluster, THROUGH the dev host — full binary replacement, node by node. You give a mysql connection string + node-ssh creds; the skill lists the cluster's FE/BE nodes, detects each node's OS, cross-checks it against the dev-env image the profile was built on (warns on glibc/ABI mismatch), then for each node stops it, backs up + swaps lib/bin from <profile>/output/, restarts, and verifies Alive. BEs first (FE stays up to verify), then FEs. Supports plan (dry-run), apply, rollback, status. Build the profile first with sr-build. Requires sr-connect for the dev host. Triggers — "roll out this build to the cluster", "replace the cluster binaries with my build", "deploy my worktree output to the live cluster", "upgrade the cluster to my FE/BE", "灰度/滚动发布到集群", "把我编的二进制替换到集群", "回滚集群二进制".
---

# StarRocks Cluster Rollout

Pushes the binaries you **built in a worktree profile** onto an **already-running**
cluster's nodes, **through the dev host**. This is the step after sr-build: take
`<profile>/output/{fe,be}` and **full-replace** the FE/BE install on each live node.

(For the local single-node dev cluster, use **sr-deploy**. This skill targets a real
multi-node test/staging cluster reached *from* the dev host.)

## Model

- **Topology — the dev host is the jump.** Same as sr-inspect: the cluster is reachable
  from the dev host (`SR_HOST`, set by sr-connect), not your laptop. Every `mysql` /
  `ssh` / `tar` runs on the dev host over the existing SSH ControlMaster.
- **Binary source = a worktree profile's `output/`.** Set `SR_PROFILE=<name>`. Artifacts
  are read from that profile's `<SR_HOST_SRC>/output/{fe,be}` on the dev host. **Build it
  first** with sr-build.
- **OS-matched build matters.** A binary built on an Ubuntu dev-env will not reliably run
  on CentOS nodes (glibc/ABI). `plan` detects each node's OS (`cl_node_os`) and compares
  it to the profile's image (`SR_IMAGE`), warning on a mismatch. To build for the right
  OS, create the profile pinned to a matching image:
  `bash ../sr-connect/scripts/workspace.sh create <name> --image <…dev-env-centos7…>`,
  then sr-build it.
- **Strategy = full replacement, node by node.** BEs roll first (FE stays up so each BE's
  Alive is verified via SQL), then FEs. Each node: **stop → back up current lib/bin →
  push new lib/bin → start → health-check**. Conf / meta / storage / log are left
  untouched. Backups under `<home>/.sr-rollout-backup/<ts>` enable `rollback`.

## Connection & credentials (one-off, never stored)

Pass the cluster connection string and node-ssh creds per invocation, exactly like
sr-inspect. For convenience in a session:

```bash
export SR_CL_CONN='mysql -h 10.0.0.21 -P 9030 -uroot -psecret'
export SR_CL_SSH_USER=ops SR_CL_SSH_PASS=secret SR_CL_SUDO=1   # node access (stop/start/swap)
export SR_PROFILE=myfeat                                       # the built worktree profile
```

## Usage

```bash
# 0) build the profile first (ideally on an OS-matched image)
SR_PROFILE=myfeat bash ../sr-build/scripts/build.sh

# 1) DRY-RUN: nodes, OS, detected install dirs, build output + image, mismatch warnings
SR_PROFILE=myfeat bash scripts/rollout.sh --conn "$C" --ssh-user ops --ssh-pass pw --sudo plan

# 2) APPLY: full replacement (BEs then FEs). Prompts unless --yes.
SR_PROFILE=myfeat bash scripts/rollout.sh --conn "$C" --ssh-user ops --ssh-pass pw --sudo apply
SR_PROFILE=myfeat bash scripts/rollout.sh ... apply be      # only BEs   (or: apply fe)

# 3) status / rollback
SR_PROFILE=myfeat bash scripts/rollout.sh ... status        # versions + installed binary mtime per node
SR_PROFILE=myfeat bash scripts/rollout.sh ... rollback      # restore each node's latest backup, restart
```

`$C` is your connection string, e.g. `C='mysql -h 10.0.0.21 -P 9030 -uroot -psecret'`.

## Commands

| Command | What it does |
|---|---|
| `plan` (default) | List FE/BE nodes, each node's OS, detected install dir, the profile's build output + image; **warn on any OS/image mismatch**. No changes. |
| `apply [all\|be\|fe]` | Full replacement on the nodes (default `all` = BEs then FEs). Backs up before swapping; verifies Alive after each. Prompts unless `--yes`. |
| `rollback [all\|be\|fe]` | Restore each node's most recent `.sr-rollout-backup`, restart, verify. |
| `status` | `SHOW FRONTENDS` / `SHOW BACKENDS` + the installed binary's mtime per node. |

## Options

- `--conn '<str>'` (or `SR_CL_CONN`) — primary cluster input; `--fe/--port/--user/--password/--db` override parsed fields.
- `--ssh-user/--ssh-pass/--ssh-key/--ssh-port`, `--sudo` — node access (same as sr-inspect). `--sudo` is also used for the remote extract when the install dir is owned by another user.
- `--fe-home <path>` / `--be-home <path>` (or `SR_RO_FE_HOME` / `SR_RO_BE_HOME`) — override the auto-detected install dir on every node (use when detection via the running process fails).
- `--yes` (or `SR_RO_YES=1`) — skip the confirmation prompt before `apply` / `rollback`.

## Notes & caveats

- **Build output must exist** under `<profile>/output/{fe,be}` on the dev host — `plan`/`apply` fail fast with the exact build command otherwise.
- **Install-dir detection** uses the running process (`/proc/<pid>/exe` for BE, `/proc/<pid>/cwd`+cmdline for FE). If a node's FE/BE isn't running, or detection misses, pass `--fe-home/--be-home`.
- **Subdirs swapped:** BE → `lib bin www`; FE → `lib bin spark-dpp webroot` (present-only). This is a binary swap, **not** a StarRocks rolling-upgrade with version-compat gates — use it on dev/test clusters where the FE/BE versions you built are meant to run together.
- **Verify after rollout** with sr-inspect (`explain`, `profile`, `logs <node> fe|be`).
