# opencode Orchestration Skill

English | [繁體中文](README.zh-TW.md)

A skill for driving a fleet of opencode workers from an orchestrating agent that keeps planning,
supervision, review, and shipping for itself. It is the sibling of the
[codex-orchestration](https://github.com/Zakk-LLM/codex-orchestration) skill: same run directory,
same tiers, same review gate, same atomic integration — a different engine underneath.

The division of labor is fixed. Workers produce code and drafts only. The orchestrator reads the
real diff, runs the tests, and writes the verdict; commits, merges, and releases stay with it.

## Requirements

- opencode 1.18 or newer, with a working provider configured
- Python 3.11 or newer
- Bash

## Install

```bash
git clone <repository-url> opencode-orchestration
cd opencode-orchestration
./install.sh
```

| Agent | Location |
|---|---|
| Claude | `~/.claude/skills/opencode` |
| Codex | `${CODEX_HOME:-~/.codex}/skills/opencode` |
| OpenCode | `~/.config/opencode/skills/opencode` |

## What this engine changes

**Prohibitions are enforced, not requested.** `--permission workspace-write` denies `git commit`,
`push`, `rebase`, `checkout`, `reset`, `merge`, and destructive shell commands at the tool layer.
The codex skill can only write those rules into the spec.

**Named agent presets.** `--agent <name>` reuses an agent defined in the opencode config.

**Session forking.** `--fork` branches a session instead of extending it: a second approach from
the same accumulated understanding, with the original thread left intact.

**Cost per run.** `meta.json` records money alongside tokens, taken from the engine's own events.

**No sandbox.** codex confines a worker at the OS level; opencode has permission rules and
nothing else, so the profile is the entire boundary. Do not run untrusted work.

**No schema enforcement.** There is no `--output-schema`. The wrapper appends the schema to the
prompt and validates the final message, exiting 65 and recording `schema_error` when it does not
parse. The model is asked, not forced.

## Usage

```bash
RUN=$(scripts/oc_new_run.sh add-auth-cache)
scripts/oc_capacity.sh medium
scripts/oc_agents.sh --list

scripts/oc_agent.sh --run-dir "$RUN" --label cache \
  --cwd /path/to/repo --worktree --permission workspace-write \
  --tier deep --timeout 1800 --stall 300 \
  --prompt-file "$RUN/agents/cache/prompt.md" --schema "$RUN/schema/impl.json"

scripts/oc_dispatch.sh --run-dir "$RUN" --jobs "$RUN/jobs.jsonl" --weight medium
scripts/oc_watch.sh "$RUN" --timeout 120 --peek
scripts/oc_verify.sh "$RUN" cache --check "pytest -q"
scripts/oc_merge.sh --run-dir "$RUN" --repo /path/to/repo --into main --check "pytest -q"
```

Every script documents its options under `--help`.

## Permission profiles

| Profile | Grants | Use for |
|---|---|---|
| `read-only` | reading tools plus an allowlist of inspection commands | research, audits, review |
| `workspace-write` | edits, and bash minus destructive and history-changing git | implementation |
| `full` | everything except history-changing git | never without explicit approval |
| `bypass` | everything, git included, plus `--auto` | only in a workspace you would hand a shell to |

`bypass` prints a warning and is never a default. Named presets carry a whole role instead:
`--agent <name>` uses an agent defined in `~/.config/opencode/agent/<name>.md`, which fixes the
model, temperature, tools, and permissions in one place.

`--network` allows webfetch, denied by default. `--allow-git` removes the git denials. A profile
must never contain `ask`: a non-interactive run has nobody to answer it and hangs until the
timeout fires. The profile is merged into the user's config through `OPENCODE_CONFIG_CONTENT`,
so providers, models, and MCP servers stay intact while the boundary changes for that run only.

## Everything else

Tiers, dependency ordering, worktree isolation, bounded waiting, deadline warnings, the
regression-scope tool, the review gate, and atomic integration behave exactly as documented in
the sibling skill. Read [SKILL.md](SKILL.md) for the workflow and `references/` for the detail:

- [references/prompt-template.md](references/prompt-template.md)
- [references/schemas.md](references/schemas.md)
- [references/worktrees.md](references/worktrees.md)
- [references/review-gate.md](references/review-gate.md)
- [references/troubleshooting.md](references/troubleshooting.md)

## Known constraints

- `opencode run` waits forever on inherited stdin; the wrapper redirects it from `/dev/null`.
- There is no internal time limit, so every call is wrapped in `timeout` with SIGINT first.
- A model present in the config is not necessarily served by the account behind it; the 404
  arrives seconds into a paid dispatch, so `opencode models` belongs in preflight.
- Two agents writing one checkout overwrite each other; worktrees and `PLAN.md` ownership
  prevent it.

## License

MIT
