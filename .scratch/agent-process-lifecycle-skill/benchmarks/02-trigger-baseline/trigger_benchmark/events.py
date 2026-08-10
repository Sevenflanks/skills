from __future__ import annotations

import json

from .models import AttemptStatus, StreamResult


def classify_ndjson(stream: str, candidate_name: str) -> StreamResult:
    """Classify JSONL only when OpenCode emits a terminal step-finish event."""
    saw_terminal = False
    selected_candidate = False
    tool_uses: list[str] = []
    non_skill_tool_uses: list[str] = []
    lines = [line for line in stream.splitlines() if line.strip()]
    if not lines:
        return StreamResult(False, False, AttemptStatus.INVALID_MISSING_COMPLETION, (), ())
    for line in lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            return StreamResult(False, selected_candidate, AttemptStatus.INVALID_MALFORMED_STREAM, tuple(tool_uses), tuple(non_skill_tool_uses))
        match event:
            case {"type": "tool_use", "part": {"type": "tool", "tool": "skill", "state": {"status": "completed", "input": {"name": candidate}}}} if candidate == candidate_name:
                selected_candidate = True
                tool_uses.append("skill")
            case {"type": "tool_use", "part": {"tool": tool}} if isinstance(tool, str):
                tool_uses.append(tool)
                if tool != "skill":
                    non_skill_tool_uses.append(tool)
            case {"type": "step_finish", "part": {"type": "step-finish"}}:
                saw_terminal = True
            case _:
                continue
    if not saw_terminal:
        return StreamResult(False, selected_candidate, AttemptStatus.INVALID_MISSING_COMPLETION, tuple(tool_uses), tuple(non_skill_tool_uses))
    return StreamResult(True, selected_candidate, None, tuple(tool_uses), tuple(non_skill_tool_uses))
