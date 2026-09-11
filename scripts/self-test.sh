#!/usr/bin/env sh
# Every check must prove it can still go red. A check that cannot fail is worse than no check:
# it looks like coverage.
#
# All breakage happens on a temporary copy, so no tracked file is touched. That makes this
# safe inside a commit hook and removes the need for a "remember to restore it" convention.
set -u
cd "$(dirname "$0")/.." || exit 2
ENGINE=${1:?usage: self-test.sh <engine>}
command -v python3 >/dev/null 2>&1 || { echo "no python3, controls cannot run"; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM
pass=0
fail=0

# Start each control from a clean copy so one break cannot leak into the next.
fresh() {
  rm -rf "$TMP/w"
  mkdir -p "$TMP/w/scripts" || return 2
  cp SKILL.md "$TMP/w/SKILL.md" || return 2
  cp README.md README.zh-TW.md "$TMP/w/" || return 2
  mkdir -p "$TMP/w/references" || return 2
  cp references/prompt-template.md "$TMP/w/references/" || return 2
  cp scripts/*.sh scripts/*.py "$TMP/w/scripts/" 2>/dev/null
  [ -f install.sh ] && cp install.sh "$TMP/w/install.sh"
  return 0
}

# expect <wanted exit code> <name> <command...>
expect() {
  want=$1
  name=$2
  shift 2
  "$@" >"$TMP/out" 2>&1
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'DEAD  %s: wanted exit %s, got %s\n' "$name" "$want" "$rc"
    sed 's/^/      /' "$TMP/out"
  fi
}

# Confirm the clean copy is green first. If the baseline were red, none of the breaks below
# would establish anything.
fresh || exit 2
expect 0 "baseline contract" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"

# The description loses this engine's read-only boundary. That was the actual state of all
# three skills before this check existed.
fresh || exit 2
python3 - "$TMP/w/SKILL.md" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
head, rest = s.split("\n---\n", 1)
# Drop the last sentence of the description; the boundary is that sentence.
head = re.sub(r"(?m)^(description: .*)\.\s*[^.]*\.\s*$", r"\1.", head)
open(p, "w", encoding="utf-8").write(head + "\n---\n" + rest)
PY
expect 1 "description without the boundary" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"

# The ladder drifts: deep falls from high to medium.
fresh || exit 2
sed -i 's/^| `deep` | `high`/| `deep` | `medium`/' "$TMP/w/SKILL.md"
sed -i 's/| `high` | 1800–3600 |/| `medium` | 1800–3600 |/' "$TMP/w/SKILL.md"
expect 1 "tier maps to the wrong effort" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"

# A timeout drifts.
fresh || exit 2
sed -i 's/3600–5400/3600–9999/' "$TMP/w/SKILL.md"
expect 1 "timeout drift" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"

# A whole tier disappears.
fresh || exit 2
sed -i '/^| `frontier` |/d' "$TMP/w/SKILL.md"
expect 1 "a tier is missing" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"

# An access profile disappears.
fresh || exit 2
sed -i '/^| `workspace-write` |/d' "$TMP/w/SKILL.md"
expect 1 "an access profile is missing" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"

# The README loses the sentence saying these profile names do not carry to the siblings.
# Codex's README once said its read-only "reads only", contradicting its own SKILL.md; this
# is the control for that class of regression.
for r in README.md README.zh-TW.md; do
  fresh || exit 2
  python3 - "$TMP/w/$r" <<'PY'
import sys
p = sys.argv[1]
marks = ["omp 自己的", "opencode 自己的", "profile names are",
         "不能沿用到姊妹引擎",
         "does not carry to the siblings"]
lines = open(p, encoding="utf-8").read().split("\n")
keep = [l for l in lines if not any(m in l for m in marks)]
open(p, "w", encoding="utf-8").write("\n".join(keep))
PY
  expect 1 "$r without the cross-engine note" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"
done

# An evidence rule drops out of the worker prompt template. This happened: one sibling gained
# a rule and the other two kept the shorter list.
fresh || exit 2
sed -i '/^- A number is a claim/,+2d' "$TMP/w/references/prompt-template.md"
expect 1 "prompt template lost an evidence rule" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"

fresh || exit 2
rm -f "$TMP/w/references/prompt-template.md"
expect 2 "the prompt template is missing" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"

# Input that cannot be read is 2, not a finding.
expect 2 "SKILL.md does not exist" python3 scripts/check-contract.py "$ENGINE" "$TMP/does-not-exist.md"
expect 2 "unknown engine name" python3 scripts/check-contract.py nosuchengine SKILL.md
fresh || exit 2
rm -f "$TMP/w/README.zh-TW.md"
expect 2 "a README is missing" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"

# Shell syntax: the clean copy is green, an injected error is red.
fresh || exit 2
expect 0 "baseline shell-syntax" sh "$TMP/w/scripts/check-shell-syntax.sh"
printf '\ncase x in\n' >> "$TMP/w/install.sh"
expect 1 "install.sh does not parse" sh "$TMP/w/scripts/check-shell-syntax.sh"

# An error in a dispatch script must be caught too, not only in install.sh. Break one that is
# not the checker itself.
fresh || exit 2
victim=$(ls "$TMP"/w/scripts/*_note.sh 2>/dev/null | head -1)
if [ -n "$victim" ]; then
  printf '\nif [ 1 -eq 1 ]; then\n' >> "$victim"
  expect 1 "a dispatch script does not parse" sh "$TMP/w/scripts/check-shell-syntax.sh"
else
  printf 'DEAD  a dispatch script does not parse: nothing to break\n'
  fail=$((fail + 1))
fi

if [ "$fail" -ne 0 ]; then
  printf '%d passed, %d dead\n' "$pass" "$fail"
  exit 1
fi
printf '%d controls passed, none dead\n' "$pass"
