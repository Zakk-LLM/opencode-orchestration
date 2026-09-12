#!/usr/bin/env python3
"""Read complete OpenCode tool events without modifying their source."""

import json
from pathlib import Path


def _args_head(value):
    if value is None:
        return ""
    if isinstance(value, str):
        text = value
    else:
        try:
            text = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        except (TypeError, ValueError):
            text = str(value)
    return text.replace("\n", " ")[:80]


def scan_tools(path, offset):
    """Return terminal tool calls after offset and the last complete-line offset."""
    path = Path(path)
    try:
        size = path.stat().st_size
        if offset < 0 or offset > size:
            offset = 0
        with path.open("rb") as stream:
            stream.seek(offset)
            data = stream.read()
    except OSError:
        return [], offset

    end = data.rfind(b"\n")
    if end < 0:
        return [], offset
    complete = data[: end + 1]
    events = []
    for raw in complete.splitlines():
        try:
            event = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            # Malformed lines are not events and cannot contribute to the count.
            continue
        if event.get("type") != "tool_use":
            continue
        part = event.get("part") or {}
        state = part.get("state") or {}
        status = state.get("status")
        if status not in {"completed", "error"}:
            continue
        ok = status == "completed"
        if part.get("tool") == "bash":
            exit_code = (state.get("metadata") or {}).get("exit")
            ok = ok and exit_code in (0, None)
        events.append({
            "name": part.get("tool") or "",
            "args_head": _args_head(state.get("input")),
            "ok": ok,
        })
    return events, offset + len(complete)
