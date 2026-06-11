---
description: Run StarRocks tests on the remote dev host over SSH — FE unit tests (Maven), BE unit tests (gtest), Java-extension unit tests, and SQL regression tests against a running cluster. Use to validate a change after sr-build, run a single test class/case, or reproduce a CI test failure remotely. Requires sr-connect; regression tests also require a cluster from sr-deploy. Triggers — "run the FE/BE unit tests", "run a single test", "gtest filter", "run regression tests", "跑单测", "跑回归测试".
---

# StarRocks Remote Test

Runs StarRocks' test suites on the remote dev host (inside `SR_DOCKER` if set),
reusing the **sr-connect** connection. Wraps the repo's own runners so flags pass
straight through.

Prefix `SR_PROFILE=<name>` to run tests in a parallel profile's container/worktree.
See sr-connect → **Parallel work** (`workspace.sh`).

## Usage

```bash
bash scripts/test.sh fe                              # all FE unit tests (Maven)
bash scripts/test.sh fe --test com.starrocks.sql.SomeTest   # one FE class/method
bash scripts/test.sh be                              # all BE unit tests (gtest, ASan)
bash scripts/test.sh be --test util_json_test        # one BE test binary
bash scripts/test.sh be --gtest_filter 'JsonTest.*'  # gtest filter
bash scripts/test.sh be --module storage             # one BE module's tests
bash scripts/test.sh java-ext                        # Java extension UTs
bash scripts/test.sh regression [run.sh args...]     # SQL regression vs a live cluster
```

Any extra args after the suite name are forwarded verbatim to the underlying
runner. `BUILD_TYPE` is honored (env or `SR_BUILD_TYPE`).

## What each suite maps to

| suite | runner | notes |
|-------|--------|-------|
| `fe` | `./run-fe-ut.sh` | Maven-based. `--test <class>` for one class/method, `--filter` to skip, `-j N`. |
| `be` | `./run-be-ut.sh` | gtest. **Defaults to `BUILD_TYPE=ASAN`** (slow first build). `--test <name>`, `--gtest_filter`, `--module`, `--clean`. |
| `java-ext` | `./run-java-exts-ut.sh` | tests under `java-extensions/`. |
| `regression` | `cd test && ./run.sh` | end-to-end SQL tests; needs a **running cluster** and `test/conf/sr.conf` pointed at it. |

## Notes for the agent

- `fe`/`be`/`java-ext` build their own test targets from source — run them after
  the relevant **sr-build**, but they do **not** need a running cluster.
- `regression` **does** need a live cluster: run **sr-deploy** `up` first, and make
  sure `test/conf/sr.conf` has the right `fe_host`/`fe_query_port`/user (default
  dev cluster = `127.0.0.1` / `9030` / `root`, empty password). Edit it via
  sr-connect's `sr.sh --src`.
- Iterate fast: prefer `be --gtest_filter '<pattern>'` or `fe --test <class>` over
  a full suite — a full BE UT run is long.
- BE UT under ASan needs ample RAM/disk; if it OOMs or fails to link, check
  `sr-connect doctor.sh` (disk) and consider `BUILD_TYPE=Release bash scripts/test.sh be`.
- The script exits with the runner's real exit code, so a non-zero exit means real
  test failures — read the output above before retrying.
