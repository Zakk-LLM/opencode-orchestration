# Failure modes

## The agent never returns

`opencode run` waits on inherited stdin. `oc_agent.sh` passes the prompt as an argument and
redirects stdin from `/dev/null`; without that the process sits with no output until it is
killed — measured at four minutes of nothing before a timeout, against seconds for the same
prompt with stdin closed.

`opencode run` also has no internal time limit, so every invocation is wrapped in `timeout`.
Exit code 124 or 137 means the wrapper killed it; `meta.json` reports `timed_out: true`, or
`stalled: true` when `--stall` fired instead.

A repeated timeout is a decomposition problem, not a timeout-value problem.

## The run hangs with no events at all

A permission profile containing `ask` will do this: the engine waits for an answer that no one
can give in a non-interactive run. The wrapper's profiles only ever use `allow` and `deny`; a
profile from elsewhere must be checked for `ask` before use.

## `Model "..." is not supported by any configured account`

The config lists a model the account behind the provider does not serve. The error arrives as a
404 several seconds into the dispatch, after it has been paid for, so `opencode models` belongs
in preflight rather than in the postmortem.

## A clean exit with an unusable result

Check `meta.json.schema_error`. The engine cannot enforce a schema, so a worker can finish
successfully and still answer in prose. That is a failed run: re-dispatch with a flatter schema
or drop the schema and read the prose yourself.

## The permission profile did not apply

`OPENCODE_CONFIG_CONTENT` merges with the user's config rather than replacing it, so the
provider and models survive. If a denied command still ran, the pattern did not match: opencode
matches shell patterns, and a more specific pattern wins over the wildcard.

## The agent wrote nothing

Check in this order:

1. `meta.json` → `exit_code`, `timed_out`
2. `stderr.log` → auth, network, or config failures
3. `events.jsonl` → `tool_use` entries whose state is `error`, usually a permission denial
4. the profile: `read-only` denies edits, and webfetch needs `--network`

## The result contradicts the diff

Normal and expected. A worker's summary reports intent, not outcome. Only `git diff` and the
test run are evidence. When they disagree, the summary is wrong.

## Two agents fought over one file

Overlapping write scopes, and nothing detects it at dispatch time. Recover by keeping one
version, reverting the other, and re-dispatching with disjoint scopes. Prevent it with
`--worktree` per write-capable agent, plus file ownership assigned in `PLAN.md` before anything
is dispatched. See [worktrees.md](worktrees.md).

## A worktree cannot be created

`--worktree` needs `--cwd` to be a git repository, and the branch name `opencode/<name>` must be
free unless the worktree is being reused deliberately. A leftover worktree from an aborted run
blocks reuse of the same path: `oc_worktrees.sh <run> --list` shows what is registered, and
`--remove-merged <base>` removes only what has already landed.

## The worker committed anyway

The prohibition block was missing or diluted. Recover with `git reset --soft HEAD~1`, review the
staged content, and decide yourself. Never leave `git commit` unmentioned in a spec that runs
with `workspace-write`.

## Rate limits or auth failures

`stderr.log` shows them plainly. Lower concurrency to two agents, and re-dispatch the failed
labels only. The completed agents' results stay valid — never restart a whole run for one
failed agent.

## Reading the event log

`events.jsonl` is one JSON object per line:

- `thread.started` → `thread_id`, needed for `--resume`
- `item.completed` with `type: "command_execution"` → the exact command, output, and exit code
- `item.completed` with `type: "agent_message"` → intermediate narration
- `turn.completed` → `usage` token counts

Filter instead of reading the whole file:

```sh
python3 -c 'import json,sys
for l in open(sys.argv[1]):
    e=json.loads(l)
    i=e.get("item",{})
    if i.get("type")=="command_execution":
        print(i.get("exit_code"), i.get("command"))' <run>/agents/<label>/events.jsonl
```

## Cost control

`oc_status.sh` totals the token usage per run. When output tokens run high for the value
returned, the usual causes are an effort level above what the task needs, a spec so vague the
worker explores the repository first, or a missing schema letting it write an essay.
