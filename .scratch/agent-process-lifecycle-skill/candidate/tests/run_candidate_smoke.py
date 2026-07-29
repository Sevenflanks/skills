#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.0"
# dependencies = []
# ///

# --- How to run ---
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly (no venv, no pip install needed):
#      uv run run_candidate_smoke.py <scratch-evidence-directory>
# 3. Or make executable and run:
#      chmod +x run_candidate_smoke.py && ./run_candidate_smoke.py <scratch-evidence-directory>
# ------------------

from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
CANDIDATE = ROOT / ".scratch/agent-process-lifecycle-skill/candidate/agent-process-lifecycle/SKILL.md"
PROMPTS = ROOT / ".scratch/agent-process-lifecycle-skill/benchmarks/02-trigger-baseline/trigger-evals.json"
NAME = "agent-process-lifecycle"
MODEL = "openai/gpt-5.6-sol"


@dataclass(frozen=True, slots=True)
class RunResult:
    valid: bool
    loaded: bool
    response: str


def main() -> None:
    output = _output_path()
    document = CANDIDATE.read_text(encoding="utf-8")
    description = _frontmatter(document, "description")
    prompts = json.loads(PROMPTS.read_text(encoding="utf-8"))["prompts"]
    manual = [_manual(document, item) for item in _manual_cases()]
    with ThreadPoolExecutor(max_workers=4) as executor:
        routing = list(executor.map(lambda prompt: _routing(description, prompt), prompts))
    summary = {
        "evidence_type": "ticket-10-candidate-smoke",
        "candidate": {"path": str(CANDIDATE.relative_to(ROOT)).replace("\\", "/"), "sha256": _hash(document), "model_invocation": "disabled", "published_inventory": "absent"},
        "manual_checks": manual,
        "routing_fixture": {"purpose": "isolated metadata-routing smoke only; it is not the manually invoked candidate", "candidate_description_sha256": _hash(description), "permissions": {"*": "deny", "skill": "allow"}, "runs_per_prompt": 1, "raw_streams_retained": False, "checks": routing},
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    if not all(item["valid"] and item["candidate_loaded"] and item["required_result_fields_present"] for item in manual):
        raise RuntimeError("manual candidate checks did not prove the required decisions")
    if len(routing) != 16 or not all(item["valid"] for item in routing):
        raise RuntimeError("routing smoke did not produce one valid run for every fixed prompt")


def _output_path() -> Path:
    if len(sys.argv) != 2:
        raise RuntimeError("usage: run_candidate_smoke.py <scratch-evidence-directory>")
    output = (ROOT / sys.argv[1]).resolve()
    scratch = (ROOT / ".scratch/agent-process-lifecycle-skill").resolve()
    if not output.is_relative_to(scratch) or output.exists():
        raise RuntimeError("output must be a new directory under .scratch/agent-process-lifecycle-skill")
    output.mkdir(parents=True)
    return output


def _manual_cases() -> tuple[tuple[str, str, tuple[str, ...]], ...]:
    return (
        ("excluded-synchronous-command", "Explicitly invoke the agent-process-lifecycle skill's Candidate Test Entry. This repository test command waits for exit normally. Return only its required lifecycle decision JSON.", ('"applicable": false', '"lifecycle_fact_bundle_created": false', '"lifecycle_actions": []')),
        ("helper-unavailable-pre-launch-block", "Explicitly invoke the agent-process-lifecycle skill's Candidate Test Entry. On Windows, an Agent-owned local watcher needs a self-managed launch, no managed or external owner is verified, and the production helper is unavailable. Return only its required lifecycle decision JSON.", ('"action": "blocked"', '"stage": "pre-launch"', '"failure_kind": "production-helper-unavailable"', '"launch_performed": false', '"termination_performed": false', '"os_inspection_performed": false', '"lifecycle_shell_calls": []')),
        ("non-windows-unidentified-owner", "Explicitly invoke the agent-process-lifecycle skill's Candidate Test Entry. On non-Windows, an Agent-owned local watcher needs self-managed lifecycle execution and no managed or external owner is identifiable. Return only its required lifecycle decision JSON.", ('"action": "blocked"', '"stage": "pre-launch"', '"platform": "non-Windows"', '"requested_lifecycle_need": "self-managed lifecycle execution"', '"identified_owner": null', '"contract_gap": "No managed or external owner contract is identifiable."', '"launch_performed": false', '"termination_performed": false', '"os_inspection_performed": false', '"lifecycle_shell_calls": []', '"missing_safety_evidence"', '"alternative"', '"next_owner"', '"unresolved_items"')),
        ("non-windows-identified-owner", "Explicitly invoke the agent-process-lifecycle skill's Candidate Test Entry. On non-Windows, an external managed owner with a documented lifecycle contract is identifiable. Return only its required lifecycle decision JSON.", ('"action": "handoff"', '"stage": "pre-launch"', '"platform": "non-Windows"', '"requested_lifecycle_need": "managed lifecycle execution"', '"identified_owner": "managed-or-external"', '"contract_gap": null', '"launch_performed": false', '"termination_performed": false', '"os_inspection_performed": false', '"lifecycle_shell_calls": []', '"missing_safety_evidence"', '"alternative"', '"next_owner"', '"unresolved_items"')),
    )


def _manual(document: str, case: tuple[str, str, tuple[str, ...]]) -> dict[str, str | bool]:
    identifier, prompt, required = case
    result = _with_fixture(document, prompt)
    return {"id": identifier, "valid": result.valid, "candidate_loaded": result.loaded, "response_sha256": _hash(result.response), "required_result_fields_present": all(value in result.response for value in required), "raw_stream_retained": False}


def _routing(description: str, prompt: dict[str, str]) -> dict[str, str | bool | int]:
    fixture = f"---\nname: {NAME}\ndescription: {description}\nlicense: MIT\nmetadata:\n  author: ticket-10-routing-fixture\n  version: 0.0.0\n---\n\n# Isolated Routing Fixture\n\nClassify only. Do not execute commands, inspect the OS, launch, terminate, or run lifecycle shell calls.\n"
    result = _with_fixture(fixture, prompt["body"])
    attempts = 1
    if not result.valid:
        result = _with_fixture(fixture, prompt["body"])
        attempts = 2
    return {"id": prompt["id"], "label": prompt["label"], "valid": result.valid, "triggered": result.loaded, "attempts": attempts, "response_sha256": _hash(result.response), "raw_stream_retained": False}


def _with_fixture(skill: str, prompt: str) -> RunResult:
    with tempfile.TemporaryDirectory(prefix="ticket-10-agent-process-lifecycle-") as temp:
        project = Path(temp)
        skill_path = project / ".opencode/skills" / NAME / "SKILL.md"
        skill_path.parent.mkdir(parents=True)
        skill_path.write_text(skill, encoding="utf-8")
        (project / "opencode.json").write_text('{"permission":{"*":"deny","skill":"allow"}}\n', encoding="utf-8")
        preflight = _command([_opencode(), "debug", "skill", "--pure"], project, 30)
        discovered = [item for item in json.loads(preflight.stdout) if isinstance(item, dict) and item.get("location") == str(skill_path.resolve()) and item.get("name") == NAME]
        if preflight.returncode != 0 or len(discovered) != 1:
            raise RuntimeError("fixture preflight did not discover exactly the candidate skill")
        completed = _command([_opencode(), "run", "--pure", "--format", "json", "--model", MODEL, "--agent", "build", "--dir", str(project), prompt], project, 90)
        events = _events(completed.stdout)
        loaded = any(_loaded(event) for event in events)
        finished = any(_finished(event) for event in events)
        response = "\n".join(_text(event) for event in events if _text(event))
        return RunResult(completed.returncode == 0 and finished, loaded, response)


def _command(arguments: list[str], cwd: Path, timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(arguments, cwd=cwd, capture_output=True, text=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        return subprocess.CompletedProcess(arguments, 124, _timeout_text(error.stdout), _timeout_text(error.stderr))


def _events(stream: str) -> list[dict[str, object]]:
    return [item for line in stream.splitlines() if line.strip() for item in [json.loads(line)] if isinstance(item, dict)]


def _loaded(event: dict[str, object]) -> bool:
    match event:
        case {"type": "tool_use", "part": {"tool": "skill", "state": {"status": "completed", "input": {"name": NAME}}}}:
            return True
        case _:
            return False


def _finished(event: dict[str, object]) -> bool:
    match event:
        case {"type": "step_finish", "part": {"type": "step-finish"}}:
            return True
        case _:
            return False


def _text(event: dict[str, object]) -> str:
    match event:
        case {"type": "text", "part": {"text": str(text)}}:
            return text
        case _:
            return ""


def _timeout_text(value: str | bytes | None) -> str:
    match value:
        case str():
            return value
        case bytes():
            return value.decode(errors="replace")
        case None:
            return ""


def _frontmatter(document: str, key: str) -> str:
    value = re.search(rf"^{key}: (.+)$", document, re.MULTILINE)
    if value is None:
        raise RuntimeError(f"candidate lacks {key} frontmatter")
    return value.group(1)


def _opencode() -> str:
    return shutil.which("opencode.cmd") or "opencode"


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


if __name__ == "__main__":
    main()
