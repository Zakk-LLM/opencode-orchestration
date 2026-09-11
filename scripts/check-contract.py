#!/usr/bin/env python3
"""The three orchestration skills share one tier ladder and share nothing about access.

This check holds two things: the ladder still projects to the agreed values, and the
description states this engine's read-only execution boundary.

Why the boundary belongs in the description: when a skill is selected, the description is
the only text read. All three opening paragraphs used to be near-identical and none said
whether its read-only profile could run a command, so an audit that had to execute checks
was dispatched to omp's read-only — a profile with no bash at all — and the round was lost.
What is asserted is that sentence, not its length, its position, or how it differs from a
sibling's. Those all move when the sentence moves, which makes them proxies rather than the
thing.

No sibling repository is compared. A cross-repository checkout would pin every single-repo
pull request to the other two heads, and what is actually wanted here — each skill stating
its own boundary — is decidable inside one repository.

Exit codes: 0 all assertions hold, 1 the contract is broken, 2 the check could not run.
"""
import re
import sys
from pathlib import Path

TIERS = ["cheap", "standard", "deep", "frontier", "max"]
EFFORT = {"cheap": "low", "standard": "medium", "deep": "high",
          "frontier": "xhigh", "max": "max"}
TIMEOUT = {"cheap": "300–600", "standard": "900–1800", "deep": "1800–3600",
           "frontier": "3600–5400", "max": "3600–5400"}

# Each engine's own boundary sentence and its own profile names. Editing this is editing
# the contract, which is the point; it is not a way around the check.
ENGINES = {
    "omp": {
        "boundary": "`read-only` grants no `bash`",
        "profiles": ["read-only", "workspace-write", "full", "bypass"],
        "readme": {
            "README.md": "These profile names are omp's own.",
            "README.zh-TW.md": "這些設定檔名稱是 omp 自己的。",
        },
    },
    "codex": {
        "boundary": "`read-only` sandbox runs any command while the kernel blocks writes",
        "profiles": ["read-only", "workspace-write", "danger-full-access"],
        "readme": {
            "README.md": "the name does not carry to the siblings",
            "README.zh-TW.md": "這個名稱不能沿用到姊妹引擎",
        },
    },
    "opencode": {
        "boundary": "`read-only` is plan mode and runs no commands",
        "profiles": ["read-only", "inspect", "workspace-write", "full", "bypass"],
        "readme": {
            "README.md": "These profile names are opencode's own.",
            "README.zh-TW.md": "這些設定檔名稱是 opencode 自己的。",
        },
    },
}

# The evidence rules a read-only worker is given. They are the same on all three engines and
# have already drifted once: a rule was added to one sibling's template and the other two kept
# the shorter list for a commit. Each repository asserts the whole list locally rather than
# comparing against a sibling, which is the same reason CI checks out nothing else.
EVIDENCE_RULES = [
    "Every claim carries a source",
    'Report "not found" rather than inferring',
    "Separate what the source states from what you conclude from it",
    "Report which document is wrong, not that they disagree",
    "A number is a claim",
]

CELL = re.compile(r"`([^`]+)`")


def flat(text):
    """Where a line wraps must not decide whether a sentence is present."""
    return re.sub(r"\s+", " ", text)


def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def frontmatter(text):
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 4)
    if end < 0:
        return None
    return text[4:end]


def description_of(fm):
    out, taking = [], False
    for line in fm.split("\n"):
        if line.startswith("description:"):
            taking = True
            out.append(line[len("description:"):].strip())
        elif taking and line[:1] in (" ", "\t"):
            out.append(line.strip())
        elif taking:
            break
    return " ".join(out) if out else None


def projections(text):
    """Read tier -> effort and effort -> timeout from any table, then compose.

    Codex splits the two halves across adjacent tables and keys the second by effort;
    omp and opencode keep both in one. Reading by meaning rather than by table shape is
    what lets one check serve all three.
    """
    tier_effort, effort_timeout, tier_timeout = {}, {}, {}
    for line in text.split("\n"):
        if not line.lstrip().startswith("|"):
            continue
        cs = cells(line)
        found = [t for c in cs for t in CELL.findall(c)]
        tier = next((t for t in found if t in TIERS), None)
        effort = next((t for t in found if t in set(EFFORT.values())), None)
        # A cell may carry a note: codex writes `900–1800 (default 1800)`. The contract is
        # the range, not whatever is written after it.
        timeout = next((m.group(1) for m in
                        (re.match(r"(\d+(?:–\d+|\+))(?:\s|$)", c) for c in cs) if m), None)
        if tier and effort:
            tier_effort[tier] = effort
        if effort and timeout:
            effort_timeout[effort] = timeout
        if tier and timeout:
            tier_timeout[tier] = timeout
    return tier_effort, effort_timeout, tier_timeout


def main():
    if len(sys.argv) != 3:
        print("usage: check-contract.py <engine> <SKILL.md>", file=sys.stderr)
        return 2
    engine, path = sys.argv[1], Path(sys.argv[2])
    if engine not in ENGINES:
        print("unknown engine: %s" % engine, file=sys.stderr)
        return 2
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        print("cannot read %s: %s" % (path, exc), file=sys.stderr)
        return 2
    spec = ENGINES[engine]
    bad = []

    fm = frontmatter(text)
    if fm is None:
        bad.append("no YAML frontmatter, so there is no description to read")
    else:
        if ("name: %s" % engine) not in fm:
            bad.append("frontmatter name is not %s" % engine)
        desc = description_of(fm)
        if desc is None:
            bad.append("frontmatter has no description")
        elif spec["boundary"] not in flat(desc):
            bad.append("description does not state %s's read-only execution boundary; "
                       "missing: %s" % (engine, spec["boundary"]))

    tier_effort, effort_timeout, tier_timeout = projections(text)
    for tier in TIERS:
        want_e = EFFORT[tier]
        got_e = tier_effort.get(tier)
        if got_e is None:
            bad.append("the tier table has no `%s` row" % tier)
            continue
        if got_e != want_e:
            bad.append("`%s` maps to `%s`; the contract is `%s`" % (tier, got_e, want_e))
        got_t = tier_timeout.get(tier) or effort_timeout.get(got_e)
        if got_t is None:
            bad.append("`%s` has no timeout, neither directly nor through `%s`"
                       % (tier, got_e))
        elif got_t != TIMEOUT[tier]:
            bad.append("`%s` allows %s; the contract is %s" % (tier, got_t, TIMEOUT[tier]))

    # A profile cell may carry a note too: opencode writes `inspect` (default).
    listed = set()
    for line in text.split("\n"):
        if not line.lstrip().startswith("|"):
            continue
        m = CELL.match(cells(line)[0])
        if m:
            listed.add(m.group(1))
    for profile in spec["profiles"]:
        if profile not in listed:
            bad.append("the access table has no `%s` row" % profile)

    # The README is the second place permissions are explained and the first one a reader
    # meets. Codex's README once said its read-only "reads only" while the SKILL.md in the
    # same repository spent a paragraph saying it runs any command. Two documents in one
    # repository contradicted each other, and the misleading half was the one that steers a
    # reader away from the right profile. So the sentence is held here too.
    for name, needle in spec["readme"].items():
        rp = path.parent / name
        try:
            body = rp.read_text(encoding="utf-8")
        except OSError as exc:
            print("cannot read %s: %s" % (rp, exc), file=sys.stderr)
            return 2
        if needle not in flat(body):
            bad.append("%s does not say these profile names do not carry to the siblings; "
                       "missing: %s" % (name, needle))

    tp = path.parent / "references" / "prompt-template.md"
    try:
        template = flat(tp.read_text(encoding="utf-8"))
    except OSError as exc:
        print("cannot read %s: %s" % (tp, exc), file=sys.stderr)
        return 2
    for rule in EVIDENCE_RULES:
        if rule not in template:
            bad.append("references/prompt-template.md is missing an evidence rule: %s" % rule)

    if bad:
        for line in bad:
            print("%s: %s" % (path, line))
        return 1
    print("%s: contract intact — %d tiers, %d access profiles, %d READMEs carry the "
          "cross-engine note, %d evidence rules in the prompt template" %
          (path, len(TIERS), len(spec["profiles"]), len(spec["readme"]),
           len(EVIDENCE_RULES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
