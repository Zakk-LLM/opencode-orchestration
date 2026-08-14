#!/usr/bin/env bash
# Integrate agent branches one at a time, atomically. Every merge is verified before it is
# kept, and any failure returns the target branch to the exact commit it started from, so a
# half-integrated tree is never left behind.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: oc_merge.sh --run-dir DIR --repo DIR --into BRANCH [options] [label ...]

  --run-dir DIR   run whose agents are being integrated
  --repo DIR      the integration repository (not a worktree)
  --into BRANCH   target branch; must be checked out and clean
  --check CMD     command that must pass after each merge, repeatable
  --rebase        rebase a branch whose base is no longer an ancestor of the target
  --dry-run       report what would happen, change nothing

With no labels, every agent in the run that has a worktree branch is integrated, in the order
they finished. Pass labels explicitly when dependencies require a different order. Agent work is committed in its worktree first, because agents are
forbidden from committing.

Refuses to start when the target is dirty, and stops at the first failure with the repository
reset to its starting commit.
EOF
}

RUN=; REPO=; INTO=; REBASE=0; DRY=0; CHECKS=(); LABELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) RUN=$2; shift 2 ;;
    --repo) REPO=$2; shift 2 ;;
    --into) INTO=$2; shift 2 ;;
    --check) CHECKS+=("$2"); shift 2 ;;
    --rebase) REBASE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) LABELS+=("$1"); shift ;;
  esac
done
[ -n "$RUN" ] && [ -n "$REPO" ] && [ -n "$INTO" ] || { usage >&2; exit 2; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "$REPO is not a git repository" >&2; exit 2; }

CURRENT=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
[ "$CURRENT" = "$INTO" ] || { echo "checkout $INTO first (currently on $CURRENT)" >&2; exit 2; }
# Tracked modifications block integration because a merge would mix them in. Pre-existing
# untracked files do not: they are recorded and left exactly as they are.
if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
  echo "the integration tree has uncommitted tracked changes; commit or stash before merging" >&2
  git -C "$REPO" status --short --untracked-files=no >&2
  exit 2
fi

# Collect candidates in creation order, with the base each agent actually built on.
WANTED_JSON=$(python3 -c 'import json,sys; json.dump(sys.argv[1:], sys.stdout)' ${LABELS+"${LABELS[@]}"})
mapfile -t JOBS < <(RUN_DIR="$RUN" WANTED="$WANTED_JSON" python3 <<'PY'
import json, os, pathlib
run = pathlib.Path(os.environ["RUN_DIR"])
wanted = json.loads(os.environ.get("WANTED") or "[]")
rows = []
for meta in (run / "agents").glob("*/meta.json"):
    try:
        m = json.loads(meta.read_text())
    except (json.JSONDecodeError, OSError):
        continue
    if not m.get("worktree_branch"):
        continue
    if wanted and m["label"] not in wanted:
        continue
    rows.append((meta.stat().st_mtime, m["label"], m["worktree_branch"],
                 m.get("base_sha") or "", m.get("cwd") or ""))
for _, label, branch, base, cwd in sorted(rows):
    print(f"{label}\t{branch}\t{base}\t{cwd}")
PY
)
[ "${#JOBS[@]}" -gt 0 ] || { echo "no agent branches to integrate in $RUN" >&2; exit 2; }

START_SHA=$(git -C "$REPO" rev-parse HEAD)
# `git reset --hard` restores tracked content only, so the untracked set is captured too:
# a failed check that generated files would otherwise leave them behind.
UNTRACKED_BEFORE=$(git -C "$REPO" ls-files --others --exclude-standard | sort)
DONE=0
echo "integrating ${#JOBS[@]} branch(es) into $INTO at $START_SHA" >&2

rollback() {
  echo "rolling back $INTO to $START_SHA" >&2
  git -C "$REPO" merge --abort 2>/dev/null
  git -C "$REPO" rebase --abort 2>/dev/null
  git -C "$REPO" reset --hard "$START_SHA" >/dev/null
  # Remove only what appeared during this run; anything that was already untracked stays.
  comm -13 <(printf '%s\n' "$UNTRACKED_BEFORE") \
           <(git -C "$REPO" ls-files --others --exclude-standard | sort) |
  while IFS= read -r f; do [ -n "$f" ] && rm -f "$REPO/$f"; done
}

# An interrupt during a check would otherwise leave the target half-integrated.
trap '[ "$DONE" = 1 ] || { echo "interrupted" >&2; rollback; }; exit 130' INT
trap '[ "$DONE" = 1 ] || { echo "terminated" >&2; rollback; }; exit 143' TERM HUP

for job in "${JOBS[@]}"; do
  IFS=$'\t' read -r LABEL BRANCH BASE WT <<< "$job"
  echo "== $LABEL ($BRANCH)" >&2

  # Agents never commit, so their work is still uncommitted in the worktree.
  if [ -d "$WT" ] && [ -n "$(git -C "$WT" status --porcelain)" ]; then
    if [ "$DRY" = 1 ]; then
      echo "   would commit uncommitted work in $WT" >&2
    else
      git -C "$WT" add -A || { rollback; exit 1; }
      git -C "$WT" commit -q -m "$LABEL: agent work from run $(basename "$RUN")" || { rollback; exit 1; }
    fi
  fi

  # A base that is no longer an ancestor of the target means the branch was written against a
  # tree that has since moved: merging it silently would resurrect the old state.
  if [ -n "$BASE" ] && ! git -C "$REPO" merge-base --is-ancestor "$BASE" HEAD 2>/dev/null; then
    if [ "$REBASE" = 1 ] && [ "$DRY" = 0 ]; then
      echo "   base moved; rebasing $BRANCH onto $INTO" >&2
      git -C "$REPO" rebase --onto "$INTO" "$BASE" "$BRANCH" >/dev/null 2>&1 || {
        echo "   rebase conflicted; resolve $BRANCH by hand" >&2; rollback; exit 1; }
      git -C "$REPO" checkout -q "$INTO"
    else
      echo "   base $BASE is not an ancestor of $INTO; rerun with --rebase or update the branch" >&2
      [ "$DRY" = 0 ] && { rollback; exit 1; }
    fi
  fi

  if [ "$DRY" = 1 ]; then
    git -C "$REPO" diff --stat "$INTO...$BRANCH" 2>/dev/null | tail -3 >&2
    continue
  fi

  BEFORE=$(git -C "$REPO" rev-parse HEAD)
  if ! git -C "$REPO" merge --no-ff --no-edit "$BRANCH" >/dev/null 2>&1; then
    echo "   merge conflicted" >&2
    git -C "$REPO" merge --abort 2>/dev/null
    rollback; exit 1
  fi

  # Verify after every merge, not once at the end: two branches that each pass alone can fail
  # together, and finding that at the end tells you nothing about which one caused it.
  for cmd in ${CHECKS+"${CHECKS[@]}"}; do
    echo "   check: $cmd" >&2
    if ! ( cd "$REPO" && eval "$cmd" >/dev/null 2>&1 ); then
      echo "   check failed after merging $BRANCH" >&2
      git -C "$REPO" reset --hard "$BEFORE" >/dev/null
      rollback; exit 1
    fi
  done
  if [ "${#CHECKS[@]}" -eq 0 ]; then
    echo "   merged; NOT verified — no --check was given" >&2
  else
    echo "   merged and verified" >&2
  fi
done
DONE=1

if [ "$DRY" = 1 ]; then
  echo "dry run: nothing changed" >&2
  exit 0
fi
echo "integrated ${#JOBS[@]} branch(es): $START_SHA -> $(git -C "$REPO" rev-parse HEAD)" >&2
