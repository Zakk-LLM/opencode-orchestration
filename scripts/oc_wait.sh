#!/usr/bin/env bash
# Block until at least one not-yet-handled agent finishes, then print its label and state,
# one per line. Lets the orchestrator review agents as they land instead of waiting for the
# slowest one.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: oc_wait.sh <run-dir> [--handled a,b,...] [--interval SEC] [--timeout SEC]

Prints "<label> <state>" for every agent that has finished and is not in --handled,
as soon as at least one exists. Exit 0 when something is printed, 1 on timeout,
2 on a usage error. Feed the labels you already reviewed back in via --handled.
EOF
}

RUN=${1:-}; shift || true
[ -n "$RUN" ] || { usage >&2; exit 2; }
[ "$RUN" = "-h" ] || [ "$RUN" = "--help" ] && { usage; exit 0; }

HANDLED=""; INTERVAL=15; TIMEOUT=3600
while [ $# -gt 0 ]; do
  case "$1" in
    --handled) HANDLED=$2; shift 2 ;;
    --interval) INTERVAL=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -d "$RUN/agents" ] || { echo "no agents under $RUN" >&2; exit 2; }

WAITED=0
while :; do
  FOUND=0
  for meta in "$RUN"/agents/*/meta.json; do
    [ -f "$meta" ] || continue
    label=$(basename "$(dirname "$meta")")
    case ",$HANDLED," in *",$label,"*) continue ;; esac
    code=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["exit_code"], int(bool(m.get("timed_out"))))' "$meta")
    set -- $code
    if [ "$1" = 0 ]; then state=OK; elif [ "$2" = 1 ]; then state=TIMEOUT; else state="FAIL($1)"; fi
    printf '%s %s\n' "$label" "$state"
    FOUND=1
  done
  [ "$FOUND" = 1 ] && exit 0
  [ "$WAITED" -ge "$TIMEOUT" ] && exit 1
  sleep "$INTERVAL"
  WAITED=$((WAITED + INTERVAL))
done
