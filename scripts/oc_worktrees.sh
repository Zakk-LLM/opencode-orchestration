#!/usr/bin/env bash
# List or clean up the git worktrees a run created.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: oc_worktrees.sh <run-dir> --list
       oc_worktrees.sh <run-dir> --diff [BASE]         (default BASE: main)
       oc_worktrees.sh <run-dir> --drift [BASE]
       oc_worktrees.sh <run-dir> --rebase [BASE]
       oc_worktrees.sh <run-dir> --remove-merged BASE
       oc_worktrees.sh <run-dir> --remove-all

--drift reports how far each branch has fallen behind BASE and whether its agent is still
running. --rebase moves the finished ones onto BASE, committing their pending work first, and
never touches a worktree whose agent is live.

--remove-merged deletes only worktrees whose branch is already contained in BASE, so
unmerged work is never thrown away. --remove-all refuses while a worktree has uncommitted
changes; commit or discard them first.
EOF
}

case "${1:-}" in -h|--help|"") usage; exit 0 ;; esac
RUN=$1; ACTION=${2:-}; ARG=${3:-}
[ -n "$ACTION" ] || { usage >&2; exit 2; }
[ -d "$RUN/worktrees" ] || { echo "no worktrees under $RUN"; exit 0; }

# Every agent records the repository it came from; take the first one that used a worktree.
REPO=$(python3 - "$RUN" <<'PY'
import json, pathlib, sys
run = pathlib.Path(sys.argv[1])
for meta in sorted((run / "agents").glob("*/meta.json")):
    m = json.loads(meta.read_text())
    if m.get("worktree_branch"):
        print(m["cwd"]); break
PY
)
[ -n "$REPO" ] || { echo "no agent in this run recorded a worktree" >&2; exit 1; }
# meta.cwd is the worktree itself; its common dir points back at the origin repository.
REPO=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')

case "$ACTION" in
  --list)
    git -C "$REPO" worktree list | grep -F "$RUN/worktrees" || echo "(none registered)"
    ;;
  --diff)
    BASE=${ARG:-main}
    for wt in "$RUN"/worktrees/*/; do
      [ -d "$wt" ] || continue
      name=$(basename "$wt")
      printf '\n=== opencode/%s vs %s ===\n' "$name" "$BASE"
      git -C "$REPO" diff --stat "$BASE...opencode/$name" 2>/dev/null || echo "(branch missing)"
      # Agents are forbidden from committing, so their work is usually still uncommitted.
      git -C "$wt" diff --stat HEAD | sed 's/^/  uncommitted: /'
      git -C "$wt" status --porcelain --untracked-files=all | grep '^??' | sed 's/^??/  untracked:/'
    done
    ;;
  --drift|--rebase)
    BASE=${ARG:-main}
    git -C "$REPO" rev-parse --verify "$BASE" >/dev/null 2>&1 || {
      echo "unknown base: $BASE" >&2; exit 2; }
    for wt in "$RUN"/worktrees/*/; do
      [ -d "$wt" ] || continue
      name=$(basename "$wt")
      behind=$(git -C "$REPO" rev-list --count "opencode/$name..$BASE" 2>/dev/null || echo 0)
      # Rebasing a worktree while its agent is writing in it would corrupt work in flight,
      # so liveness comes from the registry, with a cmdline scan for hand-started agents.
      live=$(WT_PATH="$(cd "$wt" && pwd)" python3 - <<'LIVE'
import json, os, pathlib
wt = os.environ["WT_PATH"]
reg = pathlib.Path(os.environ.get("OPENCODE_REGISTRY_DIR",
      os.environ.get("XDG_RUNTIME_DIR", "/tmp") + "/opencode-agents"))

def alive(pid, ticks):
    try:
        stat = open(f"/proc/{pid}/stat").read()
        fields = stat[stat.rindex(") ") + 2:].split()
        return fields[19] == str(ticks) and fields[0] != "Z"
    except (OSError, ValueError, IndexError):
        return False

for f in reg.glob("*.json"):
    try:
        d = json.loads(f.read_text())
    except (json.JSONDecodeError, OSError):
        continue
    if d.get("cwd") == wt and alive(d.get("pid", 0), d.get("start_ticks")):
        print("yes"); raise SystemExit

for entry in pathlib.Path("/proc").iterdir():
    if not entry.name.isdigit():
        continue
    try:
        argv = entry.joinpath("cmdline").read_bytes().decode(errors="replace")
    except OSError:
        continue
    if "opencode" in argv and wt in argv:
        print("yes"); raise SystemExit
print("no")
LIVE
)
      if [ "${behind:-0}" = 0 ]; then
        printf '%-28s up to date with %s\n' "opencode/$name" "$BASE"
        continue
      fi
      if [ "$ACTION" = --drift ]; then
        printf '%-28s %s commit(s) behind %s  agent-running=%s\n' "opencode/$name" "$behind" "$BASE" "$live"
        continue
      fi
      if [ "$live" = yes ]; then
        printf '%-28s SKIPPED: agent still running; tell it through NOTES.md and rebase after it exits\n' "opencode/$name"
        continue
      fi
      if [ -n "$(git -C "$wt" status --porcelain)" ]; then
        git -C "$wt" add -A && git -C "$wt" commit -q -m "$name: agent work before rebase onto $BASE" || {
          printf '%-28s FAILED to commit pending work\n' "opencode/$name"; continue; }
      fi
      if git -C "$wt" rebase "$BASE" >/dev/null 2>&1; then
        printf '%-28s rebased onto %s — re-run its acceptance checks\n' "opencode/$name" "$BASE"
      else
        git -C "$wt" rebase --abort 2>/dev/null
        printf '%-28s CONFLICT rebasing onto %s; resolve by hand\n' "opencode/$name" "$BASE"
      fi
    done
    ;;
  --remove-merged)
    [ -n "$ARG" ] || { echo "--remove-merged needs a base branch" >&2; exit 2; }
    for wt in "$RUN"/worktrees/*/; do
      [ -d "$wt" ] || continue
      name=$(basename "$wt")
      if [ -n "$(git -C "$wt" status --porcelain)" ]; then
        echo "keep opencode/$name: uncommitted changes"; continue
      fi
      if git -C "$REPO" merge-base --is-ancestor "opencode/$name" "$ARG" 2>/dev/null; then
        git -C "$REPO" worktree remove "$wt" && git -C "$REPO" branch -d "opencode/$name" \
          && echo "removed opencode/$name"
      else
        echo "keep opencode/$name: not merged into $ARG"
      fi
    done
    ;;
  --remove-all)
    for wt in "$RUN"/worktrees/*/; do
      [ -d "$wt" ] || continue
      name=$(basename "$wt")
      if [ -n "$(git -C "$wt" status --porcelain)" ]; then
        echo "refusing opencode/$name: uncommitted changes" >&2; continue
      fi
      git -C "$REPO" worktree remove "$wt" && echo "removed worktree opencode/$name"
    done
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
