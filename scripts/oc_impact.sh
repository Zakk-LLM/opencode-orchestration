#!/usr/bin/env bash
# Derive the blast radius of a change: which symbols it touched, which files reference them,
# and which tests cover those files. Computed from the diff with grep, so it costs seconds and
# no tokens — a worker handed this list does not have to read the repository to find out what
# its change might break.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: oc_impact.sh --repo DIR [--base REF] [--limit N] [--format text|md]

  --repo DIR    repository or worktree to inspect
  --base REF    diff against this ref instead of the working tree
  --limit N     stop listing referencing files per symbol after N (default 20)
  --format md   emit a block ready to paste into a task spec

Prints: changed files, the symbols their diff defines, files referencing those symbols, and
candidate tests. Everything is heuristic and deliberately cheap; it narrows the search, it does
not replace running the tests.
EOF
}

REPO=; BASE=; LIMIT=20; FORMAT=text
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=$2; shift 2 ;;
    --base) BASE=$2; shift 2 ;;
    --limit) LIMIT=$2; shift 2 ;;
    --format) FORMAT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || { usage >&2; exit 2; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "$REPO is not a git repository" >&2; exit 2; }

if [ -n "$BASE" ]; then
  DIFF=$(git -C "$REPO" diff "$BASE")
  CHANGED=$(git -C "$REPO" diff --name-only "$BASE")
else
  DIFF=$(git -C "$REPO" diff HEAD)
  CHANGED=$( { git -C "$REPO" diff --name-only HEAD
               git -C "$REPO" ls-files --others --exclude-standard; } | sort -u)
fi
[ -n "$CHANGED" ] || { echo "no changes in $REPO" >&2; exit 1; }

REPO="$REPO" LIMIT="$LIMIT" FORMAT="$FORMAT" CHANGED="$CHANGED" DIFF="$DIFF" python3 <<'PY'
import os, re, subprocess

repo, limit, fmt = os.environ["REPO"], int(os.environ["LIMIT"]), os.environ["FORMAT"]
changed = [f for f in os.environ["CHANGED"].splitlines() if f.strip()]
diff = os.environ["DIFF"]

# Definition shapes across the languages this is likely to meet. Missing one costs recall, not
# correctness: the acceptance tests still run either way.
PATTERNS = [
    r"(?:async\s+)?def\s+(\w+)", r"class\s+(\w+)", r"func\s+(?:\([^)]*\)\s*)?(\w+)",
    r"fn\s+(\w+)", r"(?:export\s+)?(?:async\s+)?function\s+(\w+)",
    r"(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s*)?\(", r"type\s+(\w+)", r"interface\s+(\w+)",
    r"^\s*(\w+)\s*\(\)\s*\{", r"^\s*([A-Z][A-Z0-9_]{2,})\s*=",
]
symbols = set()
for line in diff.splitlines():
    if not line.startswith(("+", "-")) or line.startswith(("+++", "---")):
        continue
    body = line[1:]
    for pat in PATTERNS:
        m = re.search(pat, body)
        if m and m.group(1) not in ("if", "for", "while", "return", "else"):
            symbols.add(m.group(1))

SKIP = (".git/", "node_modules/", "vendor/", "dist/", "build/", "target/", "__pycache__/",
        ".venv/", ".mypy_cache/", ".pytest_cache/")

def referencing(symbol):
    try:
        out = subprocess.run(["git", "-C", repo, "grep", "-l", "-w", "-F", "--", symbol],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    files = [f for f in out.splitlines() if f and not f.startswith(SKIP)]
    return [f for f in files if f not in changed]

TESTY = re.compile(r"(^|/)(tests?|spec|__tests__)/|(^|/)test_|_test\.|\.test\.|\.spec\.")
refs, tests, truncated = {}, set(), []
for s in sorted(symbols):
    hits = referencing(s)
    if len(hits) > limit:
        truncated.append((s, len(hits)))
        hits = hits[:limit]
    if hits:
        refs[s] = hits
    tests.update(h for h in hits if TESTY.search(h))

# Tests named after a changed file are usually the cheapest useful signal.
for f in changed:
    stem = os.path.splitext(os.path.basename(f))[0]
    if not stem:
        continue
    try:
        out = subprocess.run(["git", "-C", repo, "ls-files"], capture_output=True,
                             text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        break
    for cand in out.splitlines():
        if TESTY.search(cand) and stem in os.path.basename(cand):
            tests.add(cand)

# A change to shared surface cannot be covered by a targeted subset.
SHARED = ("package.json", "pyproject.toml", "setup.py", "requirements", "go.mod", "Cargo.toml",
          "Makefile", "conftest.py", "__init__.py", "config", "settings", ".github/")
broad = [f for f in changed if any(k in f for k in SHARED)]

if fmt == "md":
    print("## Regression scope (precomputed — do not search the repository for this)")
    print("\nChanged files:")
    for f in changed:
        print(f"- `{f}`")
    if refs:
        print("\nCallers and other references to the symbols this change defines:")
        for s, hits in refs.items():
            print(f"- `{s}`: " + ", ".join(f"`{h}`" for h in hits))
    else:
        print("\nNo other file references the changed symbols.")
    if tests:
        print("\nRun exactly these tests, plus the acceptance commands:")
        for tst in sorted(tests):
            print(f"- `{tst}`")
    else:
        print("\nNo test file covers these paths. Say so in your report instead of inventing one.")
    if broad:
        print(f"\nShared surface touched ({', '.join('`%s`' % b for b in broad)}), so the full "
              "suite is justified here.")
    if truncated:
        print("\nTruncated: " + "; ".join(f"`{s}` has {n} references, first {limit} listed"
                                          for s, n in truncated))
else:
    print(f"changed files ({len(changed)}):")
    for f in changed:
        print(f"  {f}")
    print(f"\nsymbols defined in the diff ({len(symbols)}): {', '.join(sorted(symbols)) or '(none)'}")
    print("\nreferencing files:")
    for s, hits in refs.items() or {}.items():
        print(f"  {s}: {' '.join(hits)}")
    if not refs:
        print("  (none)")
    print("\ncandidate tests:")
    for tst in sorted(tests) or []:
        print(f"  {tst}")
    if not tests:
        print("  (none found — report that rather than inventing coverage)")
    if broad:
        print(f"\nshared surface touched: {' '.join(broad)} — a full suite run is justified")
    for s, n in truncated:
        print(f"\nnote: {s} has {n} references, only the first {limit} are listed")
PY
