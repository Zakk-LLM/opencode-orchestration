#!/usr/bin/env bash
# Summarize every agent in a run directory: state, cost, thread id, result head.
set -uo pipefail

case "${1:-}" in
  -h|--help|"")
    cat <<'EOF'
Usage: oc_status.sh <run-dir> [--full|--brief]

Prints one row per agent (state, duration, output tokens), the run's token totals, and each
agent's thread id with a truncated head of its result. --full prints results untruncated;
--brief prints the table and thread ids only, which is what a supervision check needs.
EOF
    exit 0 ;;
esac
RUN_DIR=$1
FULL=${2:-}

python3 - "$RUN_DIR" "$FULL" <<'PY'
import json, pathlib, sys, time
run = pathlib.Path(sys.argv[1])
full = sys.argv[2] == "--full"
brief = sys.argv[2] == "--brief"
agents = sorted(a for a in (run / "agents").glob("*") if a.is_dir()) \
    if (run / "agents").is_dir() else []
if not agents:
    print(f"no agents under {run}")
    raise SystemExit(1)

rows, tin, tout = [], 0, 0
for a in agents:
    meta_file = a / "meta.json"
    if not meta_file.exists():
        # An agent directory with no event log was never dispatched: a prepared spec, or a job
        # the scheduler skipped because a dependency failed. That is not the same as running.
        if not (a / "events.jsonl").exists():
            rows.append((a.name, "PENDING", "-", "-", "-", ""))
            continue
        # While an agent runs, the useful number is how long it has before the guard kills it.
        left = "-"
        try:
            s = json.loads((a / "started.json").read_text())
            remaining = int(s["deadline"] - time.time())
            left = f"{remaining}s" if remaining > 0 else "over"
        except (OSError, KeyError, json.JSONDecodeError):
            pass
        rows.append((a.name, "RUNNING", left, "-", "-", ""))
        continue
    m = json.loads(meta_file.read_text())
    u = m.get("usage") or {}
    tin += u.get("input_tokens", 0)
    tout += u.get("output_tokens", 0)
    if m["exit_code"] == 0:
        state = "OK"
    elif m.get("transient_failure"):
        state = "TRANSIENT"      # upstream/transport, not the task: ask before re-dispatching
    elif m.get("stalled"):
        state = "STALLED"
    elif m.get("timed_out"):
        state = "TIMEOUT"
    else:
        state = f"FAIL({m['exit_code']})"
    if m["exit_code"] == 0 and not m.get("result_file"):
        state = "NO-RESULT"
    rows.append((a.name, state, f"{m['duration_s']}s",
                 f"{u.get('output_tokens', 0)}", m.get("thread_id") or "-",
                 m.get("result_file") or ""))

w = max(len(r[0]) for r in rows)
print(f"{'AGENT'.ljust(w)}  STATE      TIME    OUT-TOK   (TIME = elapsed, or left before the guard)")
for name, state, dur, out, _, _ in rows:
    print(f"{name.ljust(w)}  {state:<9}  {dur:>5}  {out:>7}")
print(f"\ntotal input {tin} / output {tout} tokens across {len(rows)} agents")

for name, state, _, _, thread, path in rows:
    # Thread ids share a timestamp prefix, so print them in full for --resume.
    print(f"\n--- {name} [{state}] thread {thread}")
    if not path or brief:
        continue
    text = pathlib.Path(path).read_text(errors="replace").strip()
    body = text if full else text[:700] + ("\n… (truncated, read the file)" if len(text) > 700 else "")
    print(f"{path}\n{body}")
PY
