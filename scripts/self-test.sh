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
  [ ! -f references/reflect-prompt.md ] ||
    cp references/reflect-prompt.md "$TMP/w/references/" || return 2
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

# Shared event fixtures exercise the parser through both public consumers.
fresh || exit 2
cat > "$TMP/event-controls.py" <<'PY'
import fcntl, json, os, pathlib, shlex, subprocess, sys, threading, time

root = pathlib.Path(sys.argv[1])
tmp = root.parent
sys.path.insert(0, str(root / "scripts"))

_MISSING = object()

def event(kind, call, name="read", ok=True, args=None, exit_code=_MISSING):
    status = "pending" if kind == "tool_execution_start" else \
        ("completed" if ok else "error")
    state = {"status": status, "input": args or {}}
    if exit_code is not _MISSING:
        state["metadata"] = {"exit": exit_code}
    row = {"type": "tool_use", "part": {"callID": call, "tool": name, "state": state}}
    return json.dumps(row, separators=(",", ":"), ensure_ascii=False) + "\n"

dead = 0
def run(name, fn):
    global dead
    try:
        fn()
    except Exception as exc:
        print(f"DEAD  {name}: {exc}")
        dead += 1
    else:
        print(f"PASS  {name}")

def fake_opencode(lines, delay=0, exit_code=0):
    bindir = tmp / "bin"
    bindir.mkdir(exist_ok=True)
    script = bindir / "opencode"
    script.write_text("#!/usr/bin/env python3\nimport os,sys,time\n" +
                      "p=os.environ.get('FAKE_COUNT')\n" +
                      "open(p,'a').write('1\\n') if p else None\n" +
                      f"lines={lines!r}\n" +
                      "for line in lines:\n print(line, flush=True)\n" +
                      f"time.sleep({delay})\nsys.exit({exit_code})\n")
    script.chmod(0o755)
    return bindir

def dispatch_fake(name, lines, *, delay=0, exit_code=0, max_tools=None, timeout=4):
    bindir = fake_opencode(lines, delay, exit_code)
    run_dir = tmp / name
    env = os.environ | {"PATH": f"{bindir}:{os.environ['PATH']}", "AGENT_START_STAGGER": "0",
                        "OPENCODE_REGISTRY_DIR": str(tmp / f"{name}-registry")}
    cmd = [root / "scripts/oc_agent.sh", "--run-dir", run_dir, "--label", "w",
           "--prompt", "x", "--admission", "off", "--timeout", str(timeout)]
    if max_tools is not None:
        cmd += ["--max-tools", str(max_tools)]
    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    return result, json.loads((run_dir / "agents/w/meta.json").read_text())

def parser_boundaries():
    from oc_events import scan_tools
    path = tmp / "events.jsonl"
    body = event("tool_execution_start", "pending") + \
           event("tool_execution_end", "a", args={"path": "/one"}) + \
           event("tool_execution_end", "b", name="skill", ok=False, args={"path": "/two"}) + \
           event("tool_execution_end", "c", name="bash", args={"command": "x" * 100}, exit_code=2) + \
           event("tool_execution_end", "d", name="bash", exit_code=0) + \
           event("tool_execution_end", "dup", name="todowrite") + \
           event("tool_execution_end", "dup", name="skill") + \
           event("tool_execution_end", "e", name="bash", exit_code=None) + \
           "{malformed}\n"
    path.write_text(body + event("tool_execution_end", "half").rstrip())
    rows, offset = scan_tools(path, 0)
    assert [r["name"] for r in rows] == [
        "read", "skill", "bash", "bash", "todowrite", "skill", "bash"]
    assert [r["ok"] for r in rows] == [True, False, False, True, True, True, True]
    assert "/one" in rows[0]["args_head"] and "/two" in rows[1]["args_head"]
    assert all(len(r["args_head"]) <= 80 for r in rows)
    assert offset == len(body.encode())
    rows2, offset2 = scan_tools(path, offset)
    assert rows2 == [] and offset2 == offset
    with path.open("a") as out:
        out.write("\n")
    rows2, offset2 = scan_tools(path, offset)
    assert len(rows2) == 1 and offset2 == path.stat().st_size
    whole, whole_offset = scan_tools(path, 0)
    assert whole == rows + rows2 and whole_offset == offset2
    path.write_text(event("tool_execution_end", "new", name="custom"))
    reset, reset_offset = scan_tools(path, offset2)
    assert [row["name"] for row in reset] == ["custom"]
    assert reset_offset == path.stat().st_size

def wrapper_counts():
    lines = [event("tool_execution_start", "pending", args={"path": "/x"}).strip(),
             event("tool_execution_end", "a").strip(),
             event("tool_execution_end", "b", ok=False).strip(),
             event("tool_execution_end", "c", name="bash", exit_code=7).strip()]
    result, meta = dispatch_fake("agent-run", lines, timeout=2)
    assert result.returncode == 0, result.stderr
    assert meta["tool_calls"] == 1 and meta["failed_commands"] == 2

def watch_incremental_identity():
    run_dir = tmp / "watch-run"
    agent = run_dir / "agents/w"
    agent.mkdir(parents=True)
    events = agent / "events.jsonl"
    events.write_text(event("tool_execution_end", "a", name="x" * 500))
    started_at = int(time.time())
    (agent / "started.json").write_text(json.dumps(
        {"started_at": started_at, "deadline": started_at + 1000, "timeout_s": 1000}))
    cmd = [root / "scripts/oc_watch.sh", run_dir, "--timeout", "0", "--interval", "1",
           "--reflect-tools", "999", "--reflect-min", "999999"]
    for expected in (1, 1):
        result = subprocess.run(cmd, capture_output=True, text=True)
        assert result.returncode == expected, result.stderr
    state = json.loads((run_dir / ".watch-state").read_text())
    first = state["w#tools"]
    assert first["count"] == 1 and first["offset"] == events.stat().st_size
    events.write_text(event("tool_execution_end", "b") + event("tool_execution_end", "c"))
    subprocess.run(cmd, capture_output=True)
    state = json.loads((run_dir / ".watch-state").read_text())
    assert state["w#tools"]["count"] == 2
    (agent / "started.json").write_text(json.dumps(
        {"started_at": 11, "deadline": int(time.time()) + 1000, "timeout_s": 1000}))
    subprocess.run(cmd, capture_output=True)
    state = json.loads((run_dir / ".watch-state").read_text())
    assert state["w#tools"]["started_at"] == 11 and state["w#tools"]["count"] == 2

def make_watch(name, successes, failures=0, age=0, deadline=2000, label="w"):
    run_dir = tmp / name
    agent = run_dir / f"agents/{label}"
    agent.mkdir(parents=True)
    rows = [event("tool_execution_end", f"s{i}") for i in range(successes)]
    rows += [event("tool_execution_end", f"f{i}", ok=False) for i in range(failures)]
    (agent / "events.jsonl").write_text("".join(rows))
    now = int(time.time())
    (agent / "started.json").write_text(json.dumps(
        {"started_at": now - age, "deadline": now + deadline, "timeout_s": age + deadline}))
    return run_dir

def poll_watch(run_dir, tools=100, minutes=45, state=None):
    command = [root / "scripts/oc_watch.sh", run_dir, "--timeout", "0", "--interval", "1",
               "--reflect-tools", str(tools), "--reflect-min", str(minutes)]
    if state is not None:
        command += ["--state", state]
    return subprocess.run(command, capture_output=True, text=True)

def reflect_threshold_and_dedup():
    run_dir = make_watch("threshold-run", 99, failures=5)
    first = poll_watch(run_dir)
    assert first.returncode == 1 and "REFLECT" not in first.stdout
    with (run_dir / "agents/w/events.jsonl").open("a") as out:
        out.write(event("tool_execution_end", "hundred"))
    second = poll_watch(run_dir)
    assert second.returncode == 0 and second.stdout.count("REFLECT 1") == 1
    third = poll_watch(run_dir)
    assert third.returncode == 1 and "REFLECT" not in third.stdout
    state = json.loads((run_dir / ".watch-state").read_text())
    assert state["w#reflect"]["pending"] is True
    with (run_dir / "agents/w/events.jsonl").open("a") as out:
        out.write("".join(event("tool_execution_end", f"later{i}") for i in range(100)))
    fourth = poll_watch(run_dir)
    assert fourth.returncode == 1 and "REFLECT" not in fourth.stdout

def reflect_single_and_deadline():
    both = make_watch("both-run", 100, age=3600)
    result = poll_watch(both)
    assert result.returncode == 0 and result.stdout.count("REFLECT") == 1
    elapsed = make_watch("elapsed run", 0, age=3600, label="w;echo bad")
    custom_state = tmp / "custom state"
    result = poll_watch(elapsed, state=custom_state)
    advertised = result.stdout.split("— ", 1)[1].strip()
    assert shlex.split(advertised) == [
        str(root / "scripts/oc_reflect.sh"), str(elapsed), "w;echo bad",
        "--trigger", "elapsed", "--state", str(custom_state)]
    late = make_watch("late-run", 100, age=3600, deadline=599)
    result = poll_watch(late)
    assert "REFLECT" not in result.stdout

def reflect_identity_reset():
    run_dir = make_watch("identity-run", 2)
    poll_watch(run_dir, tools=1)
    state_path = run_dir / ".watch-state"
    state = json.loads(state_path.read_text())
    state["w#reflect"]["n"] = 7
    state_path.write_text(json.dumps(state))
    started = json.loads((run_dir / "agents/w/started.json").read_text())
    started["started_at"] += 1
    (run_dir / "agents/w/started.json").write_text(json.dumps(started))
    poll_watch(run_dir, tools=999, minutes=999)
    state = json.loads(state_path.read_text())
    assert state["w#reflect"] == {
        "n": 7, "base_count": 0, "base_at": started["started_at"], "pending": False}

def max_tools_slow():
    lines = [event("tool_execution_end", str(i)).strip() for i in range(11)]
    result, meta = dispatch_fake("budget-slow", lines, delay=20, max_tools=10, timeout=30)
    assert result.returncode == 66
    assert meta["over_budget"] is True and meta["tool_calls"] == 11

def max_tools_fast():
    lines = [event("tool_execution_end", str(i)).strip() for i in range(11)]
    result, meta = dispatch_fake("budget-fast", lines, max_tools=10)
    assert result.returncode == 66 and meta["over_budget"] is True

def max_tools_exact():
    lines = [event("tool_execution_end", str(i)).strip() for i in range(10)]
    result, meta = dispatch_fake("budget-exact", lines, max_tools=10)
    assert result.returncode == 0 and meta["over_budget"] is False

def answer(value):
    return json.dumps({"type": "text", "part": {"text": value}})
def reflect_run(name, value, *, extra_events=(), env_extra=None, dry=False, exit_code=0,
                delay=0, mutate=None, prepare=None, trigger=None):
    run_dir = tmp / name
    worker = run_dir / "agents/w"
    worker.mkdir(parents=True, exist_ok=True)
    work = tmp / f"{name}-work"
    work.mkdir(exist_ok=True)
    (worker / "prompt.md").write_text("SPEC SENTENCE\n")
    (worker / "NOTES.md").write_text("# Live notes\nNOTE SENTENCE\n")
    (run_dir / "maintainer.md").write_text("STOP HERE\n")
    rows = event("tool_execution_end", "worker")
    (worker / "events.jsonl").write_text(rows)
    now = int(time.time())
    (worker / "started.json").write_text(json.dumps(
        {"started_at": now, "cwd": str(work), "deadline": now + 1000, "timeout_s": 1000}))
    state = {"w#tools": {"started_at": now, "offset": len(rows.encode()), "count": 1},
             "w#reflect": {"n": 0, "base_count": 0, "base_at": now, "pending": True}}
    (run_dir / ".watch-state").write_text(json.dumps(state))
    if prepare:
        prepare(run_dir, worker)
    lines = list(extra_events)
    if value is not None:
        lines.append(answer(value))
    bindir = fake_opencode(lines, delay=delay, exit_code=exit_code)
    if (env_extra or {}).get("FAKE_TIMEOUT"):
        timeout = bindir / "timeout"
        timeout.write_text("#!/usr/bin/env python3\nimport subprocess,sys\n"
            "a=sys.argv[1:]\nwhile a and a[0].startswith('--'): a.pop(0)\n"
            "a.pop(0)\ntry: subprocess.run(a,timeout=.5); sys.exit(0)\n"
            "except subprocess.TimeoutExpired: sys.exit(124)\n")
        timeout.chmod(0o755)
    env = os.environ | {"PATH": f"{bindir}:{os.environ['PATH']}",
                        "OPENCODE_REGISTRY_DIR": str(tmp / f"{name}-registry"),
                        "AGENT_SLOTS_DIR": str(tmp / f"{name}-slots"),
                        "AGENT_ORCHESTRATION_ENV": str(tmp / "no-agent-env")}
    env.update(env_extra or {})
    cmd = [root / "scripts/oc_reflect.sh", run_dir, "w"]
    if trigger:
        cmd += ["--trigger", trigger]
    if dry:
        cmd.append("--dry-run")
    thread = threading.Thread(target=mutate) if mutate else None
    if thread:
        thread.start()
    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if thread:
        thread.join()
    return run_dir, result, state

def valid_no_issue():
    value = "```json\n" + json.dumps({"verdict": "NO_ISSUE",
        "reason": "The route matches."}) + "\n```"
    run_dir, result, _ = reflect_run("reflect-ok", value)
    assert result.returncode == 0, result.stderr
    report = json.loads((run_dir / "agents/w/reflect-1.json").read_text())
    assert report["verdict"] == "NO_ISSUE" and report["tools_at_check"] == 1
    state = json.loads((run_dir / ".watch-state").read_text())
    assert state["w#reflect"]["n"] == 1 and state["w#reflect"]["pending"] is False
    assert state["w#reflect"]["base_count"] == 1

def valid_route():
    value = json.dumps({"verdict": "ROUTE_CORRECTION", "reason": "A stop was bypassed.",
        "next_step": "Stop and report.", "quotes": [{"source": "maintainer.md",
        "text": "STOP HERE"}]})
    run_dir, result, _ = reflect_run("reflect-route", value, trigger="maintainer")
    assert result.returncode == 0 and "Stop and report." in result.stdout
    assert json.loads((run_dir / "agents/w/reflect-1.json").read_text())["trigger"] == "maintainer"
    assert (run_dir / "agents/w/NOTES.md").read_text() == "# Live notes\nNOTE SENTENCE\n"

def valid_cannot_judge():
    value = json.dumps({"verdict": "CANNOT_JUDGE", "reason": "No maintainer quote applies."})
    run_dir, result, _ = reflect_run("reflect-cannot", value)
    assert result.returncode == 0
    assert json.loads((run_dir / "agents/w/reflect-1.json").read_text())["verdict"] == "CANNOT_JUDGE"

def invalid_result(name, obj):
    run_dir, result, _ = reflect_run(f"reflect-invalid-{name}", json.dumps(obj))
    assert result.returncode != 0 and (run_dir / "agents/w/reflect-1.error").exists()
    assert not (run_dir / "agents/w/reflect-1.json").exists()

def empty_result():
    run_dir, result, _ = reflect_run("reflect-empty", None)
    assert result.returncode != 0 and (run_dir / "agents/w/reflect-1.error").exists()

def failed_reflector():
    value = json.dumps({"verdict": "NO_ISSUE", "reason": "x"})
    run_dir, result, _ = reflect_run("reflect-exit", value, exit_code=1)
    assert result.returncode != 0 and (run_dir / "agents/w/reflect-1.error").exists()
    assert (run_dir / "reflect/w-1/agents/reflector/meta.json").exists()

def dry_run_prompt():
    def prepare(_, worker):
        rows = []
        for i in range(45):
            rows.append(event("tool_execution_end", f"d{i}", ok=i != 6,
                              args={"index": i}))
        (worker / "events.jsonl").write_text("".join(rows))
        (worker / "reflect-7.json").write_text(json.dumps(
            {"verdict": "NO_ISSUE", "reason": "history"}))
    run_dir, _, state = reflect_run("reflect-dry", json.dumps(
        {"verdict": "NO_ISSUE", "reason": "x"}), dry=True, prepare=prepare)
    prompt = (run_dir / "agents/w/reflect-8.prompt.md").read_text()
    heads = [prompt.index(x) for x in ("## prompt.md", "## maintainer.md", "## NOTES.md",
                                      "## Tool summary")]
    summary = prompt.split("## Tool summary", 1)[1].split("## Previous reflection", 1)[0]
    assert heads == sorted(heads) and summary.count("\n- ") == 40
    assert '"index":5' in summary and "error" in summary and "Historical" in prompt
    assert json.loads((run_dir / ".watch-state").read_text()) == state
    assert not (run_dir / "reflect").exists()

def admission_preserves_pending():
    value = json.dumps({"verdict": "NO_ISSUE", "reason": "x"})
    run_dir, result, state = reflect_run("reflect-full", value, env_extra={"AGENT_MAX_AGENTS": "0"})
    assert result.returncode == 3
    assert json.loads((run_dir / ".watch-state").read_text()) == state
    assert not (run_dir / "agents/w/reflect-1.error").exists()

def over_budget_is_error():
    tools = [event("tool_execution_end", str(i)).strip() for i in range(11)]
    value = json.dumps({"verdict": "NO_ISSUE", "reason": "x"})
    run_dir, result, _ = reflect_run("reflect-budget", value, extra_events=tools)
    assert result.returncode != 0 and (run_dir / "agents/w/reflect-1.error").exists()

def lock_and_numbering():
    lock = tmp / "reflect-lock/agents/w/.reflect.lock"
    lock.parent.mkdir(parents=True)
    with lock.open("w") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        _, result, state = reflect_run("reflect-lock", json.dumps(
            {"verdict": "NO_ISSUE", "reason": "x"}))
        assert result.returncode == 2
        assert json.loads((tmp / "reflect-lock/.watch-state").read_text()) == state
    run_dir, result, _ = reflect_run("reflect-lock", None)
    assert result.returncode != 2 and (run_dir / "agents/w/reflect-1.error").exists()
    run_dir, result, _ = reflect_run("reflect-lock", None)
    assert result.returncode != 2 and (run_dir / "agents/w/reflect-2.error").exists()

def completion_uses_current_count():
    name = "reflect-current"
    def mutate():
        time.sleep(1)
        with (tmp / name / "agents/w/events.jsonl").open("a") as out:
            out.write("".join(event("tool_execution_end", f"new{i}") for i in range(100)))
    value = json.dumps({"verdict": "NO_ISSUE", "reason": "x"})
    run_dir, result, _ = reflect_run(name, value, delay=3, mutate=mutate)
    assert result.returncode == 0
    state = json.loads((run_dir / ".watch-state").read_text())
    assert state["w#reflect"]["base_count"] == 101
    assert "REFLECT" not in poll_watch(run_dir).stdout

def old_inquiry_preserves_new_identity():
    name = "reflect-identity"
    replacement = {}
    def mutate():
        time.sleep(1)
        started_path = tmp / name / "agents/w/started.json"
        started = json.loads(started_path.read_text())
        started["started_at"] += 10
        started_path.write_text(json.dumps(started))
        replacement.update({
            "w#tools": {"started_at": started["started_at"], "offset": 0, "count": 0},
            "w#reflect": {"n": 4, "base_count": 0, "base_at": started["started_at"],
                          "pending": False}})
        (tmp / name / ".watch-state").write_text(json.dumps(replacement))
    value = json.dumps({"verdict": "NO_ISSUE", "reason": "x"})
    run_dir, result, _ = reflect_run(name, value, delay=3, mutate=mutate)
    assert result.returncode == 0 and (run_dir / "agents/w/reflect-1.json").exists()
    assert json.loads((run_dir / ".watch-state").read_text()) == replacement

def timeout_does_not_redrive():
    count = tmp / "reflect-timeout-count"
    value = json.dumps({"verdict": "NO_ISSUE", "reason": "x"})
    start = time.time()
    run_dir, result, _ = reflect_run("reflect-timeout", value, delay=20,
        env_extra={"FAKE_TIMEOUT": "1", "FAKE_COUNT": str(count)})
    assert time.time() - start < 8 and count.read_text().splitlines() == ["1"]
    assert result.returncode != 0 and (run_dir / "agents/w/reflect-1.error").exists()

def status_fixture(name, running=False):
    run_dir = tmp / name
    agent = run_dir / "agents/w"
    agent.mkdir(parents=True)
    if running:
        (agent / "events.jsonl").write_text(event("tool_execution_end", "a"))
        now = int(time.time())
        (agent / "started.json").write_text(json.dumps(
            {"started_at": now, "deadline": now + 1000, "timeout_s": 1000}))
        (run_dir / ".watch-state").write_text(json.dumps({
            "w#tools": {"started_at": now, "offset": 0, "count": 12},
            "w#reflect": {"n": 3, "base_count": 0, "base_at": now, "pending": True}}))
    else:
        (agent / "meta.json").write_text(json.dumps(
            {"label": "w", "exit_code": 0, "duration_s": 1, "usage": {},
             "thread_id": "t", "result_file": None}))
        (agent / "reflect-1.json").write_text(json.dumps(
            {"verdict": "NO_ISSUE", "reason": "x"}))
        (agent / "reflect-2.error").write_text("invalid result\n")
    return run_dir

def status_running_state():
    result = subprocess.run([root / "scripts/oc_status.sh",
        status_fixture("status-running", True), "--brief"], capture_output=True, text=True)
    assert result.returncode == 0 and "tools=12 reflect=3[pending]" in result.stdout

def status_finished_reports():
    run_dir = status_fixture("status-finished")
    for flag in ("--brief", "--full"):
        result = subprocess.run([root / "scripts/oc_status.sh", run_dir, flag],
                                capture_output=True, text=True)
        assert "reflect: 1 NO_ISSUE, 2 error" in result.stdout

def nested_runs_stay_isolated():
    run_dir = status_fixture("parent-isolation")
    nested = run_dir / "reflect/w-1/agents/reflector"
    nested.mkdir(parents=True)
    (nested / "meta.json").write_text(json.dumps(
        {"exit_code": 0, "worktree_branch": "opencode/child"}))
    wait = subprocess.run([root / "scripts/oc_wait.sh", run_dir, "--timeout", "0"],
                          capture_output=True, text=True)
    assert wait.stdout.strip() == "w OK"
    parent_meta = run_dir / "agents/w/meta.json"
    meta = json.loads(parent_meta.read_text())
    meta.update({"worktree_branch": "opencode/parent", "base_sha": "", "cwd": str(tmp)})
    parent_meta.write_text(json.dumps(meta))
    bindir = tmp / "fake-git"
    bindir.mkdir()
    git = bindir / "git"
    git.write_text("#!/bin/sh\ncase \"$*\" in\n"
        "*'rev-parse --git-dir'*) echo .git;;\n"
        "*'rev-parse --abbrev-ref HEAD'*) echo main;;\n"
        "*'rev-parse HEAD'*) echo abc;;\n"
        "esac\nexit 0\n")
    git.chmod(0o755)
    merge = subprocess.run([root / "scripts/oc_merge.sh", "--run-dir", run_dir,
        "--repo", tmp, "--into", "main", "--dry-run"],
        env=os.environ | {"PATH": f"{bindir}:{os.environ['PATH']}"},
        capture_output=True, text=True)
    assert merge.returncode == 0 and "integrating 1 branch" in merge.stderr

def new_run_prompts_for_maintainer_words():
    base = tmp / "new-runs"
    result = subprocess.run([root / "scripts/oc_new_run.sh", "probe"],
        env=os.environ | {"OPENCODE_RUNS_DIR": str(base)}, capture_output=True, text=True)
    assert result.returncode == 0
    assert "maintainer.md" in (pathlib.Path(result.stdout.strip()) / "PLAN.md").read_text()
phase = sys.argv[2]
if phase == "events":
    run("event parser preserves partial lines and correlates arguments", parser_boundaries)
    run("agent meta counts completed tools", wrapper_counts)
    run("watch persists incremental counts and resets identity", watch_incremental_identity)
elif phase == "triggers":
    run("watch triggers once at one hundred successful tools", reflect_threshold_and_dedup)
    run("watch coalesces triggers and skips the final ten minutes", reflect_single_and_deadline)
    run("watch resets reflection state on worker identity change", reflect_identity_reset)
elif phase == "budget":
    run("max-tools kills a slow eleventh completion without stall", max_tools_slow)
    run("max-tools rejects a fast over-budget result", max_tools_fast)
    run("max-tools accepts exactly ten completions", max_tools_exact)
elif phase == "reflect":
    run("reflect accepts fenced NO_ISSUE", valid_no_issue)
    run("reflect accepts source-bound ROUTE_CORRECTION", valid_route)
    run("reflect accepts CANNOT_JUDGE", valid_cannot_judge)
    run("reflect rejects a missing verdict", lambda: invalid_result("missing", {}))
    run("reflect rejects an absent quote", lambda: invalid_result("badquote",
        {"verdict": "ROUTE_CORRECTION", "reason": "x", "next_step": "y",
         "quotes": [{"source": "maintainer.md", "text": "ABSENT"}]}))
    run("reflect rejects an empty quote", lambda: invalid_result("emptyquote",
        {"verdict": "ROUTE_CORRECTION", "reason": "x", "next_step": "y",
         "quotes": [{"source": "maintainer.md", "text": "   "}]}))
    run("reflect rejects source misuse", lambda: invalid_result("misuse",
        {"verdict": "ROUTE_CORRECTION", "reason": "x", "next_step": "y",
         "quotes": [{"source": "maintainer.md", "text": "SPEC SENTENCE"}]}))
    run("reflect rejects a missing next_step", lambda: invalid_result("next",
        {"verdict": "ROUTE_CORRECTION", "reason": "x",
         "quotes": [{"source": "maintainer.md", "text": "STOP HERE"}]}))
    run("reflect rejects empty output", empty_result)
    run("reflect records a failed reflector without redrive", failed_reflector)
    run("reflect dry-run preserves state and renders bounded sources", dry_run_prompt)
    run("reflect admission refusal preserves pending", admission_preserves_pending)
    run("reflect treats over-budget output as failure", over_budget_is_error)
    run("reflect lock releases and report numbers never overwrite", lock_and_numbering)
    run("reflect completion merges the current tool count", completion_uses_current_count)
    run("old reflection cannot update a new worker identity", old_inquiry_preserves_new_identity)
    run("reflect timeout launches only once", timeout_does_not_redrive)
elif phase == "status":
    run("status renders running reflection state", status_running_state)
    run("status renders finished reflection artifacts in brief and full modes",
        status_finished_reports)
    run("wait and merge ignore nested reflector runs", nested_runs_stay_isolated)
    run("new runs prompt for maintainer words", new_run_prompts_for_maintainer_words)
else:
    raise SystemExit(f"unknown phase {phase}")
if dead:
    raise SystemExit(1)
PY
# Confirm the clean copy is green first. If the baseline were red, none of the breaks below
# would establish anything.
fresh || exit 2
expect 0 "baseline contract" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"
fresh || exit 2
expect 0 "reflection event controls" python3 "$TMP/event-controls.py" "$TMP/w" events
cat "$TMP/out"

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
fresh || exit 2
expect 0 "reflection trigger controls" python3 "$TMP/event-controls.py" "$TMP/w" triggers
cat "$TMP/out"

# The ladder drifts: deep falls from high to medium.
fresh || exit 2
sed -i 's/^| `deep` | `high`/| `deep` | `medium`/' "$TMP/w/SKILL.md"
sed -i 's/| `high` | 1800–3600 |/| `medium` | 1800–3600 |/' "$TMP/w/SKILL.md"
expect 1 "tier maps to the wrong effort" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"
fresh || exit 2
expect 0 "reflection tool-budget controls" python3 "$TMP/event-controls.py" "$TMP/w" budget
cat "$TMP/out"

# A timeout drifts.
fresh || exit 2
sed -i 's/3600–5400/3600–9999/' "$TMP/w/SKILL.md"
expect 1 "timeout drift" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"
fresh || exit 2
expect 0 "reflection inquiry controls" python3 "$TMP/event-controls.py" "$TMP/w" reflect
cat "$TMP/out"

# A whole tier disappears.
fresh || exit 2
sed -i '/^| `frontier` |/d' "$TMP/w/SKILL.md"
expect 1 "a tier is missing" python3 scripts/check-contract.py "$ENGINE" "$TMP/w/SKILL.md"
fresh || exit 2
expect 0 "reflection status controls" python3 "$TMP/event-controls.py" "$TMP/w" status
cat "$TMP/out"

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

fresh || exit 2
printf '\ncase x in\n' >> "$TMP/w/scripts/oc_reflect.sh"
expect 1 "oc_reflect.sh does not parse" sh "$TMP/w/scripts/check-shell-syntax.sh"


if [ "$fail" -ne 0 ]; then
  printf '%d passed, %d dead\n' "$pass" "$fail"
  exit 1
fi
printf '%d controls passed, none dead\n' "$pass"
