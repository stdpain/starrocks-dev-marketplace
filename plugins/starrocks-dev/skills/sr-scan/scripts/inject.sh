#!/usr/bin/env bash
# sr-scan / inject.sh — fault-injection toolbox to REPRODUCE a suspected bug on the dev
# cluster (brought up by sr-deploy). Pick the lightest method that faithfully forces the
# error path you found while scanning:
#
#   failpoint  StarRocks-native, best for INTERNAL error paths (alloc/IO/RPC failure,
#              early return) that are hard to hit from SQL. Toggled at runtime via SQL.
#   syscall    attach strace to the live BE/FE and inject an errno/return/delay into a
#              libc syscall (EIO on pwrite, ENOMEM on mmap, …). Portable, no rebuild.
#   kfail      Linux kernel fault injection (failslab / fail_page_alloc / fail_make_request
#              / fail_function) scoped to the BE's tasks via debugfs. Needs a fault-
#              injection kernel + root on the HOST.
#   ebpf       run a bpftrace program against the BE/FE to OBSERVE the path (or inject via
#              kfunc override). Good for confirming a race/ordering hypothesis.
#
# Every method that needs a trigger reuses sr-diagnose's repro.sh to fire the SQL and watch
# be.out/fe.log for a signature: setup injection -> repro.sh --sql .. --match .. -> teardown.
# For a plain SQLTest/gtest with NO injection, just call repro.sh directly.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"
REPRO="$PLUGIN_ROOT/skills/sr-diagnose/scripts/repro.sh"
DEPLOY="$PLUGIN_ROOT/skills/sr-deploy/scripts/deploy.sh"
DEF_MATCH='SIG(SEGV|ABRT|BUS)|Check failed|terminate called|AddressSanitizer|core dumped|\*\*\* Aborted|E[0-9]{4} |status_code|InternalError|Status::|exception'

usage() {
  cat >&2 <<'EOF'
usage: inject.sh <method> <args>

failpoint check                       is the running BE built with failpoint support?
failpoint grammar                     show the FE failpoint statement syntax (from source)
failpoint list [pattern]              list failpoints/syncpoints registered in BE source
failpoint run --enable '<SQL>' --disable '<SQL>' --sql <trigger.sql> [--match RE]
            enable a failpoint, fire the SQL trigger, watch logs, then ALWAYS disable.
            Build the enable/disable SQL from `grammar` + `list` (names differ per version).

syscall --proc be|fe --syscall <name> (--errno EIO|--retval N|--delay-exit US) [--when EXPR]
        --sql <trigger.sql> [--match RE] [--timeout S]
            attach strace to the live BE/FE, inject into <name> while firing the trigger.
            e.g. force a write failure:  --proc be --syscall pwrite64 --errno EIO --when 3

kfail --type failslab|fail_page_alloc|fail_make_request|fail_function [--func NAME --retval V]
      [--probability 0-100] [--times N] --sql <trigger.sql> [--match RE]
            scope a Linux kernel fault to the BE's tasks (debugfs), fire the trigger, watch,
            then reset. Runs on the HOST as root; needs a fault-injection-enabled kernel.

ebpf --script <prog.bt> [--proc be|fe] [--duration S] [--sql <trigger.sql>] [--match RE]
            run a bpftrace program (uploaded) to observe/inject; optionally fire a trigger.

Prereqs: a cluster up via sr-deploy (`bash skills/sr-deploy/scripts/deploy.sh up`). Confirmed
bugs go to record.sh.
EOF
  exit "${1:-2}"
}

# pgrep snippet for a role, used inside remote scripts.
_pg() { [[ "$1" == fe ]] && echo "pgrep -f com.starrocks.StarRocksFE | head -1" || echo "pgrep -x starrocks_be | head -1"; }

# run repro.sh for the trigger+watch part (cluster already up, no build).
fire_and_watch() { # <trigger.sql> <match>
  local sql="$1" match="$2"
  [[ -f "$sql" ]] || sr_die "trigger SQL not found: $sql"
  bash "$REPRO" --sql "$sql" --match "$match"
}

method="${1:-}"; [[ -n "$method" ]] || usage 0; shift || true

case "$method" in
# ───────────────────────────── failpoint ─────────────────────────────
failpoint)
  sub="${1:-}"; shift || true
  case "$sub" in
    check)
      sr_log "checking failpoint support in the BE source + build ..."
      rsrc "echo '── build flag ──'; grep -rnE -i 'fault[_-]?injection|FIU_ENABLE|ENABLE_FAULT_INJECTION|WITH_FAULT' build.sh cmake* CMakeLists.txt be/CMakeLists.txt 2>/dev/null | head -10 || true
echo '── failpoint framework present ──'; ls be/src/util/failpoint/ 2>/dev/null || git ls-files 'be/src/**fail_point*' 2>/dev/null | head
echo '── note ──'; echo 'Failpoints only fire if the BE was built with the fault-injection flag (often a Debug/Asan or a --with-fault-injection build). A Release build typically compiles them out.'"
      ;;
    grammar)
      sr_log "FE failpoint statement grammar (use the exact tokens you see here) ..."
      rsrc "grep -rnE -i 'FAILPOINT|FailPoint' fe/fe-core/src/main/java/com/starrocks/sql/parser/StarRocks.g4 fe/fe-core/src/main/java/com/starrocks/sql/ast/*FailPoint* 2>/dev/null | head -40 || true
echo '── parser rule ──'; awk '/[Ff]ailpoint|FAILPOINT/{print NR\": \"\$0}' fe/fe-core/src/main/java/com/starrocks/sql/parser/StarRocks.g4 2>/dev/null | head -30 || true"
      ;;
    list)
      pat="${1:-}"
      sr_log "failpoints / sync points registered in BE source${pat:+ matching '$pat'} ..."
      rsrc "echo '── DEFINE_FAIL_POINT / triggers ──'; git grep -nE 'DEFINE_FAIL_POINT|FAIL_POINT_TRIGGER(_RETURN|_EXECUTE)?\\(' -- be/src 2>/dev/null | ${pat:+grep -i '$pat' |} head -60
echo '── sync points ──'; git grep -nE 'SYNC_POINT|TEST_SYNC_POINT' -- be/src 2>/dev/null | ${pat:+grep -i '$pat' |} head -30"
      ;;
    run)
      EN=""; DIS=""; SQL=""; MATCH="$DEF_MATCH"
      while [[ $# -gt 0 ]]; do case "$1" in
        --enable) EN="$2"; shift 2 ;; --disable) DIS="$2"; shift 2 ;;
        --sql) SQL="$2"; shift 2 ;; --match) MATCH="$2"; shift 2 ;;
        *) sr_die "failpoint run: unknown arg '$1'" ;; esac; done
      [[ -n "$EN" && -n "$SQL" ]] || sr_die "failpoint run needs --enable '<SQL>' and --sql <trigger> (and ideally --disable)"
      sr_log "enabling failpoint: $EN"
      bash "$DEPLOY" sql "$EN" || sr_die "enable failed — check the syntax against: inject.sh failpoint grammar (and that the BE has failpoint support: inject.sh failpoint check)"
      rc=0
      fire_and_watch "$SQL" "$MATCH" || rc=$?
      if [[ -n "$DIS" ]]; then sr_log "disabling failpoint: $DIS"; bash "$DEPLOY" sql "$DIS" || sr_log "WARN: disable failed — disable it manually so it doesn't affect later runs"; fi
      exit $rc
      ;;
    *) usage ;;
  esac
  ;;

# ───────────────────────────── syscall (strace) ─────────────────────────────
syscall)
  PROC=be; SYS=""; ERRNO=""; RETVAL=""; DELAY=""; WHEN=""; SQL=""; MATCH="$DEF_MATCH"; TMO=120
  while [[ $# -gt 0 ]]; do case "$1" in
    --proc) PROC="$2"; shift 2 ;; --syscall) SYS="$2"; shift 2 ;;
    --errno) ERRNO="$2"; shift 2 ;; --retval) RETVAL="$2"; shift 2 ;;
    --delay-exit) DELAY="$2"; shift 2 ;; --when) WHEN="$2"; shift 2 ;;
    --sql) SQL="$2"; shift 2 ;; --match) MATCH="$2"; shift 2 ;; --timeout) TMO="$2"; shift 2 ;;
    *) sr_die "syscall: unknown arg '$1'" ;; esac; done
  [[ -n "$SYS" && -n "$SQL" ]] || sr_die "syscall needs --syscall <name> and --sql <trigger>"
  [[ -n "$ERRNO" || -n "$RETVAL" || -n "$DELAY" ]] || sr_die "give an injection: --errno <E> | --retval <N> | --delay-exit <us>"
  inj="inject=$SYS"
  [[ -n "$ERRNO" ]]  && inj="$inj:error=$ERRNO"
  [[ -n "$RETVAL" ]] && inj="$inj:retval=$RETVAL"
  [[ -n "$DELAY" ]]  && inj="$inj:delay_exit=$DELAY"
  [[ -n "$WHEN" ]]   && inj="$inj:when=$WHEN"
  sr_ensure_docker
  sr_log "attaching strace to $PROC with $inj ..."
  # Start strace in the BE/FE's namespace (rsrc = inside the container when SR_DOCKER set),
  # detached, writing to a temp file; record its pid so we can stop it after the trigger.
  start=$(rsrc "pid=\$($(_pg "$PROC")); [ -n \"\$pid\" ] || { echo NO_PROC; exit 0; }
command -v strace >/dev/null 2>&1 || { echo NO_STRACE; exit 0; }
rm -f /tmp/sr_inject.out /tmp/sr_inject.pid
setsid strace -f -p \$pid -e trace=$SYS -e $inj -o /tmp/sr_inject.out >/dev/null 2>&1 &
echo \$! > /tmp/sr_inject.pid; sleep 1
if kill -0 \$(cat /tmp/sr_inject.pid) 2>/dev/null; then echo ATTACHED \$pid; else echo ATTACH_FAILED; fi")
  case "$start" in
    *NO_PROC*)      sr_die "no $PROC process found — is the cluster up? (bash $DEPLOY up)";;
    *NO_STRACE*)    sr_die "strace not installed where the $PROC runs. Install it (the dev-env image), or use a failpoint instead.";;
    *ATTACH_FAILED*) sr_die "strace could not attach (needs CAP_SYS_PTRACE). Add '--cap-add=SYS_PTRACE' to SR_DOCKER_RUN_OPTS and recreate the container, or set kernel.yama.ptrace_scope=0 on the host.";;
    *ATTACHED*)     sr_log "strace attached ($start).";;
    *)              sr_die "unexpected strace start state: $start";;
  esac
  rc=0
  fire_and_watch "$SQL" "$MATCH" || rc=$?
  sr_log "detaching strace + injection summary:"
  rsrc "kill \$(cat /tmp/sr_inject.pid 2>/dev/null) 2>/dev/null; sleep 1; echo '── strace inject log (tail) ──'; tail -n 30 /tmp/sr_inject.out 2>/dev/null; grep -c 'injected' /tmp/sr_inject.out 2>/dev/null | sed 's/^/injected calls: /'" || true
  exit $rc
  ;;

# ───────────────────────────── kfail (kernel fault injection) ─────────────────────────────
kfail)
  TYPE=""; FUNC=""; RETVAL=""; PROB=100; TIMES=1; SQL=""; MATCH="$DEF_MATCH"
  while [[ $# -gt 0 ]]; do case "$1" in
    --type) TYPE="$2"; shift 2 ;; --func) FUNC="$2"; shift 2 ;; --retval) RETVAL="$2"; shift 2 ;;
    --probability) PROB="$2"; shift 2 ;; --times) TIMES="$2"; shift 2 ;;
    --sql) SQL="$2"; shift 2 ;; --match) MATCH="$2"; shift 2 ;;
    *) sr_die "kfail: unknown arg '$1'" ;; esac; done
  [[ -n "$TYPE" && -n "$SQL" ]] || sr_die "kfail needs --type <fault> and --sql <trigger>"
  [[ "$TYPE" != fail_function || ( -n "$FUNC" && -n "$RETVAL" ) ]] || sr_die "--type fail_function needs --func NAME and --retval V"
  # Setup runs on the HOST (debugfs is host-kernel state; the BE's IO/alloc go through the
  # host kernel even when it runs in a container). The BE host-pid is visible from the host.
  sr_log "setting up kernel fault '$TYPE' scoped to the BE tasks (host, sudo) ..."
  setup=$(rsh "sudo -n bash -s" <<RS
set -e
D=/sys/kernel/debug; F=\$D/$TYPE
[ -d "\$F" ] || { echo "NO_FAULT \$F not present — kernel lacks this fault injector or debugfs is unmounted"; exit 0; }
pid=\$(pgrep -x starrocks_be | head -1); [ -n "\$pid" ] || { echo NO_PROC; exit 0; }
echo $PROB > "\$F/probability"; echo $TIMES > "\$F/times"; echo -1 > "\$F/interval" 2>/dev/null || true
echo 0 > "\$F/space" 2>/dev/null || true; echo 1 > "\$F/task-filter" 2>/dev/null || true
echo 2 > "\$F/verbose" 2>/dev/null || true
if [ "$TYPE" = fail_function ]; then echo "$FUNC" > "\$F/inject" 2>/dev/null || { echo "NO_FUNC $FUNC not error-injectable (needs ALLOW_ERROR_INJECTION)"; exit 0; }
  printf '%s %s\n' "$FUNC" "$RETVAL" > "\$F/$FUNC/retval" 2>/dev/null || echo "$RETVAL" > "\$F/inject"; fi
for t in /proc/\$pid/task/*; do echo 1 > "\$t/make-it-fail" 2>/dev/null || true; done
echo "ARMED pid=\$pid threads=\$(ls /proc/\$pid/task | wc -l)"
RS
)
  case "$setup" in
    *NO_FAULT*) sr_die "$setup. Need a kernel with CONFIG_FAULT_INJECTION + CONFIG_FAILSLAB/_PAGE_ALLOC/_MAKE_REQUEST (and CONFIG_FUNCTION_ERROR_INJECTION for fail_function).";;
    *NO_PROC*)  sr_die "no starrocks_be visible on the host — is the cluster up?";;
    *NO_FUNC*)  sr_die "$setup";;
    *ARMED*)    sr_log "$setup";;
    *)          sr_die "kfail setup state unclear: $setup";;
  esac
  rc=0
  fire_and_watch "$SQL" "$MATCH" || rc=$?
  sr_log "resetting kernel fault injection ..."
  rsh "sudo -n bash -s" <<RS || true
D=/sys/kernel/debug; F=\$D/$TYPE
pid=\$(pgrep -x starrocks_be | head -1)
[ -n "\$pid" ] && for t in /proc/\$pid/task/*; do echo 0 > "\$t/make-it-fail" 2>/dev/null || true; done
echo 0 > "\$F/probability" 2>/dev/null || true; echo 0 > "\$F/task-filter" 2>/dev/null || true
RS
  exit $rc
  ;;

# ───────────────────────────── ebpf (bpftrace) ─────────────────────────────
ebpf)
  SCRIPT=""; PROC=be; DUR=20; SQL=""; MATCH="$DEF_MATCH"
  while [[ $# -gt 0 ]]; do case "$1" in
    --script) SCRIPT="$2"; shift 2 ;; --proc) PROC="$2"; shift 2 ;; --duration) DUR="$2"; shift 2 ;;
    --sql) SQL="$2"; shift 2 ;; --match) MATCH="$2"; shift 2 ;;
    *) sr_die "ebpf: unknown arg '$1'" ;; esac; done
  [[ -f "$SCRIPT" ]] || sr_die "ebpf needs --script <prog.bt> (a bpftrace program)"
  # bpftrace needs the HOST kernel + root; run on the host. $PID is exposed to the program
  # as the env var SR_BE_PID so the .bt can filter on it (e.g. /pid == $SR_BE_PID/).
  sr_log "running bpftrace ($SCRIPT) for ${DUR}s on the host ..."
  b64=$(base64 < "$SCRIPT" | tr -d '\n')
  rsh "command -v bpftrace >/dev/null 2>&1 || { echo NO_BPFTRACE; exit 0; }" | grep -q NO_BPFTRACE \
    && sr_die "bpftrace not installed on the host — install bpftrace (needs root + a BTF/kernel-headers kernel)."
  # start bpftrace detached, capturing to a temp file
  rsh "sudo -n bash -c 'pid=\$(pgrep -x starrocks_be|head -1); echo $b64 | base64 -d > /tmp/sr_inject.bt; rm -f /tmp/sr_bpf.out; SR_BE_PID=\$pid setsid timeout ${DUR}s bpftrace /tmp/sr_inject.bt > /tmp/sr_bpf.out 2>&1 & echo started pid=\$pid'" \
    || sr_die "failed to launch bpftrace (need passwordless sudo on the host)."
  sleep 2
  rc=0
  if [[ -n "$SQL" ]]; then fire_and_watch "$SQL" "$MATCH" || rc=$?; else sr_log "observing for ${DUR}s (no SQL trigger) ..."; sleep "$DUR"; fi
  sr_log "── bpftrace output ──"
  rsh "sleep 1; cat /tmp/sr_bpf.out 2>/dev/null" || true
  exit $rc
  ;;

-h|--help|help) usage 0 ;;
*) sr_die "unknown method '$method' (failpoint|syscall|kfail|ebpf; see --help)" ;;
esac
