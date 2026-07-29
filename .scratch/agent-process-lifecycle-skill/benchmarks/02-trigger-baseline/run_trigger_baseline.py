#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.0"
# dependencies = []
# ///

# Run with: py -3.12 run_trigger_baseline.py --output-dir results/baseline-001

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import random
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, replace
from datetime import UTC, datetime
from pathlib import Path

from trigger_benchmark.aggregate import aggregate_trials, markdown_report
from trigger_benchmark.completeness import check_matrix_completeness
from trigger_benchmark.fixture import create_fixture
from trigger_benchmark.models import AttemptStatus, Prompt, Specification, TrialRecord, Variant
from trigger_benchmark.preflight import verify_candidate_discovery
from trigger_benchmark.spec import load_specification


BENCHMARK_ROOT = Path(__file__).resolve().parent


@dataclass(frozen=True, slots=True)
class RunOptions:
    runs_per_query: int
    workers: int
    timeout_seconds: float
    retries: int
    seed: int
    output_directory: Path
    model: str
    variant_ids: tuple[str, ...]
    prompt_ids: tuple[str, ...]


def main() -> int:
    """Run selected cells, retaining every attempted JSONL stream for audit."""
    options = _parse_options()
    specification = load_specification(BENCHMARK_ROOT)
    selected_variants = _select_variants(specification, options.variant_ids)
    selected_prompts = _select_prompts(specification, options.prompt_ids)
    _prepare_output_directory(options.output_directory)
    manifest = _build_manifest(options, specification, selected_variants, selected_prompts)
    manifest["preflight"] = _run_preflight(options, selected_variants)
    _write_manifest(options.output_directory, manifest)
    records = _run_trials(options, selected_variants, selected_prompts)
    _write_records(options.output_directory, records)
    completeness = check_matrix_completeness(records, selected_variants, selected_prompts, options.runs_per_query)
    manifest["matrix_completeness"] = asdict(completeness)
    if not completeness.is_complete:
        incomplete_path = options.output_directory / "incomplete.json"
        incomplete_path.write_text(json.dumps(asdict(completeness), indent=2) + "\n", encoding="utf-8")
        _add_artifact_hashes(manifest, options.output_directory, ("trials.ndjson", "incomplete.json"))
        _write_manifest(options.output_directory, manifest)
        return 2
    report = aggregate_trials(records, Specification(selected_prompts, selected_variants, specification.current_metadata, specification.published_skill_path))
    (options.output_directory / "aggregate.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (options.output_directory / "aggregate.md").write_text(markdown_report(report), encoding="utf-8")
    _add_artifact_hashes(manifest, options.output_directory, ("trials.ndjson", "aggregate.json", "aggregate.md"))
    _write_manifest(options.output_directory, manifest)
    return 0


def _parse_options() -> RunOptions:
    parser = argparse.ArgumentParser(description="Run the scratch-only OpenCode trigger baseline.")
    parser.add_argument("--runs-per-query", type=int, default=3)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--timeout-seconds", type=float, default=90.0)
    parser.add_argument("--retries", type=int, default=1)
    parser.add_argument("--seed", type=int, default=20260728)
    parser.add_argument("--output-dir", default=f"results/run-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}")
    parser.add_argument("--model", default="openai/gpt-5.6-sol")
    parser.add_argument("--variant", action="append", default=[])
    parser.add_argument("--prompt", action="append", default=[])
    arguments = parser.parse_args()
    output_directory = Path(arguments.output_dir)
    resolved_output = output_directory.resolve() if output_directory.is_absolute() else (BENCHMARK_ROOT / output_directory).resolve()
    if not resolved_output.is_relative_to(BENCHMARK_ROOT):
        raise ValueError("--output-dir must remain under the benchmark scratch directory")
    if arguments.runs_per_query < 1 or arguments.workers < 1 or arguments.timeout_seconds <= 0 or arguments.retries < 0:
        raise ValueError("runs, workers, timeout, and retries must be positive within their stated bounds")
    return RunOptions(arguments.runs_per_query, arguments.workers, arguments.timeout_seconds, arguments.retries, arguments.seed, resolved_output, arguments.model, tuple(arguments.variant), tuple(arguments.prompt))


def _select_variants(specification: Specification, selected_ids: tuple[str, ...]) -> tuple[Variant, ...]:
    selected = tuple(variant for variant in specification.variants if not selected_ids or variant.id in selected_ids)
    if not selected:
        raise ValueError("no requested variants exist")
    return selected


def _select_prompts(specification: Specification, selected_ids: tuple[str, ...]) -> tuple[Prompt, ...]:
    selected = tuple(prompt for prompt in specification.prompts if not selected_ids or prompt.id in selected_ids)
    if not selected:
        raise ValueError("no requested prompts exist")
    return selected


def _prepare_output_directory(output_directory: Path) -> None:
    if output_directory.exists():
        raise ValueError("--output-dir must not already exist")
    output_directory.mkdir(parents=True)
    (output_directory / "logs").mkdir()
    (output_directory / "fixtures").mkdir()


def _build_manifest(options: RunOptions, specification: Specification, variants: tuple[Variant, ...], prompts: tuple[Prompt, ...]) -> dict[str, object]:
    source_files = sorted(BENCHMARK_ROOT.rglob("*.py"))
    source_hashes = {str(path.relative_to(BENCHMARK_ROOT)).replace("\\", "/"): _sha256(path) for path in source_files}
    source_hashes["inputs/trigger-evals.json"] = _sha256(BENCHMARK_ROOT / "trigger-evals.json")
    source_hashes["inputs/variants.json"] = _sha256(BENCHMARK_ROOT / "variants.json")
    source_hashes["published/skills/playwright-server-lifecycle/SKILL.md"] = _sha256((BENCHMARK_ROOT / specification.published_skill_path).resolve())
    return {
        "generated_at_utc": datetime.now(UTC).isoformat(),
        "requirements": {"opencode": "1.18.5", "python": "3.12.0", "model": options.model},
        "observed_environment": {"opencode": _opencode_version(), "python": platform.python_version(), "platform": platform.platform()},
        "selection": {"variants": [variant.id for variant in variants], "prompts": [prompt.id for prompt in prompts], "runs_per_query": options.runs_per_query, "workers": options.workers, "timeout_seconds": options.timeout_seconds, "retries": options.retries, "seed": options.seed},
        "source_hashes": source_hashes,
        "fixture_permission_policy": {"*": "deny", "skill": "allow"},
    }


def _write_manifest(output_directory: Path, manifest: dict[str, object]) -> None:
    (output_directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def _run_preflight(options: RunOptions, variants: tuple[Variant, ...]) -> list[dict[str, object]]:
    evidence: list[dict[str, object]] = []
    for variant in variants:
        with tempfile.TemporaryDirectory(dir=options.output_directory / "fixtures", ignore_cleanup_errors=True) as temporary_directory:
            fixture = create_fixture(Path(temporary_directory), variant)
            evidence.append(asdict(verify_candidate_discovery(_opencode_command(), fixture, variant)))
    return evidence


def _add_artifact_hashes(manifest: dict[str, object], output_directory: Path, artifacts: tuple[str, ...]) -> None:
    manifest["artifact_hashes"] = {artifact: _sha256(output_directory / artifact) for artifact in artifacts}


def _opencode_version() -> str:
    completed = subprocess.run([_opencode_command(), "--version"], capture_output=True, text=True, check=False, timeout=20)
    output = (completed.stdout or completed.stderr).strip()
    if completed.returncode != 0 or "1.18.5" not in output:
        raise RuntimeError(f"expected OpenCode 1.18.5, observed: {output}")
    return output


def _opencode_command() -> str:
    return shutil.which("opencode.cmd") or "opencode"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _run_trials(options: RunOptions, variants: tuple[Variant, ...], prompts: tuple[Prompt, ...]) -> list[TrialRecord]:
    cells = [(variant, prompt, logical_run) for variant in variants for prompt in prompts for logical_run in range(1, options.runs_per_query + 1)]
    random.Random(options.seed).shuffle(cells)
    with ThreadPoolExecutor(max_workers=options.workers) as executor:
        futures = [executor.submit(_run_cell, options, variant, prompt, logical_run) for variant, prompt, logical_run in cells]
    return sorted((record for future in futures for record in future.result()), key=lambda record: (record.variant_id, record.prompt_id, record.logical_run, record.attempt))


def _run_cell(options: RunOptions, variant: Variant, prompt: Prompt, logical_run: int) -> list[TrialRecord]:
    records: list[TrialRecord] = []
    for attempt in range(1, options.retries + 2):
        record = _run_attempt(options, variant, prompt, logical_run, attempt)
        records.append(record)
        if record.is_valid:
            break
    return records


def _run_attempt(options: RunOptions, variant: Variant, prompt: Prompt, logical_run: int, attempt: int) -> TrialRecord:
    fixture_parent = options.output_directory / "fixtures"
    command_prefix = (_opencode_command(), "run", "--pure", "--format", "json", "--model", options.model, "--agent", "build")
    with tempfile.TemporaryDirectory(dir=fixture_parent, ignore_cleanup_errors=True) as temporary_directory:
        fixture = create_fixture(Path(temporary_directory), variant)
        command = (*command_prefix, "--dir", str(fixture.project_directory), prompt.body)
        started = time.monotonic()
        try:
            completed = subprocess.run(command, capture_output=True, text=True, check=False, timeout=options.timeout_seconds)
        except subprocess.TimeoutExpired as error:
            stdout = _timeout_text(error.stdout)
            stderr = _timeout_text(error.stderr)
            record = TrialRecord.invalid(variant.id, prompt.id, prompt.label, logical_run, attempt, AttemptStatus.INVALID_TIMEOUT)
            return _persist_stream(options.output_directory, replace(record, command=command, duration_seconds=time.monotonic() - started), stdout, stderr)
        record = TrialRecord.from_completed_process(variant.id, prompt.id, prompt.label, logical_run, attempt, command, completed.stdout, completed.stderr, completed.returncode, time.monotonic() - started, variant.skill_name)
        return _persist_stream(options.output_directory, record, completed.stdout, completed.stderr)


def _persist_stream(output_directory: Path, record: TrialRecord, stdout: str, stderr: str) -> TrialRecord:
    prefix = f"{record.variant_id}__{record.prompt_id}__run-{record.logical_run}__attempt-{record.attempt}"
    stdout_path = output_directory / "logs" / f"{prefix}.stdout.ndjson"
    stderr_path = output_directory / "logs" / f"{prefix}.stderr.log"
    stdout_path.write_text(stdout, encoding="utf-8")
    stderr_path.write_text(stderr, encoding="utf-8")
    return replace(record, stdout_path=str(stdout_path.relative_to(output_directory)), stderr_path=str(stderr_path.relative_to(output_directory)), stdout_sha256=_sha256(stdout_path), stderr_sha256=_sha256(stderr_path))


def _timeout_text(value: str | bytes | None) -> str:
    match value:
        case str():
            return value
        case bytes():
            return value.decode(errors="replace")
        case None:
            return ""


def _write_records(output_directory: Path, records: list[TrialRecord]) -> None:
    with (output_directory / "trials.ndjson").open("w", encoding="utf-8", newline="\n") as handle:
        for record in records:
            handle.write(json.dumps(asdict(record), default=str) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
