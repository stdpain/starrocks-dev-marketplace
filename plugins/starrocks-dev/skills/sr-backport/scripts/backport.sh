#!/usr/bin/env bash
# Backport a merged PR to a release branch, resolving cherry-pick conflicts and
# verifying the result on the dev host with the BRANCH-MATCHING dev-env image.
#
# Model (consistent with the rest of the plugin):
#   - You give an ORIGINAL (merged-to-main) PR link + a TARGET branch (branch-4.1).
#   - The skill resolves the PR's squash-merge commit, creates an isolated worktree
#     PROFILE pinned to the matching dev-env image (branch-4.1 -> ...:branch-4.1),
#     and cherry-picks the commit there.
#   - On conflict it copies the conflicted files out so Claude resolves them, then
#     pushes them back and continues the cherry-pick.
#   - `verify` builds the changed FE/BE on that branch image and runs related UTs.
#   - Nothing is pushed back to GitHub: you review the diff and push yourself
#     (`push` exists but is gated behind an explicit confirmation).
#
#   backport.sh prepare --pr <url|#> --branch <target> [--repo o/r] [--oid <sha>] [--image <img>] [--profile <name>]
#   SR_PROFILE=<p> backport.sh pull      [<localdir>]
#   SR_PROFILE=<p> backport.sh resolve   [<localdir>]
#   SR_PROFILE=<p> backport.sh continue
#   SR_PROFILE=<p> backport.sh verify    [--fe] [--be] [--fe-test '<mvn args>'] [--be-test '<filter>'] [--no-build] [--no-test]
#   SR_PROFILE=<p> backport.sh diff | status
#   SR_PROFILE=<p> backport.sh push      [--remote origin] [--branch <name>] [--yes]
#   SR_PROFILE=<p> backport.sh cleanup   [--keep-src]
#   backport.sh list
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/srlib.sh"

BUILD_SH="$PLUGIN_ROOT/skills/sr-build/scripts/build.sh"
TEST_SH="$PLUGIN_ROOT/skills/sr-test/scripts/test.sh"
WORKSPACE_SH="$PLUGIN_ROOT/skills/sr-connect/scripts/workspace.sh"

# ---- small helpers -------------------------------------------------------------

# normalize_branch <input> — accept "4.1" / "branch-4.1" / "main"; emit the real
# branch name. A bare X.Y is shorthand for branch-X.Y (StarRocks release branches).
normalize_branch() {
  local b="$1"
  case "$b" in
    main|master)        printf '%s' "$b" ;;
    [0-9]*.[0-9]*)      printf 'branch-%s' "$b" ;;
    *)                  printf '%s' "$b" ;;
  esac
}

# image_base <ref> — strip the :tag (but not a registry :port) and any @digest.
image_base() {
  local ref="${1%%@*}"            # drop digest
  local last="${ref##*:}"
  if [[ "$last" == *"/"* || "$ref" != *:* ]]; then
    printf '%s' "$ref"            # last ':' is a registry port, or no tag at all
  else
    printf '%s' "${ref%:*}"
  fi
}

# derive_image <target-branch> — branch-matching dev-env image. The base repo
# comes from the (base profile's) SR_IMAGE; the TAG follows a convention you can
# configure with SR_BP_IMAGE_TPL (placeholders: {base}, {branch}, {ver}). Default
# template is '{base}:{branch}', e.g. registry/.../dev-env-ubuntu:branch-4.1.
# {ver} is the numeric version (branch-4.1 -> 4.1) for registries tagged that way:
#   SR_BP_IMAGE_TPL='{base}:{ver}'        -> ...:4.1
#   SR_BP_IMAGE_TPL='{base}:{ver}-latest' -> ...:4.1-latest
# main/master keep SR_IMAGE's own tag (usually :latest). Override per-run with --image.
derive_image() {
  local target="$1" base ver tpl
  base=$(image_base "${SR_IMAGE:-starrocks/dev-env-ubuntu:latest}")
  case "$target" in
    main|master) printf '%s' "${SR_IMAGE:-$base:latest}"; return 0 ;;
  esac
  ver="${target#branch-}"                     # branch-4.1 -> 4.1
  tpl="${SR_BP_IMAGE_TPL:-}"
  [[ -n "$tpl" ]] || tpl='{base}:{branch}'    # (literal braces can't go in a :- default)
  tpl="${tpl//\{base\}/$base}"
  tpl="${tpl//\{branch\}/$target}"
  tpl="${tpl//\{ver\}/$ver}"
  printf '%s' "$tpl"
}

# parse_pr <pr> <repo> — set OWNER REPO PRNUM from a URL or a bare number(+repo).
parse_pr() {
  local pr="$1" repo="${2:-}"
  if [[ "$pr" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    OWNER="${BASH_REMATCH[1]}"; REPO="${BASH_REMATCH[2]}"; PRNUM="${BASH_REMATCH[3]}"
  elif [[ "$pr" =~ ^([^/]+)/([^/#]+)#([0-9]+)$ ]]; then        # owner/repo#123
    OWNER="${BASH_REMATCH[1]}"; REPO="${BASH_REMATCH[2]}"; PRNUM="${BASH_REMATCH[3]}"
  elif [[ "$pr" =~ ^[0-9]+$ ]]; then
    [[ -n "$repo" && "$repo" == */* ]] || sr_die "--pr is a bare number; pass --repo owner/repo too."
    OWNER="${repo%%/*}"; REPO="${repo##*/}"; PRNUM="$pr"
  else
    sr_die "could not parse --pr '$pr' (use a PR URL, owner/repo#N, or a number + --repo)."
  fi
}

# gh_meta — query the GitHub REST API for PR <OWNER/REPO#PRNUM>. Sets
# OID / MERGED / PR_STATE / PR_TITLE / BASE_REF. Honors GITHUB_TOKEN/GH_TOKEN
# (needed for private repos / rate limits). Uses local python3 (no jq/gh needed).
gh_meta() {
  command -v python3 >/dev/null 2>&1 || sr_die "python3 not found locally — needed to read PR metadata, or pass --oid <sha> to skip."
  local url="https://api.github.com/repos/$OWNER/$REPO/pulls/$PRNUM"
  local tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  local out
  out=$(GH_URL="$url" GH_TOKEN_V="$tok" python3 - <<'PY'
import json,os,sys,shlex,urllib.request
url=os.environ["GH_URL"]; tok=os.environ.get("GH_TOKEN_V","")
req=urllib.request.Request(url, headers={"Accept":"application/vnd.github+json","User-Agent":"sr-backport"})
if tok: req.add_header("Authorization","Bearer "+tok)
try:
    d=json.load(urllib.request.urlopen(req,timeout=20))
except Exception as e:
    sys.stderr.write("api error: %s\n"%e); sys.exit(3)
def g(k,default=""):
    v=d.get(k); return default if v is None else v
def emit(k,v): print("%s=%s"%(k,shlex.quote(str(v))))   # shell-safe: titles have spaces/metachars
emit("OID",g("merge_commit_sha"))
emit("MERGED","1" if d.get("merged") else "0")
emit("PR_STATE",g("state"))
emit("BASE_REF",(d.get("base",{}) or {}).get("ref",""))
emit("PR_TITLE",g("title").replace("\n"," "))
PY
  ) || sr_die "GitHub API call failed for $OWNER/$REPO#$PRNUM (rate limit? private repo without token? network?). Pass --oid <sha> to skip metadata."
  eval "$out"
}

# bp_meta_dir / load_bp — the active profile's backport metadata.
bp_meta_dir() { printf '%s' "$SR_CFG_DIR"; }
BP_FILE=""
load_bp() {
  [[ -n "${SR_PROFILE:-}" ]] || sr_die "set SR_PROFILE=<backport-profile> for this command (see 'backport.sh list')."
  BP_FILE="$SR_CFG_DIR/backport.env"
  [[ -f "$BP_FILE" ]] || sr_die "no backport metadata for profile '$SR_PROFILE' — run 'backport.sh prepare' first."
  # shellcheck source=/dev/null
  source "$BP_FILE"
}

require_output_exists() { :; }   # reserved

# ---- prepare (host side: metadata + worktree) ----------------------------------

cmd_prepare() {
  local pr="" branch="" repo="" oid="" image="" profile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr)      pr="$2"; shift 2 ;;
      --branch)  branch="$2"; shift 2 ;;
      --repo)    repo="$2"; shift 2 ;;
      --oid)     oid="$2"; shift 2 ;;
      --image)   image="$2"; shift 2 ;;
      --profile) profile="$2"; shift 2 ;;
      *) sr_die "prepare: unknown option '$1'" ;;
    esac
  done
  [[ -n "$pr" ]]     || sr_die "prepare: --pr <url|#> is required."
  [[ -n "$branch" ]] || sr_die "prepare: --branch <target> is required (e.g. branch-4.1 or 4.1)."
  [[ -z "${SR_PROFILE:-}" ]] || sr_die "do not set SR_PROFILE for 'prepare' — it CREATES the profile."

  parse_pr "$pr" "$repo"
  local target; target=$(normalize_branch "$branch")
  local repo_url="https://github.com/$OWNER/$REPO.git"

  # Resolve the commit to cherry-pick (the PR's squash-merge commit).
  if [[ -z "$oid" ]]; then
    gh_meta
    oid="$OID"
    [[ -n "$oid" && "$oid" != "None" ]] || sr_die "PR $OWNER/$REPO#$PRNUM has no merge_commit_sha — is it merged? Pass --oid <sha> for an explicit commit."
    [[ "$MERGED" == "1" ]] || sr_log "WARNING: PR #$PRNUM state=$PR_STATE merged=$MERGED — backporting an unmerged PR's merge_commit_sha may be wrong."
    sr_log "PR #$PRNUM \"$PR_TITLE\" (base $BASE_REF) -> merge commit ${oid:0:12}"
  else
    PR_TITLE="${PR_TITLE:-}"
  fi

  [[ -n "$image" ]] || image=$(derive_image "$target")
  [[ -z "$profile" ]] && profile="bp-${target#branch-}-pr${PRNUM}"
  profile=$(printf '%s' "$profile" | tr -c 'A-Za-z0-9._-' '-')

  sr_log "target branch : $target"
  sr_log "dev-env image : $image"
  sr_log "profile       : $profile"

  # Fetch the target branch tip from the canonical repo (avoids a stale origin),
  # use its SHA as the worktree base.
  sr_resolve_host_src
  local main_src="$SR_HOST_SRC"
  rsh "git -C '$main_src' rev-parse --is-inside-work-tree >/dev/null 2>&1" \
    || sr_die "$main_src is not a git work tree on the dev host (run sr-connect setup/doctor first)."
  sr_log "fetching $target from $repo_url ..."
  local base_sha
  base_sha=$(rsh "cd '$main_src' && git fetch --quiet '$repo_url' '$target' && git rev-parse FETCH_HEAD" 2>/dev/null)
  if [[ -z "$base_sha" ]]; then
    sr_log "direct fetch of '$target' failed; falling back to origin/$target ..."
    base_sha=$(rsh "cd '$main_src' && git fetch --quiet origin && git rev-parse 'origin/$target'" 2>/dev/null)
  fi
  if [[ -z "$base_sha" && -n "${SR_DOCKER:-}" ]]; then
    # Some dev hosts can only reach GitHub from INSIDE the dev container (the host's
    # only egress is a proxy that may be down). The base container shares this repo's
    # object DB (bind-mounted .git), so fetch there and resolve the SHA host-side.
    sr_log "host fetch unavailable; fetching '$target' via base container ($SR_DOCKER) ..."
    sr_ensure_docker >/dev/null 2>&1 || true
    rsrc "git fetch --quiet '$repo_url' '$target'" >/dev/null 2>&1
    base_sha=$(rsh "git -C '$main_src' rev-parse FETCH_HEAD" 2>/dev/null)
  fi
  [[ -n "$base_sha" ]] || sr_die "could not resolve target branch '$target' on the dev host (host fetch, origin/$target, and base-container fetch all failed)."
  sr_log "base ($target) = ${base_sha:0:12}"

  # Create the isolated profile: worktree on a fresh local branch off the target,
  # pinned to the branch-matching dev-env image.
  local local_branch="backport/$target/pr-$PRNUM"
  sr_log "creating worktree profile (branch $local_branch) ..."
  bash "$WORKSPACE_SH" create "$profile" --branch "$local_branch" --base "$base_sha" --image "$image" \
    || sr_die "workspace create failed for profile '$profile'."

  # Hand off to the cherry-pick phase IN the profile's context (re-exec so srlib
  # re-sources the new profile -> correct SR_SRC / SR_DOCKER / SR_IMAGE).
  # MUST clear the config-derived SR_* vars THIS process exported when it sourced
  # the base config (srlib uses `set -a`): the child inherits them as real env and
  # srlib treats pre-set SR_* as explicit overrides, which would SHADOW the
  # profile's config.env — making __pick run against the BASE profile's container
  # /source (e.g. sr-dev-main + /root/starrocks) instead of the worktree. Keep
  # SR_PROFILE / SR_CFG_BASE so the child resolves the right profile dir.
  unset $(compgen -v | grep '^SR_' | grep -vxE 'SR_PROFILE|SR_CFG_BASE' || true)
  SR_PROFILE="$profile" exec bash "$0" __pick \
    --repo "$OWNER/$REPO" --repo-url "$repo_url" --oid "$oid" --pr "$PRNUM" \
    --target "$target" --local-branch "$local_branch" --image "$image" --title "${PR_TITLE:-}"
}

# ---- __pick (profile side: cherry-pick) ----------------------------------------

cmd_pick() {
  local repo="" repo_url="" oid="" pr="" target="" local_branch="" image="" title=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;; --repo-url) repo_url="$2"; shift 2 ;;
      --oid) oid="$2"; shift 2 ;;   --pr) pr="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;; --local-branch) local_branch="$2"; shift 2 ;;
      --image) image="$2"; shift 2 ;;   --title) title="$2"; shift 2 ;;
      *) sr_die "__pick: unknown option '$1'" ;;
    esac
  done
  [[ -n "${SR_PROFILE:-}" ]] || sr_die "__pick must run with SR_PROFILE set (internal)."
  title="${title//\'/}"   # keep the backport.env single-quote heredoc safe

  sr_ensure_docker     # pull/create the branch-image container for this profile

  # Bring the commit into this worktree's object DB, then cherry-pick it. -x notes
  # the upstream commit in the message (StarRocks backport convention).
  sr_log "fetching commit ${oid:0:12} from $repo_url ..."
  rsrc "git fetch --quiet '$repo_url' '$oid' 2>/dev/null || true"
  sr_log "cherry-picking ${oid:0:12} onto $local_branch ..."
  rsrc "git -c core.editor=true cherry-pick -x '$oid'"
  local rc=$?

  # Record the conflict set (empty when the cherry-pick applied cleanly).
  local conflicts
  conflicts=$(rsrc "git diff --name-only --diff-filter=U" 2>/dev/null)
  printf '%s\n' "$conflicts" | sed '/^$/d' > "$SR_CFG_DIR/backport.conflicts"

  # Persist metadata for the later phases.
  ( umask 077; cat > "$SR_CFG_DIR/backport.env" <<EOF
BP_PR='$pr'
BP_OID='$oid'
BP_REPO='$repo'
BP_REPO_URL='$repo_url'
BP_TARGET='$target'
BP_LOCAL_BRANCH='$local_branch'
BP_IMAGE='$image'
BP_TITLE='$title'
EOF
  )

  echo
  if [[ "$rc" -eq 0 && -z "$(sed '/^$/d' "$SR_CFG_DIR/backport.conflicts")" ]]; then
    sr_log "✓ cherry-pick applied CLEANLY — no conflicts."
    _print_changed_summary
    cat >&2 <<EOF

Next: verify on the $target image, then review and push yourself:
  SR_PROFILE=$SR_PROFILE bash $0 verify
  SR_PROFILE=$SR_PROFILE bash $0 diff
EOF
  else
    sr_log "⚠ cherry-pick CONFLICTED — Claude must resolve these files:"
    sed 's/^/    /' "$SR_CFG_DIR/backport.conflicts" >&2
    _print_changed_summary
    cat >&2 <<EOF

Resolve loop:
  1. SR_PROFILE=$SR_PROFILE bash $0 pull <dir>     # copy conflicted files locally
  2. (Claude edits the files in <dir> — remove every <<<<<<< / ======= / >>>>>>> marker)
  3. SR_PROFILE=$SR_PROFILE bash $0 resolve <dir>  # push them back + git add, check for leftover markers
  4. SR_PROFILE=$SR_PROFILE bash $0 continue       # finish the cherry-pick
Then: SR_PROFILE=$SR_PROFILE bash $0 verify
EOF
  fi
}

# _print_changed_summary — what the backport touches (drives build/test choices).
_print_changed_summary() {
  local files; files=$(rsrc "git show --name-only --format= HEAD 2>/dev/null; git diff --name-only --diff-filter=U 2>/dev/null" | sed '/^$/d' | sort -u)
  [[ -z "$files" ]] && return 0
  local fe=0 be=0 f
  while IFS= read -r f; do
    case "$f" in
      fe/*|java-extensions/*|fe-core/*) fe=1 ;;
      be/*|gensrc/*)                    be=1 ;;
    esac
  done <<< "$files"
  sr_log "changed components: ${fe:+FE }${be:+BE }$([[ $fe == 0 && $be == 0 ]] && echo '(non-FE/BE)')"
}

# ---- pull / resolve / continue --------------------------------------------------

# default local conflict dir for a profile
_default_dir() { printf '%s' "${SR_BP_DIR:-$PWD/.sr-backport/$SR_PROFILE}"; }

cmd_pull() {
  load_bp
  local dir="${1:-$(_default_dir)}"
  local list="$SR_CFG_DIR/backport.conflicts"
  if [[ ! -s "$list" ]]; then
    sr_log "no conflicts recorded for '$SR_PROFILE' — nothing to pull. Proceed to: backport.sh verify"
    return 0
  fi
  mkdir -p "$dir"
  sr_resolve_host_src
  local f n=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    mkdir -p "$dir/$(dirname "$f")"
    rget "$SR_HOST_SRC/$f" "$dir/$f" || sr_die "failed to fetch $f from the dev host."
    n=$((n+1))
  done < "$list"
  sr_log "pulled $n conflicted file(s) to:"
  while IFS= read -r f; do [[ -n "$f" ]] && printf '    %s/%s\n' "$dir" "$f" >&2; done < "$list"
  cat >&2 <<EOF
Claude: open each file, resolve the <<<<<<< / ======= / >>>>>>> markers (keep the
correct merged result), then run:
  SR_PROFILE=$SR_PROFILE bash $0 resolve "$dir"
EOF
}

cmd_resolve() {
  load_bp
  local dir="${1:-$(_default_dir)}"
  local list="$SR_CFG_DIR/backport.conflicts"
  [[ -s "$list" ]] || { sr_log "no conflicts recorded — nothing to resolve."; return 0; }
  [[ -d "$dir" ]]  || sr_die "local dir '$dir' not found — run 'backport.sh pull $dir' first."
  sr_resolve_host_src
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -f "$dir/$f" ]] || sr_die "expected resolved file missing: $dir/$f"
    rput "$dir/$f" "$SR_HOST_SRC/$f" || sr_die "failed to push $f back to the dev host."
  done < "$list"
  # Stage them, then refuse to advance if any conflict marker survived.
  local files_q="" g
  while IFS= read -r g; do [[ -n "$g" ]] && files_q+=" $(printf '%q' "$g")"; done < "$list"
  rsrc "git add --$files_q"
  local left
  left=$(rsrc "git --no-pager grep -nE '^(<<<<<<<|=======|>>>>>>>)' --$files_q 2>/dev/null")
  if [[ -n "$left" ]]; then
    sr_log "⚠ leftover conflict markers — NOT resolved yet:"
    printf '%s\n' "$left" | sed 's/^/    /' >&2
    sr_die "fix the markers in $dir and re-run resolve."
  fi
  sr_log "✓ pushed back + staged $(grep -c . "$list") file(s); no leftover markers."
  sr_log "next: SR_PROFILE=$SR_PROFILE bash $0 continue"
}

cmd_continue() {
  load_bp
  # Already committed (clean cherry-pick or a prior continue)? then no-op.
  if ! rsrc "test -f \"\$(git rev-parse --git-path CHERRY_PICK_HEAD)\""; then
    sr_log "no cherry-pick in progress (already committed). HEAD:"
    rsrc "git --no-pager log -1 --oneline" >&2
    return 0
  fi
  rsrc "git -c core.editor=true cherry-pick --continue" \
    || sr_die "cherry-pick --continue failed — unresolved files remain? Check: SR_PROFILE=$SR_PROFILE bash $0 status"
  sr_log "✓ cherry-pick committed:"
  rsrc "git --no-pager log -1 --oneline" >&2
  sr_log "next: SR_PROFILE=$SR_PROFILE bash $0 verify"
}

# ---- verify (build changed FE/BE on the branch image + related UTs) -------------

cmd_verify() {
  load_bp
  local force_fe=0 force_be=0 fe_test="" be_test="" do_build=1 do_test=1 have_force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fe) force_fe=1; have_force=1; shift ;;
      --be) force_be=1; have_force=1; shift ;;
      --fe-test) fe_test="$2"; shift 2 ;;
      --be-test) be_test="$2"; shift 2 ;;
      --no-build) do_build=0; shift ;;
      --no-test)  do_test=0; shift ;;
      *) sr_die "verify: unknown option '$1'" ;;
    esac
  done

  # Detect touched components + changed test files from the backport commit.
  local files; files=$(rsrc "git show --name-only --format= HEAD 2>/dev/null" | sed '/^$/d')
  local fe=0 be=0 fe_classes="" be_tests="" f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
      fe/*|java-extensions/*|fe-core/*) fe=1 ;;
      be/*|gensrc/*)                    be=1 ;;
    esac
    case "$f" in
      *Test.java) fe_classes+="${fe_classes:+,}$(basename "$f" .java)" ;;
      *_test.cpp) be_tests+="${be_tests:+ }$f" ;;
    esac
  done <<< "$files"
  [[ "$have_force" == 1 ]] && { fe="$force_fe"; be="$force_be"; }
  sr_log "verify: FE=$fe BE=$be image=$BP_IMAGE profile=$SR_PROFILE"

  local rc=0
  if [[ "$do_build" == 1 ]]; then
    if [[ "$fe" == 0 && "$be" == 0 ]]; then
      sr_log "no FE/BE source changed — skipping build (docs/other only)."
    fi
    if [[ "$be" == 1 ]]; then
      sr_log "building BE on $BP_IMAGE ..."
      bash "$BUILD_SH" --be || { sr_log "✗ BE build FAILED"; rc=1; }
    fi
    if [[ "$fe" == 1 ]]; then
      sr_log "building FE on $BP_IMAGE ..."
      bash "$BUILD_SH" --fe || { sr_log "✗ FE build FAILED"; rc=1; }
    fi
    [[ "$rc" -ne 0 ]] && sr_die "build failed — fix before testing (see output above)."
    sr_log "✓ build OK"
  fi

  if [[ "$do_test" == 1 ]]; then
    if [[ "$fe" == 1 ]]; then
      if [[ -n "$fe_test" ]]; then
        sr_log "FE UT: $fe_test"
        bash "$TEST_SH" fe $fe_test || { sr_log "✗ FE UT FAILED"; rc=1; }
      elif [[ -n "$fe_classes" ]]; then
        sr_log "FE UT (changed test classes): $fe_classes"
        bash "$TEST_SH" fe "-Dtest=$fe_classes" "-DfailIfNoTests=false" || { sr_log "✗ FE UT FAILED"; rc=1; }
      else
        sr_log "no FE test classes changed; pass --fe-test '-Dtest=SomeClass' to run a specific FE suite."
      fi
    fi
    if [[ "$be" == 1 ]]; then
      if [[ -n "$be_test" ]]; then
        sr_log "BE UT filter: $be_test"
        bash "$TEST_SH" be "--gtest_filter=$be_test" || { sr_log "✗ BE UT FAILED"; rc=1; }
      elif [[ -n "$be_tests" ]]; then
        sr_log "changed BE test files: $be_tests"
        sr_log "pass --be-test '<gtest_filter>' to run them (e.g. --be-test 'SomeSuite.*')."
      else
        sr_log "no BE test files changed; pass --be-test '<gtest_filter>' to run a specific BE suite."
      fi
    fi
  fi

  [[ "$rc" -eq 0 ]] && sr_log "✓ verify passed — review: SR_PROFILE=$SR_PROFILE bash $0 diff" \
                     || sr_die "verify FAILED (exit $rc) — read the output above."
}

# ---- diff / status / push / cleanup / list -------------------------------------

cmd_diff() {
  load_bp
  rsrc "git --no-pager show --stat HEAD; echo; git --no-pager show HEAD"
}

cmd_status() {
  load_bp
  sr_log "profile=$SR_PROFILE  PR #$BP_PR -> $BP_TARGET  image=$BP_IMAGE"
  sr_log "local branch: $BP_LOCAL_BRANCH   upstream commit: ${BP_OID:0:12}"
  if rsrc "test -f \"\$(git rev-parse --git-path CHERRY_PICK_HEAD)\""; then
    sr_log "cherry-pick IN PROGRESS — unmerged files:"
    rsrc "git --no-pager diff --name-only --diff-filter=U" | sed 's/^/    /' >&2
  else
    sr_log "cherry-pick committed. HEAD:"
    rsrc "git --no-pager log -1 --oneline" | sed 's/^/    /' >&2
  fi
}

cmd_push() {
  load_bp
  local remote="origin" branch="$BP_LOCAL_BRANCH" yes="${SR_RO_YES:-0}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote) remote="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --yes)    yes=1; shift ;;
      *) sr_die "push: unknown option '$1'" ;;
    esac
  done
  if rsrc "test -f \"\$(git rev-parse --git-path CHERRY_PICK_HEAD)\""; then
    sr_die "cherry-pick still in progress — finish with 'continue' (and verify) before pushing."
  fi
  sr_log "about to push HEAD -> $remote/$branch on the dev host:"
  rsrc "git --no-pager log -1 --oneline" >&2
  if [[ "$yes" != 1 ]]; then
    sr_die "this PUSHES to GitHub. Re-run with --yes once you've reviewed 'diff' and 'verify'."
  fi
  rsrc "git push '$remote' 'HEAD:refs/heads/$branch'" \
    || sr_die "git push failed (auth on the dev host? branch protection?)."
  sr_log "✓ pushed $branch to $remote. Open a backport PR targeting $BP_TARGET on GitHub."
}

cmd_cleanup() {
  load_bp
  local keep_src=""
  [[ "${1:-}" == "--keep-src" ]] && keep_src="--keep-src"
  local p="$SR_PROFILE"
  sr_log "removing backport profile '$p' (worktree + container)..."
  SR_PROFILE= bash "$WORKSPACE_SH" rm "$p" $keep_src
}

cmd_list() {
  local d name f
  echo "── backport profiles ──"
  local any=0
  for d in "$SR_CFG_BASE"/profiles/*/; do
    [[ -f "$d/backport.env" ]] || continue
    name=$(basename "$d"); any=1
    # shellcheck source=/dev/null
    ( source "$d/backport.env"; printf '  %-22s PR#%s -> %-12s image=%s\n' "$name" "$BP_PR" "$BP_TARGET" "$BP_IMAGE" )
  done
  [[ "$any" == 1 ]] || echo "  (none — create one with: backport.sh prepare --pr <url> --branch <b>)"
}

# ---- dispatch ------------------------------------------------------------------

cmd="${1:-}"; shift || true
case "$cmd" in
  prepare)   cmd_prepare "$@" ;;
  __pick)    cmd_pick "$@" ;;
  pull)      cmd_pull "$@" ;;
  resolve)   cmd_resolve "$@" ;;
  continue)  cmd_continue "$@" ;;
  verify)    cmd_verify "$@" ;;
  diff)      cmd_diff "$@" ;;
  status)    cmd_status "$@" ;;
  push)      cmd_push "$@" ;;
  cleanup)   cmd_cleanup "$@" ;;
  list)      cmd_list "$@" ;;
  -h|--help|help|"") cat >&2 <<'EOF'
usage: backport.sh <command>
  prepare --pr <url|#> --branch <target> [--repo o/r] [--oid <sha>] [--image <img>] [--profile <name>]
                                  resolve the PR's merge commit, create a worktree profile pinned to the
                                  branch-matching dev-env image, and cherry-pick onto <target>.
  (the rest take SR_PROFILE=<the profile prepare printed>)
  pull [<dir>]                    copy conflicted files locally for Claude to resolve
  resolve [<dir>]                 push resolved files back + git add; reject leftover markers
  continue                        finish the cherry-pick
  verify [--fe|--be] [--fe-test '<mvn>'] [--be-test '<filter>'] [--no-build] [--no-test]
                                  build changed FE/BE on the branch image + run related UTs
  diff | status                   review the backport commit / cherry-pick state
  push [--remote o] [--branch b] [--yes]   push the local branch to GitHub (gated)
  cleanup [--keep-src]            remove the worktree profile + container
  list                            list active backport profiles
EOF
    ;;
  *) sr_die "unknown command '$cmd' (run 'backport.sh help')." ;;
esac
