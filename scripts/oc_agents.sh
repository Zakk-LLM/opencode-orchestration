#!/usr/bin/env bash
# Machine-wide view of the opencode agents this wrapper is running, so a second orchestrator window can
# see what a first one started. The registry is the source of truth; process scanning only
# reports strays, because an idle opencode TUI, a zombie, or an unrelated program named opencode must
# never be counted as a running agent.
set -uo pipefail

REG=${OPENCODE_REGISTRY_DIR:-${XDG_RUNTIME_DIR:-/tmp}/opencode-agents}

usage() {
  cat <<'EOF'
Usage: oc_agents.sh [--list | --count | --prune | --slots]

  --list    live agents: pid, label, tier, elapsed, workspace, run directory
  --count   number of live registered agents (for scripts)
  --prune   drop entries whose process is gone
  --slots   free slots against OPENCODE_MAX_AGENTS (default 5)

Internal, used by oc_agent.sh:
  --register PID FILE      register a running agent, metadata read from FILE (JSON)
  --unregister PID

Registry directory: $OPENCODE_REGISTRY_DIR, or $XDG_RUNTIME_DIR/opencode-agents.
EOF
}

mkdir -p "$REG" 2>/dev/null

case "${1:---list}" in
  --register)
    PID=${2:?pid}; META=${3:?metadata file}
    START=$(awk '{n=index($0,") "); print substr($0,n+2)}' "/proc/$PID/stat" 2>/dev/null | awk '{print $20}')
    python3 - "$REG/$PID.json" "$PID" "${START:-0}" "$META" <<'PY'
import json, sys, time
out, pid, start, meta = sys.argv[1:5]
d = json.load(open(meta))
# start_ticks pins the identity: a recycled pid gets a different value, so a stale entry from a
# crashed run can never be mistaken for a live agent.
d.update({"pid": int(pid), "start_ticks": int(start), "registered_at": int(time.time())})
json.dump(d, open(out, "w"))
PY
    ;;
  --unregister)
    rm -f "$REG/${2:?pid}.json" ;;
  --count|--list|--prune|--slots)
    ACTION=$1
    python3 - "$REG" "$ACTION" "${OPENCODE_MAX_AGENTS:-5}" <<'PY'
import json, os, pathlib, sys, time
reg, action, cap = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])

def start_ticks(pid):
    try:
        stat = open(f"/proc/{pid}/stat").read()
        return int(stat[stat.rindex(") ") + 2:].split()[19])
    except (OSError, ValueError, IndexError):
        return None

def field(pid, idx):
    try:
        stat = open(f"/proc/{pid}/stat").read()
        return stat[stat.rindex(") ") + 2:].split()[idx]
    except (OSError, ValueError, IndexError):
        return None

def state(pid):
    return field(pid, 0)

def descends_from(pid, known):
    """opencode run sits under a timeout wrapper, so the registered pid is an ancestor of the
    real opencode process. Without this walk every agent would be counted twice."""
    seen = 0
    while pid and pid != 1 and seen < 20:
        if pid in known:
            return True
        ppid = field(pid, 1)
        pid = int(ppid) if ppid and ppid.isdigit() else 0
        seen += 1
    return False

def scan_unregistered(known):
    """Agents started by hand still occupy a slot; an idle TUI or a zombie does not."""
    found = []
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit() or int(entry.name) in known:
            continue
        try:
            argv = [a for a in (entry / "cmdline").read_bytes().split(b"\0") if a]
        except OSError:
            continue
        argv = [a.decode(errors="replace") for a in argv]
        # Only a non-interactive `opencode run` counts; the TUI is a different process shape.
        sub = next((a for a in argv[1:] if not a.startswith("-")), None)
        if not argv or os.path.basename(argv[0]) != "opencode" or sub != "run":
            continue
        pid = int(entry.name)
        if state(pid) in (None, "Z") or descends_from(pid, known):
            continue
        found.append({"pid": pid, "label": "(unregistered)",
                      "tier": "?", "cwd": next((argv[i + 1] for i, a in enumerate(argv)
                                                if a == "-C" and i + 1 < len(argv)), "?"),
                      "run_dir": "(started outside this wrapper)", "registered_at": None})
    return found

live, stale = [], []
for f in sorted(reg.glob("*.json")):
    try:
        d = json.loads(f.read_text())
    except (json.JSONDecodeError, OSError):
        stale.append(f); continue
    pid = d.get("pid", 0)
    # A pid that no longer exists, was recycled, or is a zombie is not a running agent.
    if start_ticks(pid) == d.get("start_ticks") and state(pid) not in (None, "Z"):
        live.append(d)
    else:
        stale.append(f)

for f in stale:
    try: f.unlink()
    except OSError: pass

# Every counter uses the same set, so --slots and oc_capacity.sh cannot disagree.
live += scan_unregistered({d["pid"] for d in live})

if action == "--count":
    print(len(live))
elif action == "--slots":
    print(max(0, cap - len(live)))
    print(f"registered={len(live)} cap={cap} pruned={len(stale)}", file=sys.stderr)
elif action == "--prune":
    print(f"pruned {len(stale)} stale entr{'y' if len(stale)==1 else 'ies'}, {len(live)} live")
else:
    if not live:
        print("no agents registered on this machine")
    else:
        now = time.time()
        print(f"{'PID':>7}  {'LABEL':<24} {'TIER':<9} {'ELAPSED':>7}  WORKSPACE")
        for d in sorted(live, key=lambda d: d.get("registered_at") or 0):
            since = d.get("registered_at")
            elapsed = f"{int(now - since)//60:>4}m{int(now - since)%60:02d}" if since else "     -"
            print(f"{d['pid']:>7}  {d.get('label','?')[:24]:<24} {d.get('tier') or d.get('effort','?'):<9} "
                  f"{elapsed}  {d.get('cwd','?')}")
            print(f"{'':>7}  run: {d.get('run_dir','?')}")
PY
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
