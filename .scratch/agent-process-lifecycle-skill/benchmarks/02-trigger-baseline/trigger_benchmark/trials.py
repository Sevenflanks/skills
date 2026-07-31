from __future__ import annotations

import hashlib
import json
import random
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, replace
from pathlib import Path

from .fixture import create_fixture
from .models import AttemptStatus, Prompt, RunOptions, TrialRecord, Variant


@dataclass(frozen=True, slots=True)
class TrialPlan:
    options: RunOptions
    variants: tuple[Variant, ...]
    prompts: tuple[Prompt, ...]
    command: str


@dataclass(frozen=True, slots=True)
class TrialCell:
    variant: Variant
    prompt: Prompt
    logical_run: int


@dataclass(frozen=True, slots=True)
class StreamOutput:
    record: TrialRecord
    stdout: str
    stderr: str


def run_trials(plan: TrialPlan) -> list[TrialRecord]:
    """Run all selected cells while retaining every invalid attempt beside its retry."""
    cells = [TrialCell(variant, prompt, logical_run) for variant in plan.variants for prompt in plan.prompts for logical_run in range(1, plan.options.runs_per_query + 1)]
    random.Random(plan.options.seed).shuffle(cells)
    with ThreadPoolExecutor(max_workers=plan.options.workers) as executor:
        futures = [executor.submit(_run_cell, plan, cell) for cell in cells]
    return sorted((record for future in futures for record in future.result()), key=lambda record: (record.variant_id, record.prompt_id, record.logical_run, record.attempt))


def write_records(output_directory: Path, records: list[TrialRecord]) -> None:
    """Write every attempt, not only the valid matrix denominator."""
    with (output_directory / "trials.ndjson").open("w", encoding="utf-8", newline="\n") as handle:
        for record in records:
            handle.write(json.dumps(asdict(record), default=str) + "\n")


def _run_cell(plan: TrialPlan, cell: TrialCell) -> list[TrialRecord]:
    records: list[TrialRecord] = []
    for attempt in range(1, plan.options.retries + 2):
        record = _run_attempt(plan, cell, attempt)
        records.append(record)
        if record.is_valid:
            break
    return records


def _run_attempt(plan: TrialPlan, cell: TrialCell, attempt: int) -> TrialRecord:
    options = plan.options
    command_prefix = (plan.command, "run", "--pure", "--format", "json", "--model", options.model, "--agent", "build")
    with tempfile.TemporaryDirectory(dir=options.output_directory / "fixtures", ignore_cleanup_errors=True) as temporary_directory:
        fixture = create_fixture(Path(temporary_directory), cell.variant)
        trial_command = (*command_prefix, "--dir", str(fixture.project_directory), cell.prompt.body)
        fixture_identity = {"fixture_id": fixture.project_directory.name, "fixture_candidate_name": cell.variant.skill_name}
        started = time.monotonic()
        try:
            completed = subprocess.run(trial_command, capture_output=True, text=True, check=False, timeout=options.timeout_seconds)
        except subprocess.TimeoutExpired as error:
            stdout = _timeout_text(error.stdout)
            stderr = _timeout_text(error.stderr)
            from .events import classify_ndjson

            stream = classify_ndjson(stdout, cell.variant.skill_name)
            record = TrialRecord.invalid(cell.variant.id, cell.prompt.id, cell.prompt.label, cell.logical_run, attempt, AttemptStatus.INVALID_TIMEOUT, candidate_selected=stream.candidate_selected, tool_uses=stream.tool_uses, non_skill_tool_uses=stream.non_skill_tool_uses)
            return _persist_stream(options.output_directory, StreamOutput(replace(record, command=trial_command, duration_seconds=time.monotonic() - started, **fixture_identity), stdout, stderr))
        record = TrialRecord.from_completed_process(cell.variant.id, cell.prompt.id, cell.prompt.label, cell.logical_run, attempt, trial_command, completed.stdout, completed.stderr, completed.returncode, time.monotonic() - started, cell.variant.skill_name)
        return _persist_stream(options.output_directory, StreamOutput(replace(record, **fixture_identity), completed.stdout, completed.stderr))


def _persist_stream(output_directory: Path, stream: StreamOutput) -> TrialRecord:
    record = stream.record
    prefix = f"{record.variant_id}__{record.prompt_id}__run-{record.logical_run}__attempt-{record.attempt}"
    stdout_path = output_directory / "logs" / f"{prefix}.stdout.ndjson"
    stderr_path = output_directory / "logs" / f"{prefix}.stderr.txt"
    stdout_path.write_text(stream.stdout, encoding="utf-8", newline="\n")
    stderr_path.write_text(stream.stderr, encoding="utf-8", newline="\n")
    return replace(record, stdout_path=str(stdout_path.relative_to(output_directory)).replace("\\", "/"), stderr_path=str(stderr_path.relative_to(output_directory)).replace("\\", "/"), stdout_sha256=_sha256(stdout_path), stderr_sha256=_sha256(stderr_path))


def _timeout_text(value: str | bytes | None) -> str:
    match value:
        case str():
            return value
        case bytes():
            return value.decode(errors="replace")
        case None:
            return ""


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()
