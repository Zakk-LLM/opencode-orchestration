#!/usr/bin/env bash
# A bounded wait that always returns something actionable. Blocks until an agent finishes,
# stalls, or dies, or until the deadline — then prints what changed since the last call. The
# point is that an orchestrator never sleeps for an unknown length of time and never polls
# blindly: it either gets work back, or gets told the window is free for other work.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: oc_watch.sh <run-dir> [--timeout SEC] [--interval SEC] [--state FILE]

  --timeout SEC   maximum block, default 300. Pick it as the time until your next useful
                  action, not as how long the agents might take.
  --interval SEC  poll interval, default 10
  --state FILE    where the seen-set lives, default <run-dir>/.watch-state
  --warn PCT      warn when a running agent has used this share of its wall-clock limit,
                  default 80. Reported once per agent as "<label> EXPIRING <seconds> left".
  --peek          for each running agent, also print its last event, read from the tail of
                  events.jsonl. Liveness never costs more than a few kilobytes.

Exit codes:
  0  something changed — labels and states are printed, act on them now
  1  nothing changed before the deadline — spend the window on work that needs no agent
  2  every agent in the run has finished
  3  the run has no agents yet
EOF
}

RUN=${1:-}; shift 2>/dev/null
[ -n "$RUN" ] || { usage >&2; exit 3; }
case "$RUN" in -h|--help) usage; exit 0 ;; esac

TIMEOUT=300; INTERVAL=10; STATE=; WARN=80; PEEK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT=$2; shift 2 ;;
    --interval) INTERVAL=$2; shift 2 ;;
    --state) STATE=$2; shift 2 ;;
    --warn) WARN=$2; shift 2 ;;
    --peek) PEEK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done
[ -n "$STATE" ] || STATE="$RUN/.watch-state"
[ -d "$RUN/agents" ] || { echo "no agents under $RUN" >&2; exit 3; }

WAITED=0
while :; do
  # Two orchestrators watching one run must not both claim the same completion, so the
  # read-modify-write of the seen-set happens under a lock.
  OUT=$(flock "$STATE.lock" env RUN_DIR="$RUN" STATE_FILE="$STATE" WARN_PCT="$WARN" \
        PEEK="$PEEK" python3 <<'PY'
import json, os, pathlib, sys, time

run = pathlib.Path(os.environ["RUN_DIR"])
state_file = pathlib.Path(os.environ["STATE_FILE"])
try:
    seen = json.loads(state_file.read_text())
except (OSError, json.JSONDecodeError):
    seen = {}

def repeated_failure(path, window=40, threshold=8):
    """A worker can emit events forever while getting nowhere: the same tool failing on the
    same input is progress to the stall guard and waste to everyone else. Reads the tail only."""
    try:
        size = path.stat().st_size
        with path.open("rb") as fh:
            fh.seek(max(0, size - 262144))
            lines = fh.read().decode(errors="replace").splitlines()
    except OSError:
        return None
    fails = []
    for line in lines:
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        item = ev.get("item") or ev.get("part") or {}
        state = item.get("state") or {}
        status = state.get("status")
        exit_code = item.get("exit_code")
        failed = status == "error" or (exit_code not in (0, None))
        if item.get("type") in ("tool", "command_execution", "tool_use") or status:
            key = f"{item.get('tool') or item.get('type')}"
            fails.append(key if failed else None)
    recent = [f for f in fails[-window:] if f]
    if not recent:
        return None
    top = max(set(recent), key=recent.count)
    n = recent.count(top)
    return (top, n) if n >= threshold else None

agents = [a for a in sorted((run / "agents").glob("*")) if a.is_dir()]
# A directory holding only a prepared spec has not been dispatched: events.jsonl appears when
# the worker actually starts. Counting it as running would hide "nothing was dispatched".
dispatched = [a for a in agents if (a / "events.jsonl").exists() or (a / "meta.json").exists()]
if not dispatched:
    sys.exit(3)

now = time.time()
warn_pct = int(os.environ.get("WARN_PCT", "80"))
changed, running, done = [], 0, 0
for a in dispatched:
    meta = a / "meta.json"
    if not meta.exists():
        running += 1
        # A guard kill destroys the turn's work, so the warning has to arrive before it, not
        # after: an expiring agent can still be told to stop and report what it has.
        try:
            s = json.loads((a / "started.json").read_text())
        except (OSError, json.JSONDecodeError):
            continue
        left = int(s.get("deadline", 0) - now)
        limit = int(s.get("timeout_s") or 0)
        if limit and left <= limit * (100 - warn_pct) / 100:
            key = f"{a.name}#expiring"
            if key not in seen:
                seen[key] = "EXPIRING"
                changed.append((a.name, f"EXPIRING {max(left, 0)}s left of {limit}s", "", ""))
        # Burning wall-clock without progress: the same tool failing over and over.
        looping = repeated_failure(a / "events.jsonl")
        if looping:
            key = f"{a.name}#loop"
            if seen.get(key) != looping[0]:
                seen[key] = looping[0]
                changed.append((a.name,
                                f"LOOPING {looping[0]} failed {looping[1]} times in the last 40 "
                                f"tool calls — interrupt it, the spec cannot fix itself", "", ""))

        stall = int(s.get("stall_s") or 0)
        events = a / "events.jsonl"
        if stall and events.exists():
            quiet = int(now - events.stat().st_mtime)
            if quiet >= stall * warn_pct / 100:
                key = f"{a.name}#quiet"
                if key not in seen:
                    seen[key] = "QUIET"
                    changed.append((a.name, f"QUIET {quiet}s without an event, stall kill at {stall}s",
                                    "", ""))
        continue
    try:
        m = json.loads(meta.read_text())
    except (json.JSONDecodeError, OSError):
        # A meta file being written right now is not a finished agent.
        running += 1
        continue
    done += 1
    if m.get("exit_code") == 0:
        state = "OK"
    elif m.get("transient_failure"):
        state = "TRANSIENT"
    elif m.get("stalled"):
        state = "STALLED"
    elif m.get("timed_out"):
        state = "TIMEOUT"
    else:
        state = f"FAIL({m.get('exit_code')})"
    if seen.get(a.name) != state:
        changed.append((a.name, state, m.get("result_file") or "",
                        m.get("thread_id") or ""))
        seen[a.name] = state

# Liveness is the mtime plus the last event, never the whole log: an event file grows to
# megabytes, and reading it to answer "is it alive" is the most expensive way to ask.
def last_event(path):
    try:
        size = path.stat().st_size
        with path.open("rb") as fh:
            fh.seek(max(0, size - 4096))
            lines = [l for l in fh.read().decode(errors="replace").splitlines() if l.startswith("{")]
    except OSError:
        return None
    for line in reversed(lines):
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        item = ev.get("item") or {}
        kind = item.get("type") or ev.get("type")
        detail = (item.get("command") or item.get("query") or item.get("text") or "")[:60]
        return f"{kind} {detail}".strip()
    return None

peeked = False
if os.environ.get("PEEK") == "1":
    for a in dispatched:
        if (a / "meta.json").exists():
            continue
        ev = a / "events.jsonl"
        if not ev.exists():
            continue
        line = last_event(ev) or "(no event yet)"
        # Repeating an unchanged line every poll is the noise this whole design avoids.
        if seen.get(f"{a.name}#peek") == line:
            continue
        seen[f"{a.name}#peek"] = line
        peeked = True
        print(f"~ {a.name}\talive {int(now - ev.stat().st_mtime)}s ago\t{line}", file=sys.stderr)

if changed or peeked:
    state_file.write_text(json.dumps(seen))

# A peek line is progress information, not a state change: it must not claim exit 0, which
# means "an agent needs handling now".
if changed:
    for name, state, result, thread in changed:
        print(f"{name}\t{state}\t{result}\t{thread}")
    print(f"# {running} still running, {done} finished", file=sys.stderr)
    sys.exit(0)

# Nothing new. Distinguish "all finished and already handled" from "still working".
sys.exit(2 if running == 0 else 1)
PY
)
  CODE=$?
  case "$CODE" in
    0) printf '%s\n' "$OUT"; exit 0 ;;
    2) echo "all agents finished and already reported" >&2; exit 2 ;;
    3) exit 3 ;;
  esac
  [ "$WAITED" -ge "$TIMEOUT" ] && {
    echo "nothing changed in ${TIMEOUT}s — use the window for work that needs no agent" >&2
    exit 1
  }
  sleep "$INTERVAL"
  WAITED=$((WAITED + INTERVAL))
done
