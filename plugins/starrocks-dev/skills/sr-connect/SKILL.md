---
description: Set up and verify the SSH connection to a remote StarRocks development host, bring up the Docker dev-env container (pull image + mount source if needed), and check the remote toolchain + source tree. Use FIRST, before sr-build/sr-test/sr-deploy, or whenever a remote command fails with a connection/path/container error. Also runs ad-hoc shell commands on the dev host. Triggers — "connect to the starrocks dev machine", "set up remote starrocks", "pull the dev-env image", "start the build container", "check the remote build environment", "运行远程命令", "配置 starrocks ssh", "起编译容器".
---

# StarRocks Remote Connect

Foundation skill for the `starrocks-dev` plugin. Establishes a reusable SSH
connection to a remote StarRocks dev host and confirms the remote is build-ready.
`sr-build` and `sr-deploy` both rely on the connection this skill configures.

## How it works

- Config lives at `~/.config/starrocks_dev/config.env` (chmod 600). All three
  skills read it through the shared helper `scripts/srlib.sh` at the plugin root.
- **Profiles (parallel work):** setting `SR_PROFILE=<name>` switches the active
  config to `~/.config/starrocks_dev/profiles/<name>/config.env`. Each profile is an
  independent task — its own container, source worktree, deploy dir and ports — so
  several features build/deploy in parallel. Leaving `SR_PROFILE` unset uses the
  default config exactly as before. See **Parallel work** below.
- SSH reuses a **ControlMaster** socket, so only the first command authenticates;
  the rest are instant for ~5 minutes.
- Bastions are supported two ways: set `SR_PROXY_JUMP` (applied to ssh/scp/rsync as
  `-o ProxyJump=…`), or — since `~/.ssh/config` is honored — put a `ProxyJump`
  stanza there for the host and use its alias as `SR_HOST`. The ControlMaster
  socket is established through the jump either way. `setup.sh` `ssh-keyscan`s the
  jump host(s) and target into `known_hosts` first, so the initial BatchMode connect
  never dies on an unknown jump key (the cryptic `Connection closed ... port 65535`).
- Commands run either directly on the host or, if `SR_DOCKER` is set, inside a
  dev-env container (`starrocks/dev-env-ubuntu` style). When the container is
  missing, `env-up.sh` (and any build/test/deploy call) will pull the image and
  create it automatically — see **Docker dev-env** below.

## Config keys (`~/.config/starrocks_dev/config.env`)

Copy the template and fill in your values (keep real hosts/registries/paths out of
anything committed — they live only in this private file):

```bash
cp "$CLAUDE_PLUGIN_ROOT/config.env.example" ~/.config/starrocks_dev/config.env
chmod 600 ~/.config/starrocks_dev/config.env
```

```
SR_HOST=dev01.example.com   # hostname/IP, or a ~/.ssh/config alias
SR_USER=root                # ssh user (omit if the alias already sets it)
SR_PORT=22
SR_KEY=~/.ssh/id_ed25519    # optional identity file
SR_PROXY_JUMP=user@bastion  # optional jump host: user@jump[:port], or 'j1,j2' to chain
SR_SRC=/root/starrocks      # source path the BUILD uses (inside the container when SR_DOCKER set)

# --- Docker dev-env (set these to compile inside a container) ---
SR_DOCKER=sr-dev-main                    # container name (often encodes the branch)
SR_IMAGE=<your-registry>/starrocks/dev-env-ubuntu:latest   # dev-env image (private registry ok)
SR_HOST_SRC=/path/to/starrocks           # source path on the HOST, mounted to SR_SRC (default: remote $HOME/basename(SR_SRC))
SR_NOFILE=655350            # ulimit nofile for the container (StarRocks needs it high)
SR_M2=                      # optional host ~/.m2 to mount as /root/.m2 (Maven cache reuse)
SR_DOCKER_RUN_OPTS=         # extra docker-run opts, e.g. '--network host' or '-p 9030:9030'

SR_THIRDPARTY=              # optional STARROCKS_THIRDPARTY override (preset in the dev-env image)
SR_JOBS=                    # build parallelism (default: remote nproc)
SR_BUILD_TYPE=Release       # Release | Debug | Asan
```

> When `SR_DOCKER` is set, `SR_SRC` is the path **inside** the container
> (`/root/starrocks`) and `SR_HOST_SRC` is the real path **on the host**. If
> `SR_HOST_SRC` is left unset it defaults to **remote `$HOME`/basename(`SR_SRC`)**
> (e.g. `/home/<user>/starrocks`, resolved over SSH at runtime). They are
> bind-mounted together, so editing files at
> `SR_SRC` inside the container changes the same files on the host.

Use **single quotes** if any value contains shell metacharacters. Real env vars
override the file, so you can do `SR_HOST=foo bash scripts/...` for one-off targets
— including an empty value to *disable* a key, e.g. `SR_DOCKER= bash scripts/...`
to run on the host instead of the container for that one command.

## Scripts

All scripts live under `scripts/` next to this file and source `srlib.sh`.

### `setup.sh` — write config and test the connection

```bash
SR_HOST=dev01 SR_USER=root SR_SRC=/root/starrocks bash scripts/setup.sh
```
Writes any `SR_*` values you pass (env vars or existing config) into
`config.env`, opens the ControlMaster, and prints the remote identity line.
Re-run any time to update a value — it merges, it doesn't clobber. It persists
**every documented `SR_*` key** (connection, docker, build, and deploy), so a value
you set once is never silently dropped on the next command.

### `env-up.sh` — bring up the Docker dev-env (pull image + create container)

```bash
bash scripts/env-up.sh
```
Only relevant when `SR_DOCKER` is set. Idempotent and self-healing:

- container **running** → no-op;
- container **stopped** → `docker start`;
- container **absent** → if the image isn't present, `docker pull "$SR_IMAGE"`, then
  ```
  docker run --name "$SR_DOCKER" --ulimit nofile=$SR_NOFILE:$SR_NOFILE \
    -v "$SR_HOST_SRC":"$SR_SRC" [ -v "$SR_M2":/root/.m2 ] $SR_DOCKER_RUN_OPTS \
    -dit "$SR_IMAGE" /bin/bash
  ```

After it returns, it prints the container status and the in-container toolchain +
git branch. You rarely call this directly — `sr-build`, `sr-test`, and `sr-deploy`
each run the same ensure step first, so the container is created on first build.

It also registers `$SR_SRC` as a git `safe.directory` inside the container (the
bind-mounted tree is owned by the host user, not container root), so `build.sh`'s
version-stamping step doesn't trip over "detected dubious ownership".

### `doctor.sh` — verify the remote is build-ready

```bash
bash scripts/doctor.sh
```
Checks: connectivity, the source tree exists at `$SR_SRC` and is a StarRocks repo
(reports current branch + HEAD), toolchain (`java`/`mvn`/`cmake`/`gcc`/`ccache`),
`STARROCKS_THIRDPARTY` presence, free disk, and — if `SR_DOCKER` is set — that the
container is running. Prints a ✓/✗ table and exits non-zero if anything required
is missing.

### `sr.sh` — run an ad-hoc command on the dev host

```bash
bash scripts/sr.sh 'git -C $SR_SRC log --oneline -5'   # host-level
bash scripts/sr.sh --src 'git status'                   # inside $SR_SRC (and dev-env if SR_DOCKER set)
```
`--src` runs the command in the source dir with `STARROCKS_HOME` exported (and
inside the dev-env container when configured). This is the primitive `sr-build`
and `sr-deploy` are built on; use it for anything they don't cover (editing a
config file via `sed`, inspecting logs, `git` operations, etc.).

> `sr.sh` (like every skill) honors `SR_PROFILE` — `SR_PROFILE=featA bash
> scripts/sr.sh --src 'git status'` runs against profile *featA*'s worktree/container.

### `workspace.sh` — manage parallel profiles (create / list / rm)

```bash
bash scripts/workspace.sh list                          # default profile + all named ones
bash scripts/workspace.sh create featA --branch feature/a   # worktree + scaffolded config
bash scripts/workspace.sh rm featA                      # remove config + worktree + container
```
`create <name>` inherits the default profile's connection/image/cache settings and
overrides only what must differ, in one step:
- adds a **git worktree** on the remote (`git worktree add`, sharing the main repo's
  `.git`) for `--branch` (created off `--base`, default current HEAD; the branch
  name defaults to `<name>`) → becomes the profile's `SR_HOST_SRC`;
- sets `SR_DOCKER=sr-dev-<name>` (container created on first build);
- sets `SR_DEPLOY_DIR=<base deploy>/<name>` if the default deploys to a dir, else
  runs in-place from the worktree's `output/`;
- keeps `SR_AUTO_PORTS=1` so the cluster's ports won't collide with other profiles.

Options: `--branch`, `--base`, `--src` (worktree host path; default
`${SR_WS_ROOT:-$HOME/sr-ws}/<name>`), `--container`, `--deploy`. `rm` also
git-worktree-removes the source and `docker rm -f`s the container unless
`--keep-src` / `--keep-container` is passed. `.m2`/ccache are **shared** (the
profile inherits `SR_M2`), so parallel builds reuse one cache.

## Parallel work (build several features at once)

The scripts are fully env-driven and the SSH ControlMaster is shared per host, so
the only thing that needs isolating per task is the config. Profiles do exactly
that. Typical flow:

```bash
# one-time: a configured default profile (setup.sh) is the template
bash scripts/workspace.sh create featA --branch feature/a
bash scripts/workspace.sh create featB --branch feature/b

# build both at the same time (two containers, two worktrees, one shared cache)
SR_PROFILE=featA bash ../../sr-build/scripts/build.sh &
SR_PROFILE=featB bash ../../sr-build/scripts/build.sh &
wait

# deploy both — ports auto-allocate so the two clusters don't collide
SR_PROFILE=featA bash ../../sr-deploy/scripts/deploy.sh up
SR_PROFILE=featB bash ../../sr-deploy/scripts/deploy.sh up
```

Every skill command takes `SR_PROFILE=<name>` the same way. The agent prefixes it
on each command; nothing else changes. Editing files: each profile has a distinct
host worktree, so a change in featA's tree never affects featB's build.

## Notes for the agent

- Run `doctor.sh` before the first build of a session; most build failures are a
  missing toolchain or unbuilt thirdparty, which it catches up front.
- **Docker dev-env**: you don't need to create the container by hand — `env-up.sh`
  and any `sr-build`/`sr-test`/`sr-deploy` call run `sr_ensure_docker`, which pulls
  the image (if absent) and `docker run`s it with the source mounted and
  `--ulimit nofile` raised. Just make sure `SR_DOCKER`, `SR_IMAGE`, `SR_HOST_SRC`,
  `SR_SRC` are set. To switch branches/images, point `SR_DOCKER` at a different
  container name (e.g. `sr-dev-4.0`) and set the matching `SR_IMAGE`.
- Because `SR_SRC` lives inside the container, edit source via `sr.sh --src '...'`
  (it `docker exec`s in) — the mount makes the change land on the host too.
- To edit a remote source file, prefer `scripts/sr.sh --src '...'` with a heredoc
  or `sed`/`python -c`, or `rput`/`rget` from `srlib.sh` to copy a file both ways.
- The ControlMaster socket is at `~/.config/starrocks_dev/cm-*`. If the host
  reboots or the network drops, the next command transparently reopens it.
- Never echo `SR_KEY` contents or passwords. `setup.sh` stores only paths/values
  you provide and never prints secrets.
