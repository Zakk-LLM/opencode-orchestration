#!/usr/bin/env bash
# Dispatch a whole fan-out from a job list: hardest first, concurrency derived from the
# machine, everything else delegated to oc_agent.sh. One command instead of N background
# invocations the orchestrator has to track by hand.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

usage() {
  cat <<'EOF'
Usage: oc_dispatch.sh --run-dir DIR --jobs FILE [--weight light|medium|heavy] [--max N]
                         [--common "ARGS"] [--dry-run]

FILE is JSONL, one job per line. Recognized keys, all optional except label:

  {"label":"cache", "tier":"deep", "cwd":"/repo", "permission":"workspace-write",
   "worktree":true, "worktree_base":"main", "timeout":3600, "stall":300,
   "schema":"/path/schema.json", "network":false, "allow_git":false,
   "prompt_file":"/path/prompt.md", "variant":"high", "model":"provider/model",
   "agent":"build", "fork":false, "depends_on":["schema-design"]}

prompt_file defaults to <run-dir>/agents/<label>/prompt.md. Independent jobs run
hardest-tier-first so the long ones start while there is still capacity; concurrency is
min(--max, oc_capacity.sh --weight).

depends_on holds labels that must finish successfully first. A dependent job is not dispatched
until they do, and is skipped outright if any of them fails — running it against a missing or
broken result only produces work that has to be thrown away. Unknown labels and dependency
cycles are rejected before anything is dispatched.
EOF
}

RUN=; JOBS=; WEIGHT=medium; MAX=0; COMMON=; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) RUN=$2; shift 2 ;;
    --jobs) JOBS=$2; shift 2 ;;
    --weight) WEIGHT=$2; shift 2 ;;
    --max) MAX=$2; shift 2 ;;
    --common) COMMON=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$RUN" ] && [ -n "$JOBS" ] || { usage >&2; exit 2; }
[ -f "$JOBS" ] || { echo "no such job file: $JOBS" >&2; exit 2; }

CAP=$("$HERE/oc_capacity.sh" "$WEIGHT" 2>/dev/null) || CAP=3
[ "$MAX" -gt 0 ] 2>/dev/null && [ "$MAX" -lt "$CAP" ] && CAP=$MAX
# Capacity reaches zero when the machine-wide cap is already taken. Launching one job anyway
# is correct: oc_agent.sh queues on the slot lock. A zero here would spin forever instead.
if [ "${CAP:-0}" -lt 1 ]; then
  CAP=1
  echo "machine is at the global cap; jobs will queue on the slot lock one at a time" >&2
fi
echo "dispatching with concurrency $CAP (weight $WEIGHT)" >&2

# Expand each job into a complete oc_agent.sh argument line, hardest tier first, with its
# dependencies attached so the scheduler below can hold it back.
CMDS=$(RUN_DIR="$RUN" python3 - "$JOBS" <<'PY'
import json, os, shlex, sys
order = {"frontier": 0, "deep": 1, "standard": 2, "cheap": 3}
run = os.environ["RUN_DIR"]
jobs = []
for n, line in enumerate(open(sys.argv[1]), 1):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    try:
        j = json.loads(line)
    except json.JSONDecodeError as e:
        sys.exit(f"job file line {n}: {e}")
    if "label" not in j:
        sys.exit(f"job file line {n}: missing label")
    jobs.append(j)

for j in sorted(jobs, key=lambda j: order.get(j.get("tier", "standard"), 2)):
    label = j["label"]
    a = ["--run-dir", run, "--label", label]
    a += ["--prompt-file", j.get("prompt_file", f"{run}/agents/{label}/prompt.md")]
    for key, flag in (("tier", "--tier"), ("variant", "--variant"), ("model", "--model"),
                      ("agent", "--agent"), ("cwd", "--cwd"), ("permission", "--permission"),
                      ("schema", "--schema"), ("timeout", "--timeout"), ("stall", "--stall"),
                      ("worktree_base", "--worktree-base"), ("resume", "--resume")):
        if j.get(key) is not None:
            a += [flag, str(j[key])]
    if j.get("worktree"):
        a += ["--worktree"] if j["worktree"] is True else ["--worktree", str(j["worktree"])]
    if j.get("network"):
        a += ["--network"]
    if j.get("allow_git"):
        a += ["--allow-git"]
    if j.get("fork"):
        a += ["--fork"]
    deps = ",".join(j.get("depends_on") or []) or "-"
    print(label + "\t" + deps + "\t" + " ".join(shlex.quote(x) for x in a))

# A dependency that does not exist, or a cycle, would deadlock the scheduler or silently drop
# work. Both are decided here, before a single agent starts.
labels = {j["label"] for j in jobs}
for j in jobs:
    for d in j.get("depends_on") or []:
        if d not in labels:
            sys.exit(f"job {j['label']!r} depends on unknown label {d!r}")
graph = {j["label"]: list(j.get("depends_on") or []) for j in jobs}
state = {}
def visit(node, chain):
    if state.get(node) == "done":
        return
    if state.get(node) == "open":
        sys.exit("dependency cycle: " + " -> ".join(chain + [node]))
    state[node] = "open"
    for d in graph.get(node, []):
        visit(d, chain + [node])
    state[node] = "done"
for label in graph:
    visit(label, [])
PY
) || exit 2

[ -n "$CMDS" ] || { echo "no jobs found in $JOBS" >&2; exit 2; }

if [ "$DRY" = 1 ]; then
  printf '%s\n' "$CMDS" | while IFS=$'\t' read -r label deps args; do
    printf '%s%s: oc_agent.sh %s %s\n' "$label" \
      "$([ "$deps" != - ] && echo " (after $deps)")" "$args" "$COMMON"
  done
  exit 0
fi

declare -A DEPS ARGS RESULT PID_OF
ORDER=()
while IFS=$'\t' read -r label deps args; do
  [ "$deps" = - ] && deps=
  ORDER+=("$label"); DEPS[$label]=$deps; ARGS[$label]=$args
done <<< "$CMDS"

mkdir -p "$RUN/logs"
FAIL=0

launch() {
  local label=$1
  echo "start $label" >&2
  eval "\"$HERE/oc_agent.sh\" ${ARGS[$label]} $COMMON" > "$RUN/logs/$label.dispatch.log" 2>&1 &
  PID_OF[$label]=$!
}

# Ready when every dependency finished successfully; skipped when one of them failed. Holding a
# dependent back is the whole point: dispatching it early wastes the run and has to be redone.
deps_state() {
  local label=$1 dep
  local status=ready
  IFS=',' read -ra list <<< "${DEPS[$label]}"
  for dep in ${list+"${list[@]}"}; do
    [ -z "$dep" ] && continue
    case "${RESULT[$dep]:-pending}" in
      ok) ;;
      pending|running) status=waiting ;;
      *) echo "skip"; return ;;
    esac
  done
  echo "$status"
}

remaining=${#ORDER[@]}
while [ "$remaining" -gt 0 ]; do
  progressed=0
  for label in "${ORDER[@]}"; do
    [ -n "${RESULT[$label]:-}" ] && continue
    [ -n "${PID_OF[$label]:-}" ] && continue
    case "$(deps_state "$label")" in
      ready)
        [ "$(jobs -pr | wc -l)" -ge "$CAP" ] && continue
        launch "$label"; progressed=1 ;;
      skip)
        RESULT[$label]=skipped; FAIL=1; remaining=$((remaining - 1)); progressed=1
        echo "skip $label: a dependency failed" >&2 ;;
    esac
  done

  # Reap whatever finished, then loop: a completed dependency may unblock several jobs.
  for label in "${ORDER[@]}"; do
    pid=${PID_OF[$label]:-}
    [ -z "$pid" ] && continue
    [ -n "${RESULT[$label]:-}" ] && continue
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"; code=$?
      if [ "$code" = 0 ]; then RESULT[$label]=ok; else RESULT[$label]=failed; FAIL=1; fi
      remaining=$((remaining - 1)); progressed=1
      printf '%s exit=%s\n' "$label" "$code" >&2
    fi
  done

  [ "$remaining" -gt 0 ] && [ "$progressed" = 0 ] && sleep 2
done

for label in "${ORDER[@]}"; do
  [ "${RESULT[$label]:-}" = skipped ] && echo "$label: skipped, dependency failed" >&2
done
"$HERE/oc_status.sh" "$RUN" 2>/dev/null | head -n $(( ${#ORDER[@]} + 4 ))
exit $FAIL
