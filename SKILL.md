---
name: opencode
description: Drive the opencode CLI as a fleet of worker agents while you stay the orchestrator and reviewer. Use when a task is large enough to split across parallel workers — feature implementation, refactors, bug hunts, test writing, documentation drafting, research, multi-file audits — or whenever the user asks to delegate work to opencode. You write the plan, dispatch scoped agents, supervise, review every diff yourself, and own the commit, merge, and deploy steps that workers are never allowed to touch. Sibling of the `codex` skill: same workflow, same run directory, different engine.
---

# opencode Orchestration

opencode writes; you plan, supervise, review, and ship. Workers never commit, never push, never
deploy, and never decide that their own output is acceptable.

This is the same design as the `codex` skill — one run directory, tiers by difficulty, bounded
waiting, an evidence-based review gate, atomic integration — with a different engine underneath.
Everything below that is engine-specific is marked as such.

## What opencode gives you that codex does not

**Enforced prohibitions.** `--permission workspace-write` denies `git commit`, `push`, `rebase`,
`checkout`, `reset`, `merge`, and the rest at the tool layer. In the codex skill those rules can
only be written into the spec and hoped for; here the engine refuses them.

**Named agent presets.** `--agent <name>` runs one of the agents defined in the user's opencode
config, so a house style for "explore" or "plan" is reused instead of re-specified.

**Session forking.** `--fork` branches an existing session instead of extending it: try a second
approach from the same accumulated understanding without polluting the original thread.

**Cost per run.** Every `step_finish` event carries `cost`, so `meta.json` records money as well
as tokens.

## What it costs you

**No sandbox.** codex confines a worker with an OS-level sandbox; opencode has permission rules
and nothing more. A `read-only` worker here is bounded by opencode's own tool layer, not by the
kernel, so a permissive `bash` pattern is a real hole rather than a policy detail. Treat the
permission profile as the whole boundary, and do not run untrusted work.

**No schema enforcement.** opencode has no `--output-schema`. The wrapper appends the schema to
the prompt and validates the final message afterwards, exiting 65 when it does not parse. The
model is asked, not forced, so a schema failure is a real outcome you will occasionally see.

## Preflight

```sh
opencode --version || echo "opencode not installed — stop and tell the user"
"$OPENCODE_SKILL/scripts/oc_agents.sh" --list     # what other windows are already running
opencode models | head                            # models this config can actually reach
```

The last one matters: a model listed in the config is not necessarily served by the account
behind it, and the failure arrives as a 404 several seconds into a paid dispatch.

Agents from other sessions share this machine and this quota, and so does the sibling codex
toolkit. The cap is therefore shared: both wrappers lock the same slot directory and both
counters read both registries, so `AGENT_MAX_AGENTS` (default 5) is the total across engines, not
5 each. `oc_agents.sh --list` shows every agent on the machine whichever toolkit started it. An
idle opencode TUI and the wrapper's own child process are never counted.

Machine-local settings — the cap and the tier-to-model bindings — live in
`${XDG_CONFIG_HOME:-~/.config}/agent-orchestration.env`, which both wrappers source when it
exists. Nothing about a provider's lineup belongs in this repository.

## When not to use this

Do the work yourself when it is a single obvious edit, a one-file read, or anything you can
finish in less time than writing the spec. Never dispatch git mechanics — rebase, merge,
conflict resolution, commit, worktree cleanup — both because `oc_worktrees.sh` and `oc_merge.sh`
do them in one command and because the permission profile forbids workers from running them at
all.

Fan out only when the work decomposes. Parallel agents win on breadth-first work and lose on a
dependency chain, where measured results show multi-agent topologies doing substantially worse
than one agent. Your review capacity, not the worker count, is the limit: about three
review-bearing agents in flight.

Never dispatched, however large the run:

- **Git mechanics** — the permission profile denies them anyway, and `oc_worktrees.sh --rebase`
  and `oc_merge.sh` do them in one command.
- **A fix faster to make than to specify** — a typo, a wrong constant, a one-line guard.
- **Anything you must verify line by line anyway** — review is the expensive half.
- **Running a command to read its output** — you can run it directly.

The test is whether a separate context window earns the spec plus the review: the same rename
across 200 files does, the same rename in three files does not. A dispatched trivial task also
holds a slot the machine cap counts and puts a review ahead of one that mattered.

## Workflow

### 1. Create the run directory

```sh
RUN=$("$OPENCODE_SKILL/scripts/oc_new_run.sh" add-auth-cache)
```

```
<run>/PLAN.md                 decomposition, write scopes, acceptance criteria
<run>/jobs.jsonl              the fan-out, one job per line
<run>/schema/<name>.json      output schemas
<run>/worktrees/<label>/      that agent's isolated checkout, branch opencode/<label>
<run>/agents/<label>/prompt.md NOTES.md events.jsonl stderr.log result.json|last.txt
                     thread.txt started.json meta.json verify.json
<run>/REVIEW.md               your verdict per agent
```

`OPENCODE_RUNS_DIR` overrides the base; the default is
`${XDG_CACHE_HOME:-~/.cache}/opencode-runs`. Never a tmpfs path.

### 2. Decompose, then write PLAN.md

Split by file ownership. Declare order in `jobs.jsonl` — a dependent job is not dispatched until
its dependencies succeed, and is skipped when one fails:

```json
{"label": "api",    "tier": "deep",     "permission": "workspace-write", "worktree": true}
{"label": "client", "tier": "standard", "permission": "workspace-write", "worktree": true,
 "depends_on": ["api"]}
```

Unknown labels and cycles are rejected before anything starts. Concurrency comes from
`oc_capacity.sh light|medium|heavy`. Give every write-capable agent its own `--worktree`.

Order and atomicity are one design. The rule underneath both: work is only ever built on a state
that exists — a dependency's finished result, or the target's real commit. Dispatching a
dependent task early is the expensive mistake, because it works against a schema or signature
that does not exist yet and the whole run is discarded; a failed dependency stops its own subtree
and nothing else. The same rule reappears at merge time, where a branch whose recorded base is no
longer an ancestor of the target is rebased or refused rather than merged silently.

### 3. Write the task spec

One file per agent from [references/prompt-template.md](references/prompt-template.md), with the
scope fence, executable acceptance criteria, the live-notes block, and the prohibition list. Keep
the prohibitions even though the permission profile enforces the git ones: a worker that knows
why it must not commit reports a blocker instead of hunting for a way around it.

Paste the regression scope from `oc_impact.sh --repo <repo> --format md` rather than letting the
worker search for it: it derives the changed files, the symbols they define, the files
referencing those symbols, and the covering tests with `git grep`, in seconds and without tokens.
The economics are fixed — each agent runs the targeted set, the full suite runs once at
integration — with shared surface (build files, config, `conftest.py`) as the flagged exception.

### 4. Pick the tier, the permission profile, and the limits

| `--tier` | `--variant` | use for | `--timeout` |
|----------|-------------|---------|-------------|
| `cheap` | `low` | mechanical edits, renames, formatting, extraction | 300–600 |
| `standard` | `medium` | default: a contained feature, docs, tests for one module | 900–1800 |
| `deep` | `high` | changes across several files, non-obvious bugs, refactors | 1800–3600 |
| `frontier` | `xhigh` | architecture, concurrency, performance, vague requirements | 3600–7200 |
| `max` | `max` | one problem a `frontier` agent already failed twice; never a default | 7200+ |

A tier always sets the variant, and sets the model only when `OPENCODE_TIER_<TIER>_MODEL` is
exported. Both halves matter, and they divide the ladder cleanly: below `deep` the **model**
changes, above it the **variant** does. A cheap model costs an order of magnitude less per token
than a flagship, and a read-only worker reads far more than it writes, so the input price is the
bill. Most of a run belongs on the cheap model at low variant, and promoting a task is a decision
rather than a default. `--model provider/model` and
`--variant` override a tier for one agent, and `--agent <preset>` carries a whole role — model,
temperature, tools, permissions — in one name.

| `--permission` | agent mode | grants | use for |
|----------------|------------|--------|---------|
| `read-only` | `plan` | reading tools plus an allowlist of inspection commands; the write tools are absent | research, audits, review |
| `workspace-write` | `build` | edits, plus bash minus destructive and history-changing git | all implementation |
| `full` | `build` | everything | never without the user's explicit approval |

The agent mode is the second boundary and the stronger one. `plan` has no write, edit, or patch
tool at all: measured with `edit: allow` in force, a plan agent still could not modify a file and
reported that it was blocked. `--agent` overrides the default when a named preset fits better.

Nothing in a profile may resolve to `ask`. opencode defaults `doom_loop` and `external_directory`
to ask, and either one would stop a non-interactive run dead until the timeout; the wrapper pins
them — `doom_loop` denied so a suspected runaway stops, `external_directory` allowed so a spec
can point a worker at a skill file outside the workspace.

`--network` allows webfetch, which is denied by default in every profile. `--allow-git` removes
the git denials and needs a reason. **Never configure `ask` in a profile** — a non-interactive
run has nobody to answer it and will sit until the timeout kills it.

`--timeout` is a runaway guard: estimate the work, then roughly triple it. `--stall` interrupts a
worker that has emitted no event for that long.

### 5. Dispatch

```sh
"$OPENCODE_SKILL/scripts/oc_dispatch.sh" --run-dir "$RUN" --jobs "$RUN/jobs.jsonl" \
  --weight medium --max 4        # --dry-run prints the commands first
```

Engine-specific rules, each learned from a real failure:

- Never let opencode inherit your stdin. The wrapper passes the prompt as an argument and
  redirects stdin from `/dev/null`; without that, `opencode run` waits forever with no output.
- Always wrap in `timeout`. There is no internal limit.
- The permission profile travels in `OPENCODE_CONFIG_CONTENT`, which **merges** with the user's
  config, so the provider, models, and MCP servers stay intact while the boundary changes.
- Capture the session id from the first event; it appears as `sessionID` on every line,
  including error lines, so a failed run is still resumable.

### 6. Supervise without idling

```sh
"$OPENCODE_SKILL/scripts/oc_watch.sh" "$RUN" --timeout 120 --peek
```

Exit 0 means agents changed state and the labels are printed; 1 means the window is free for
work that needs no agent; 2 means the run is finished; 3 means nothing was dispatched. Liveness
is the event log's mtime plus its last event, read from the final 4 KB — never the whole log.
`EXPIRING` and `QUIET` warn before the guards fire, in time to tell a worker to save what it has.

Correct a running worker through `oc_note.sh "$RUN" <label> "..."`, which the live-notes block in
its spec tells it to re-read.

**Never sit idle while agents run.** From the first dispatch until the last review you are either
processing a returned agent or doing work that does not depend on one — writing the next spec,
running tests on what already merged, checking a research source. Waiting for the whole batch
before looking at anything is correct only when the user explicitly asked for it. A regression you
can fix now is fixed ahead of the queue, because a broken integration branch blocks every agent
still to be merged. Pick `--timeout` as the time until your next useful action, not as how long an
agent might take; exit 1 is an instruction to go do that work, not a reason to call again.

A transport failure is not yours to decide silently. When a run dies on a provider or connection
error, report the evidence and ask the user whether to wait for the upstream or resume the
preserved session; the session id survives in `thread.txt`, so asking costs nothing.

#### Keeping your own context small

The context that needs protecting is yours. A worker's context is disposable — created for one
task, gone with it — so let workers read whatever they need, and never split a task or shorten a
spec to save a worker's context. Only the report is bounded, because that is the part that lands
in you: read `result.json` and `verify.json`, use `oc_status.sh --brief` as the digest, open
`events.jsonl` only when something failed, and refer to artifacts by path instead of quoting
them. Summarize for the user from the diff and the check results, not from the worker's prose.

### 7. Review — the part you never delegate

An agent's report is a claim; a command you ran is evidence.

```sh
"$OPENCODE_SKILL/scripts/oc_verify.sh" "$RUN" impl --check "pytest -q"
```

Read the real diff, check every changed file against the declared scope, run each acceptance
criterion yourself, and run a negative control so a passing test is known to fail without the
change. `meta.json.schema_error` is the extra check this engine needs: a clean exit with a
schema error means the worker answered, but not in the shape you asked for. Full protocol in
[references/review-gate.md](references/review-gate.md).

### 8. Fix rounds, continuation, and forking

```sh
"$OPENCODE_SKILL/scripts/oc_agent.sh" --run-dir "$RUN" --label impl-fix1 \
  --resume "$(cat "$RUN/agents/impl/thread.txt")" --cwd /path/to/repo \
  --permission workspace-write --tier deep --prompt-file "$RUN/agents/impl-fix1/prompt.md"
```

Add `--fork` to try a different approach from the same understanding while leaving the original
session intact — useful when the first attempt was reasonable but you want a second opinion from
the same context rather than from a blank one.

Resuming replays the session, so it is not free. Continue a session for the context it holds;
start fresh when the context is small, reconstructible, or already proven wrong. Transport
failures are not yours to decide silently: report the evidence and let the user choose between
waiting for the upstream and resuming.

### 9. Integrate

```sh
"$OPENCODE_SKILL/scripts/oc_merge.sh" --run-dir "$RUN" --repo /path/to/repo --into main \
  --check "pytest -q" --rebase
```

Atomic per branch and for the run: any conflict, failed rebase, or failed check returns the
target to the commit the run started from. This is where the full suite belongs, once per merged
branch. Check drift first with `oc_worktrees.sh "$RUN" --drift main`, and rebase finished
branches with `--rebase`; a worktree whose agent is still running is never touched.

### 10. Ship

You perform every irreversible step. Confirm with the user before anything outward-facing.

## References

- [references/prompt-template.md](references/prompt-template.md) — the task spec structure
- [references/schemas.md](references/schemas.md) — result shapes, and how they are validated here
- [references/worktrees.md](references/worktrees.md) — isolating parallel writers, merging, cleanup
- [references/review-gate.md](references/review-gate.md) — the anti-optimism review protocol
- [references/troubleshooting.md](references/troubleshooting.md) — failure modes and recovery
