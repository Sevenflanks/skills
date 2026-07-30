#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.0"
# dependencies = []
# ///

from __future__ import annotations

import hashlib
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Final
from uuid import uuid4

from model_visible_contract import Case, load_cases
from model_visible_execution import MANIFEST_PERMISSION_POLICY, CaseResult, ExecutionConfig, run_case
from model_visible_json import JsonArray, JsonObject, JsonValue, json_text, record

ROOT: Final = Path(__file__).resolve().parents[4]
CANDIDATE_DIRECTORY: Final = ROOT / ".scratch/agent-process-lifecycle-skill/candidate"
SKILL_DIRECTORY: Final = CANDIDATE_DIRECTORY / "agent-process-lifecycle"
EVALS_PATH: Final = SKILL_DIRECTORY / "evals/evals.json"
CANONICAL_EVIDENCE_DIRECTORY: Final = (CANDIDATE_DIRECTORY / "evidence/model-visible-ticket-16").resolve()
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
    failed_results = tuple(
        record(("identifier", result.identifier), ("assertions", JsonArray(result.assertions)))
        for result in results
        if result.assertions
    )
    if failed_results:
        raise HarnessError(f"model-visible lifecycle assertions failed: {json_text(JsonArray(failed_results))}")
    staging = Path(tempfile.mkdtemp(prefix=f"{output.name}.staging-", dir=output.parent))
    try:
        _write_json(staging / "manifest.json", _manifest(cases))
        (staging / "results.ndjson").write_text("".join(f"{json_text(result.evidence())}\n" for result in results), encoding="utf-8")
        _write_json(staging / "summary.json", _summary(results))
        _publish(staging, output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def _output_path() -> Path:
    if len(sys.argv) != 2:
        raise HarnessError("usage: run_candidate_smoke.py <scratch-evidence-directory>")
    output = (ROOT / sys.argv[1]).resolve()
    if output != CANONICAL_EVIDENCE_DIRECTORY:
        raise HarnessError("output must be candidate/evidence/model-visible-ticket-16")
    return output


def _publish(staging: Path, output: Path) -> None:
    rollback = output.with_name(f"{output.name}.rollback-{uuid4().hex}")
    canonical_was_moved = False
    try:
        if output.exists():
            _replace(output, rollback)
            canonical_was_moved = True
        _replace(staging, output)
    except OSError:
        if canonical_was_moved:
            _replace(rollback, output)
        raise
    finally:
        if rollback.exists() and output.exists():
            shutil.rmtree(rollback)


def _replace(source: Path, destination: Path) -> None:
    source.replace(destination)


def _manifest(cases: tuple[Case, ...]) -> JsonObject:
    hashed = (SKILL_DIRECTORY / "SKILL.md", SKILL_DIRECTORY / "references/windows-self-managed.md", SKILL_DIRECTORY / "references/failure-and-handoff.md", EVALS_PATH, *MODULES, *ARCHIVED_EVIDENCE)
    inputs = JsonObject(tuple((str(path.relative_to(ROOT)).replace("\\", "/"), _lf_normalized_text_hash(path)) for path in hashed))
    return record(
        ("evidence_type", "ticket-16-model-visible"),
        ("model", MODEL),
        ("case_ids", JsonArray(tuple(case.identifier for case in cases))),
        ("permission_policy", MANIFEST_PERMISSION_POLICY),
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
