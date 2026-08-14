#!/usr/bin/env bash
# Create a run directory on disk and print its path. Never use a tmpfs path: runs must
# survive a reboot and can hold large event logs.
set -euo pipefail

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Usage: oc_new_run.sh [SLUG]

Creates <OPENCODE_RUNS_DIR>/<timestamp>-<slug>/ with agents/ and schema/ plus a PLAN.md
skeleton, and prints the path. The directory is created exclusively, so two runs started in
the same second never share one directory.
EOF
    exit 0 ;;
esac

SLUG=${1:-run}
SLUG=$(printf '%s' "$SLUG" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//;s/-*$//')
[ -n "$SLUG" ] || SLUG=run
BASE=${OPENCODE_RUNS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/opencode-runs}
STAMP=$(date +%Y%m%d-%H%M%S)
RUN="$BASE/$STAMP-$SLUG"

# mkdir without -p fails when the directory exists, which is the collision signal: two runs
# with the same slug in the same second must not land in one directory.
mkdir -p "$BASE"
n=0
until mkdir "$RUN" 2>/dev/null; do
  n=$((n + 1))
  [ "$n" -gt 50 ] && { echo "cannot create a unique run directory under $BASE" >&2; exit 1; }
  RUN="$BASE/$STAMP-$SLUG-$n"
done
mkdir -p "$RUN/agents" "$RUN/schema"
cat > "$RUN/PLAN.md" <<EOF
# Run: $SLUG

Created: $(date -Iseconds)
Goal:
Workspace:
Acceptance criteria:

## Agents

| label | scope (files/dirs) | sandbox | effort | depends on |
|-------|--------------------|---------|--------|------------|
EOF
printf '%s\n' "$RUN"
