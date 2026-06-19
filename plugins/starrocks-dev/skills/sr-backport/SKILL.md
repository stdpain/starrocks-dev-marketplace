---
description: Backport a merged StarRocks PR to a release branch and resolve the cherry-pick conflicts, then verify on the dev host using the BRANCH-MATCHING dev-env image (branch-4.1 → the 4.1 image). You give an original (merged-to-main) PR link + a target branch; the skill resolves the PR's merge commit, creates an isolated worktree profile pinned to the right image, cherry-picks, surfaces conflicts for Claude to resolve, then builds the changed FE/BE on that image and runs the related unit tests. Nothing is pushed to GitHub — you review the diff and push yourself. Requires sr-connect. Triggers — "backport this PR to branch-4.1", "解决这个 backport 冲突", "cherry-pick this PR to 4.1 and verify", "把这个 PR backport 到 3.3", "resolve the backport conflict and build on the branch image".
---

# StarRocks PR Backport (conflict-resolve + branch-image verify)

Backports a **merged** PR onto a release branch the StarRocks way: cherry-pick the
PR's squash-merge commit onto the target branch, resolve any conflicts, and verify
the result on the dev host **using the dev-env image that matches the target
branch** (backporting to `branch-4.1` builds on the 4.1 image, not main's).

The work happens in an **isolated worktree profile** (see sr-connect → *Parallel
work*) so it never disturbs your main checkout. **Nothing is pushed to GitHub** —
the skill stops at a verified local commit; you review the diff and push yourself.

## Division of labor

- **The script** (`backport.sh`) does all the git plumbing: resolve the PR → merge
  commit (GitHub REST API), create the branch-image worktree profile, cherry-pick,
  copy conflicted files out / back, finish the cherry-pick, and build + test.
- **Claude** does the one thing only a human/model can: **resolve the conflict
  markers** in the pulled files, using judgement about what the backport should be.

## Prerequisites

- **sr-connect** configured (the dev host where StarRocks is built). The dev host's
  git must be able to fetch from GitHub (it already fetches `origin` in normal dev).
- PR metadata is read from the GitHub REST API with local `python3`. For private
  repos or to avoid rate limits, export `GITHUB_TOKEN` (or `GH_TOKEN`). You can also
  skip the API entirely with `--oid <merge-sha>`.

## Workflow

```bash
S="$CLAUDE_PLUGIN_ROOT/skills/sr-backport/scripts/backport.sh"   # or: cd skills/sr-backport/scripts

# 1) PREPARE — resolve the PR, create the branch-image worktree, cherry-pick.
#    --branch accepts 4.1 / branch-4.1 / main. Prints the profile name to use next.
bash "$S" prepare --pr https://github.com/StarRocks/starrocks/pull/12345 --branch 4.1
#   → profile bp-4.1-pr12345, image …/dev-env-ubuntu:branch-4.1
#   → either "applied CLEANLY" or "CONFLICTED — resolve these files: …"

# 2) If CONFLICTED — the resolve loop (Claude does step 2b):
SR_PROFILE=bp-4.1-pr12345 bash "$S" pull  ./bp            # 2a: copy conflicted files to ./bp
#   2b: Claude opens each file under ./bp, resolves the <<<<<<< / ======= / >>>>>>> markers
SR_PROFILE=bp-4.1-pr12345 bash "$S" resolve ./bp          # 2c: push back + git add (rejects leftover markers)
SR_PROFILE=bp-4.1-pr12345 bash "$S" continue              # 2d: finish the cherry-pick

# 3) VERIFY — build the changed FE/BE on the 4.1 image + run related unit tests.
SR_PROFILE=bp-4.1-pr12345 bash "$S" verify                # auto-detects FE/BE from the diff

# 4) REVIEW — then push yourself if it looks right.
SR_PROFILE=bp-4.1-pr12345 bash "$S" diff
SR_PROFILE=bp-4.1-pr12345 bash "$S" push --yes            # gated: refuses without --yes

# 5) Clean up the worktree + container when done.
SR_PROFILE=bp-4.1-pr12345 bash "$S" cleanup
```

`bash "$S" list` shows every active backport profile (PR → branch → image).

## Commands

| Command | What it does |
|---|---|
| `prepare --pr <url\|#> --branch <target>` | Resolve the PR's merge commit, create a worktree profile pinned to the branch image, cherry-pick. `--repo o/r` (for a bare `--pr` number), `--oid <sha>` (skip API), `--image <img>`, `--profile <name>`. |
| `pull [<dir>]` | Copy the conflicted files locally (default `./.sr-backport/<profile>`) for Claude to edit. |
| `resolve [<dir>]` | Push the edited files back, `git add` them; **refuses** if any conflict marker survived. |
| `continue` | `git cherry-pick --continue` (no-op if already committed). |
| `verify [--fe\|--be] [--fe-test '<mvn>'] [--be-test '<filter>'] [--no-build] [--no-test]` | Build changed FE/BE on the branch image + run related UTs. |
| `diff` / `status` | Show the backport commit / cherry-pick state. |
| `push [--remote o] [--branch b] [--yes]` | Push the local branch to GitHub. **Gated** — refuses without `--yes`. |
| `cleanup [--keep-src]` | Remove the worktree profile + container (`workspace.sh rm`). |
| `list` | List active backport profiles. |

## Branch → image matching (the key requirement)

`prepare` derives the dev-env image from the **target branch**, so a 4.1 backport
verifies on the 4.1 toolchain — never main's. The base repo comes from your
configured `SR_IMAGE`; the **tag** follows a convention you can set with
`SR_BP_IMAGE_TPL` (placeholders `{base}`, `{branch}`, `{ver}`):

| target | default tpl `{base}:{branch}` | `SR_BP_IMAGE_TPL='{base}:{ver}'` |
|---|---|---|
| `branch-4.1` | `…/dev-env-ubuntu:branch-4.1` | `…/dev-env-ubuntu:4.1` |
| `branch-3.3` | `…/dev-env-ubuntu:branch-3.3` | `…/dev-env-ubuntu:3.3` |
| `main` | `SR_IMAGE` unchanged (its own tag) | `SR_IMAGE` unchanged |

`{ver}` is the numeric version (`branch-4.1` → `4.1`). Set `SR_BP_IMAGE_TPL` once in
`~/.config/starrocks_dev/config.env` to match how *your* registry tags dev-env
images. Always overridable per-run with `prepare --image <full-ref>`. The image is
pulled automatically on the first `verify`/build (via `sr_ensure_docker`).

## How conflict resolution works (for Claude)

1. `prepare` cherry-picks and records the conflicted file list. If clean, skip to
   `verify`.
2. `pull <dir>` `rget`s each conflicted file (with its `<<<<<<<`/`>>>>>>>` markers)
   into `<dir>` on **your local machine**. Open them with Read/Edit.
3. **Resolve every marker** — decide the correct merged content for the release
   branch (it is *not* always "take main's version"; the branch may lack APIs the
   PR assumed, so adapt the hunk). Remove all `<<<<<<<`, `=======`, `>>>>>>>` lines.
4. `resolve <dir>` `rput`s them back and `git add`s them. It **greps for leftover
   markers and refuses** to advance if any remain — so a half-resolved file can't
   slip through.
5. `continue` finishes the cherry-pick (commit message keeps `(cherry picked from
   commit …)` via `-x`).

## Verify depth

`verify` honors "build + related unit tests":
- **Build**: auto-detects FE (`fe/`, `java-extensions/`) and/or BE (`be/`, `gensrc/`)
  from the backport commit and builds only those, **on the branch image**. Force with
  `--fe`/`--be`; skip with `--no-build`.
- **Tests**: FE test classes changed by the PR (`*Test.java`) are run automatically
  via `-Dtest=…`. For BE (`*_test.cpp`) or to target a specific suite, pass
  `--be-test '<gtest_filter>'` / `--fe-test '<mvn args>'`. Skip with `--no-test`.

A build/UT run takes minutes — launch `verify` with `run_in_background: true` and
let the completion notification (real exit code) tell you it finished; **don't
blind-poll the log** (see sr-build for why). Exit 0 = pass.

## Notes for the agent

- **`prepare` re-execs itself** with `SR_PROFILE=<the new profile>` to run the
  cherry-pick in the profile's container. Every command *after* `prepare` needs
  that `SR_PROFILE=<name>` prefix (the name is printed by `prepare` / `list`).
- **Not pushed automatically** (your chosen workflow): the skill stops at a verified
  local commit on `backport/<target>/pr-<N>`. Review `diff`, then `push --yes`
  yourself, or open the PR from the pushed branch.
- **Cherry-pick of a non-squashed PR**: the script uses the PR's `merge_commit_sha`.
  StarRocks squash-merges, so that's a normal commit. If a PR was merged as a true
  merge commit, pass `--oid <the real change commit>` instead.
- If the dev host can't reach `github.com` to fetch the commit, fetch it into
  `origin` first (it's usually already there), or the cherry-pick will report a bad
  object — re-run after fetching.
- For several backports at once, each is its own profile/worktree/container — run
  them in parallel exactly like any other `SR_PROFILE`-scoped work.
