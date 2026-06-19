---
description: Proactively hunt for bugs in StarRocks by statically scanning a module or a specific execution flow on the remote dev host, reasoning about what can go wrong on each path, and then PROVING the real ones by reproducing them — a SQLTest/regression case, a StarRocks failpoint, an strace syscall-error injection, a Linux kernel fault injection, or an eBPF probe — and recording every confirmed bug to a markdown report. Use when asked to audit/scan code for bugs (not triage an existing crash — that's sr-diagnose). Builds on sr-connect/sr-build/sr-deploy/sr-test and reuses sr-diagnose's repro.sh. Triggers — "scan this module for bugs", "audit be/src/storage for potential issues", "find bugs in the lake compaction flow", "扫描这个模块找 bug", "静态分析这段执行路径", "用 failpoint/错误注入复现这个问题", "ebpf 复现", "把复现的 bug 记录下来".
---

# StarRocks Static Bug Scan

Go *looking* for bugs (rather than reacting to a crash): take a **module** or a **specific
execution flow**, find the error-prone spots, decide which are real, **reproduce** them with
the lightest faithful method, and **record** each confirmed bug. Run against the remote dev
host. (Given a crash/stack you already have, use **sr-diagnose** instead.)

Work the four phases in order; the helper scripts are under `scripts/`, the reasoning between
them is yours.

## Phase 1 — Scope & scan

Pick a tight scope — a module dir, a file set, or a function's flow — and scan it:

```bash
S=scripts/scan.sh
bash $S be/src/storage/lake --hooks            # a module + available repro hooks
bash $S --flow ChunkAggregator::aggregate      # files on/around one function
bash $S --files be/src/exprs/cast_expr.cpp     # specific files
```

`scan.sh` greps the source on the dev host for high-signal bug classes (mem-unsafe ops,
narrowing casts, deref-after-cast, throwing conversions, `.at()`/empty-container access,
unchecked `StatusOr`, divide-by-variable, size arithmetic, NPE/boxing/cast smells in Java,
…), grouped by class with `file:line`. `--hooks` also lists the **failpoints**, **sync
points**, and **existing tests** in scope — your reproduction levers. Output is a *worklist*,
not a verdict: **most hits are fine.**

## Phase 2 — Analyze the path & hypothesize

For each candidate worth a look, read the code and follow the flow (use sr-connect to read
remote source: `bash ../sr-connect/scripts/sr.sh --src 'sed -n "120,180p" be/src/...'`).
Decide, concretely:
- **Is it reachable?** What input / state / config / concurrency reaches this line?
- **What goes wrong?** null deref, overflow/underflow, divide-by-zero, OOB, use-after-move,
  unchecked error swallowed, lock-order/race, resource leak, unhandled exception.
- **How would I trigger it?** the smallest SQL, or which internal error to inject.

Discard the false positives. Keep a short hypothesis per real candidate: *“if `input_rowsets`
is empty, `compaction_task.cpp:142` divides by zero.”* That hypothesis dictates the method.

## Phase 3 — Reproduce (prove it)

Pick the **lightest method that faithfully forces the path**. Build with **ASan**
(`--build asan`) when chasing a memory bug — it turns latent corruption into a clean abort.

| The bug needs… | Use | How |
|---|---|---|
| only specific **SQL/data** | **SQLTest / regression** | `bash ../sr-diagnose/scripts/repro.sh --build asan --sql /tmp/t.sql --match '...'`  · or a regression case via `../sr-test/scripts/test.sh regression` · or a gtest with `--gtest '...'` |
| an **internal error path** (alloc/IO/RPC failure, early return) | **failpoint** | `bash scripts/inject.sh failpoint check` → `grammar` → `list` to get names/syntax, then `inject.sh failpoint run --enable '<SQL>' --disable '<SQL>' --sql trigger.sql` |
| a **syscall** to fail (EIO write, ENOMEM mmap, short read) | **syscall (strace)** | `inject.sh syscall --proc be --syscall pwrite64 --errno EIO --when 3 --sql trigger.sql` |
| kernel-level **alloc/IO** failure | **kfail** | `inject.sh kfail --type fail_make_request --probability 100 --sql trigger.sql` (host root + fault-injection kernel) |
| to **confirm a race/ordering** or watch a path | **eBPF** | `inject.sh ebpf --script probe.bt --sql trigger.sql` |

Every `inject.sh` method sets up the fault, fires the trigger through **repro.sh** (which
watches `be.out`/`fe.log` for `--match`), then tears the fault down. **Minimize the trigger**
to the fewest statements that still fire — that minimal input is the deliverable. Iterate
until it reproduces reliably; if a Release build won't show it, rebuild ASan/Debug.

## Phase 4 — Record

Log every **reproduced** bug (and clearly-real ones you couldn't yet trigger, as `suspected`):

```bash
bash scripts/record.sh add \
  --title "lake compaction divides by zero on empty rowset" --status reproduced \
  --component be/storage/lake --location be/src/storage/lake/compaction_task.cpp:142 \
  --class divide-by-zero --method "syscall:EIO" --signature "F0612 ... Check failed: n > 0" \
  --trigger /tmp/repro.sql --root-cause "input_rowsets can be empty when ..." \
  --fix "guard n==0 before the division"
bash scripts/record.sh list
```

Each entry is self-contained (location, root cause, method, embedded minimal trigger), so
someone else can re-run it. Default report: `./bug-scan-findings.md` (override with `--file`).

## Notes for the agent

- **Prereqs.** sr-connect configured; for any runtime reproduction, a cluster up via
  `bash ../sr-deploy/scripts/deploy.sh up`. Check `sr-connect doctor.sh` for RAM/disk before
  an ASan build.
- **Precision over recall.** A scan that reports 3 *real* bugs beats one that dumps 200
  candidates. The scan finds places to look; you decide, and only **reproduced** findings are
  high-confidence. Mark unproven ones `suspected`, never assert a bug you couldn't trigger.
- **Method capability gates** (the scripts tell you which is missing):
  - *failpoint* fires only if the BE was built with the fault-injection flag (`failpoint
    check`); a plain Release build compiles failpoints out. Names/syntax vary by version —
    always derive them from `grammar`/`list`.
  - *syscall* needs `strace` where the BE runs and `CAP_SYS_PTRACE` (add `--cap-add=SYS_PTRACE`
    to `SR_DOCKER_RUN_OPTS`, or set `kernel.yama.ptrace_scope=0`).
  - *kfail* needs a kernel with `CONFIG_FAULT_INJECTION` (+ `…FAILSLAB/_PAGE_ALLOC/_MAKE_REQUEST`,
    or `FUNCTION_ERROR_INJECTION` for `fail_function`) and passwordless sudo on the host.
  - *ebpf* needs `bpftrace` + root on the host; the BE pid is exposed to the `.bt` as
    `$SR_BE_PID` for filtering.
- **Always disable injection afterward** — `inject.sh` does this for you (failpoint disable,
  strace detach, kfail reset). If a run is interrupted, re-run the disable/reset so a leftover
  fault doesn't poison later tests.
- **Don't report a known/already-fixed bug.** Before recording, cross-check with sr-diagnose's
  `known.sh '<symbol>'` + a WebSearch of StarRocks issues/PRs.
- This skill **runs whatever SQL/commands you give it and injects faults** into the dev
  cluster — point it at a throwaway dev cluster, never a cluster you care about.
