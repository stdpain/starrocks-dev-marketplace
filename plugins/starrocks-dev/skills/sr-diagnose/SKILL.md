---
description: Triage a StarRocks issue, crash, or stack trace on the remote dev host — locate the implicated source, check whether it's an already-fixed/known issue, and if not, reproduce it (ASan build → run a trigger → capture the crash) and write out exact reproduction steps. Use when given a crash log, BE/FE stack trace, coredump backtrace, GitHub issue, or "why does X crash/fail". Builds on sr-connect/sr-build/sr-deploy/sr-test. Triggers — "diagnose this crash", "locate this stack trace", "is this a known issue", "reproduce this bug", "定位这个崩溃", "复现这个问题", "分析堆栈".
---

# StarRocks Diagnose & Reproduce

A triage playbook for StarRocks failures, run against the remote dev host. Turns a
crash / stack / issue into: **(1) located source**, **(2) known-or-new verdict**,
**(3) a verified reproduction with steps** when it's new.

Work the four phases in order. Each has a helper script under `scripts/`; the
reasoning between them is yours.

## Phase 1 — Capture & locate

Save the raw crash/stack/issue text to a file (or pipe it), then:

```bash
bash scripts/analyze.sh /tmp/crash.txt      # or:  pbpaste | bash scripts/analyze.sh -
```
`analyze.sh` extracts the **crash signature** (signal, `Check failed`, exception,
`Memory exceed`, etc.), pulls out the implicated **frames** (C++ `ns::Class::method`
and `file.cpp:NN`, Java `com.starrocks....`), maps each to a file in `$SR_SRC` on
the remote, and prints `git blame` + the last commit that touched each line. If the
stack has only raw addresses, pass the BE binary to symbolize them:
```bash
bash scripts/analyze.sh /tmp/crash.txt --addr2line
```
> Symbolization uses **`llvm-addr2line`** when present — GNU `addr2line` is
> extremely slow on StarRocks' compressed `.debug_*` sections. If only GNU is
> available, the script decompresses the sections once (`objcopy
> --decompress-debug-sections`, cached) and reuses that copy.

Read its output and form a hypothesis: which component (FE/BE), which file/function,
what kind of bug (null deref, OOM, race, overflow, logic).

## Phase 2 — Is it already known?

```bash
bash scripts/known.sh 'SegmentIterator::next'      # a symbol/message from the signature
bash scripts/known.sh --file be/src/storage/foo.cpp
```
`known.sh` searches the local repo history for fixes (`git log --all --grep`,
commits touching the implicated files since the current HEAD's merge-base) and
prints candidate fix commits. **Also** search upstream issues/PRs with WebSearch
(`StarRocks <signature/symbol> crash`, `site:github.com/StarRocks/starrocks <msg>`)
— the script can't reach the network. If a fix commit clearly matches, report it
(commit, PR, whether the checkout already contains it) and stop — no need to reproduce.

## Phase 3 — Reproduce (only if not known)

```bash
bash scripts/repro.sh --build asan --sql /tmp/repro.sql --match 'SIGSEGV|Check failed'
bash scripts/repro.sh --build asan --gtest 'SegmentIteratorTest.*' --match 'AddressSanitizer'
```
`repro.sh`: builds with the chosen `BUILD_TYPE` (ASan recommended — it surfaces
memory bugs that a Release build hides), brings the cluster up via `sr-deploy`,
snapshots the logs, fires the **trigger** (a `.sql` file run through the FE, or a BE
gtest filter), then watches `be.out`/`fe.log` for the `--match` signature and prints
the captured crash excerpt. Exit 0 = reproduced, non-0 = not reproduced.

Iterate the trigger until it reliably fires (minimize the SQL/case to the smallest
input that still crashes). If a Release build won't reproduce, retry with
`--build asan` or `BUILD_TYPE=Debug`.

## Phase 4 — Report

Produce a short report:
- **Signature** — the exact crash line(s).
- **Location** — file:line + function + likely root cause from Phase 1.
- **Known?** — fix commit/PR if found, else "appears new on `<branch>@<sha>`".
- **Reproduction steps** — build flags, cluster setup, the minimal trigger
  (paste the SQL / gtest filter), and the observed crash. Make it copy-pasteable so
  someone else can rerun it.

## Notes for the agent

- Don't reproduce a known/already-fixed crash — Phase 2 first; it's cheap.
- ASan builds are slow and RAM-hungry but catch the real bug; prefer them for
  memory crashes. Check `sr-connect doctor.sh` for disk/RAM headroom first.
- BE crash stacks land in `output/be/log/be.out` (signal + frames) and coredumps
  per the host limit; FE exceptions in `output/fe/log/fe.log`/`fe.warn.log`.
- Keep the repro **minimal**: strip the SQL to the fewest statements that still
  crash; that minimal input *is* the deliverable.
- If reproduction needs specific data/config, capture that in the steps too
  (table DDL, `be.conf` knobs, session variables).
