#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.0"
# dependencies = []
# ///

from __future__ import annotations

import hashlib
import shutil
import sys
from pathlib import Path
from typing import Final

from model_visible_contract import Case, load_cases
from model_visible_execution import CaseResult, ExecutionConfig, run_case
from model_visible_json import JsonArray, JsonObject, JsonValue, json_text, record

ROOT: Final = Path(__file__).resolve().parents[4]
SKILL_DIRECTORY: Final = ROOT / ".scratch/agent-process-lifecycle-skill/candidate/agent-process-lifecycle"
EVALS_PATH: Final = SKILL_DIRECTORY / "evals/evals.json"
NAME: Final = "agent-process-lifecycle"
MODEL: Final = "openai/gpt-5.6-sol"
MODULES: Final = tuple(Path(__file__).with_name(name) for name in ("run_candidate_smoke.py", "model_visible_execution.py", "model_visible_contract.py", "model_visible_json.py"))
ARCHIVED_EVIDENCE: Final = (
    ROOT / ".scratch/agent-process-lifecycle-skill/candidate/evidence/routing-smoke-20260729-r7/summary.json",
    ROOT / ".scratch/agent-process-lifecycle-skill/candidate/evidence/windows-helper-acceptance.md",
)


class HarnessError(RuntimeError):
    """Signals a deterministic model-visible harness contract failure."""


def main() -> None:
    output = _output_path()
    cases = load_cases(EVALS_PATH.read_text(encoding="utf-8"), NAME)
    config = ExecutionConfig(SKILL_DIRECTORY, NAME, MODEL, shutil.which("opencode.cmd") or "opencode")
    results = tuple(run_case(case, config) for case in cases)
    _write_json(output / "manifest.json", _manifest(cases))
    (output / "results.ndjson").write_text("".join(f"{json_text(result.evidence())}\n" for result in results), encoding="utf-8")
    _write_json(output / "summary.json", _summary(results))
    if not all(not result.assertions for result in results):
        raise HarnessError("model-visible lifecycle assertions failed")


def _output_path() -> Path:
    if len(sys.argv) != 2:
        raise HarnessError("usage: run_candidate_smoke.py <scratch-evidence-directory>")
    output = (ROOT / sys.argv[1]).resolve()
    scratch = (ROOT / ".scratch/agent-process-lifecycle-skill").resolve()
    if not output.is_relative_to(scratch):
        raise HarnessError("output must be under .scratch/agent-process-lifecycle-skill")
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    return output


def _manifest(cases: tuple[Case, ...]) -> JsonObject:
    hashed = (SKILL_DIRECTORY / "SKILL.md", SKILL_DIRECTORY / "references/windows-self-managed.md", SKILL_DIRECTORY / "references/failure-and-handoff.md", EVALS_PATH, *MODULES, *ARCHIVED_EVIDENCE)
    inputs = JsonObject(tuple((str(path.relative_to(ROOT)).replace("\\", "/"), _lf_normalized_text_hash(path)) for path in hashed))
    return record(
        ("evidence_type", "ticket-16-model-visible"),
        ("model", MODEL),
        ("case_ids", JsonArray(tuple(case.identifier for case in cases))),
        ("permission_policy", record(("*", "deny"), ("read", "allow"), ("skill", "allow"))),
        ("input_hash_mode", "sha256-lf-normalized-text"),
        ("inputs", inputs),
        ("archived_evidence_policy", "Archived routing and Windows runtime evidence were hashed only; neither was rerun or recalculated."),
        ("baseline_run", False),
        ("eval_viewer", False),
    )


def _summary(results: tuple[CaseResult, ...]) -> JsonObject:
    passed = sum(not result.assertions for result in results)
    return record(
        ("evidence_type", "ticket-16-model-visible"),
        ("model", MODEL),
        ("case_count", len(results)),
        ("passed_case_count", passed),
        ("failed_case_count", len(results) - passed),
        ("case_ids", JsonArray(tuple(result.identifier for result in results))),
        ("archived_evidence_rerun", False),
        ("archived_evidence_recalculated", False),
    )


def _write_json(path: Path, value: JsonValue) -> None:
    path.write_text(f"{json_text(value, indent=2)}\n", encoding="utf-8")


def _lf_normalized_text_hash(path: Path) -> str:
    return hashlib.sha256(path.read_text(encoding="utf-8").replace("\r\n", "\n").encode()).hexdigest()


if __name__ == "__main__":
    main()
