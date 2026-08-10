from __future__ import annotations

import hashlib
import json
import platform
import shutil
import subprocess
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from .aggregate import aggregate_trials, markdown_report
from .completeness import check_matrix_completeness
from .evidence import MANIFEST_CONTRACT, MANIFEST_SCHEMA_VERSION, EvidenceValidationError, source_hashes_for, validate_evidence
from .evidence_format import JsonArray, JsonObject, json_array, json_object
from .models import Prompt, RunOptions, RunPhase, Specification, Variant
from .preflight_execution import PreflightFailure, run_preflight
from .reference import ManifestParity, expected_reference_phase, reference_document, require_exact_parity, require_static_parity
from .release_gate import GateOutcome, evaluate_base
from .trials import TrialPlan, run_trials, write_records


class RunExecutionError(Exception):
    """Raised when executable benchmark evidence cannot meet its contract."""


@dataclass(frozen=True, slots=True)
class VersionCapture:
    command: tuple[str, ...]
    return_code: int
    stdout: str
    stderr: str


@dataclass(frozen=True, slots=True)
class RunExecutionPlan:
    benchmark_root: Path
    options: RunOptions
    specification: Specification
    variants: tuple[Variant, ...]
    prompts: tuple[Prompt, ...]


@dataclass(frozen=True, slots=True)
class RawStreams:
    prefix: str
    stdout: str
    stderr: str
    stdout_suffix: str


@dataclass(frozen=True, slots=True)
class ObservedEnvironment:
    document: JsonObject
    opencode_output: str


@dataclass(frozen=True, slots=True)
class ReferenceValidation:
    document: JsonObject | None
    parity: ManifestParity | None


def execute_run(plan: RunExecutionPlan) -> int:
    """Execute a shape-validated benchmark run and retain all evidence streams."""
    options = plan.options
    if options.output_directory.exists():
        raise RunExecutionError("--output-dir must not already exist")
    static_manifest = _build_static_manifest(plan)
    reference = _validate_reference_parity(plan, static_manifest)
    command = _opencode_command()
    version = _observe_version(command)
    manifest = _build_manifest(static_manifest, _observed_environment(version))
    if reference.parity is not None:
        try:
            require_exact_parity(manifest, reference.parity)
        except EvidenceValidationError as error:
            raise RunExecutionError(str(error)) from error
    _prepare_output_directory(options.output_directory)
    _persist_version(options.output_directory, version)
    manifest["reference_manifest"] = reference.document
    preflight = _run_preflight(options, plan.variants, command)
    match preflight:
        case PreflightFailure(evidence=evidence, reason=reason):
            manifest["preflight"] = evidence
            manifest["protocol_abort"] = json_object({"stage": "preflight", "reason": reason})
            manifest["matrix_completeness"] = _preflight_incomplete(plan)
            (options.output_directory / "incomplete.json").write_text(json.dumps(manifest["matrix_completeness"], indent=2) + "\n", encoding="utf-8")
            _write_final_manifest(options.output_directory, manifest)
            return 2
        case list() as evidence:
            manifest["preflight"] = evidence
    records = run_trials(TrialPlan(options, plan.variants, plan.prompts, command))
    write_records(options.output_directory, records)
    completeness = check_matrix_completeness(records, plan.variants, plan.prompts, options.runs_per_query)
    manifest["matrix_completeness"] = json_object({
        "expected_cells": completeness.expected_cells,
        "missing_cells": json_array(completeness.missing_cells),
        "duplicate_valid_cells": json_array(completeness.duplicate_valid_cells),
    })
    if not completeness.is_complete:
        (options.output_directory / "incomplete.json").write_text(json.dumps(manifest["matrix_completeness"], indent=2) + "\n", encoding="utf-8")
        _write_final_manifest(options.output_directory, manifest)
        return 2
    report = aggregate_trials(records, Specification(plan.prompts, plan.variants))
    (options.output_directory / "aggregate.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (options.output_directory / "aggregate.md").write_text(markdown_report(report), encoding="utf-8")
    _write_final_manifest(options.output_directory, manifest)
    return 0


def _prepare_output_directory(output_directory: Path) -> None:
    output_directory.mkdir(parents=True)
    (output_directory / "logs").mkdir()
    (output_directory / "fixtures").mkdir()


def _observe_version(command: str) -> VersionCapture:
    completed = subprocess.run([command, "--version"], capture_output=True, text=True, check=False, timeout=20)
    raw_output = completed.stdout + completed.stderr
    if completed.returncode != 0 or not raw_output.strip():
        raise RunExecutionError("OpenCode --version must exit zero with nonempty output")
    return VersionCapture((command, "--version"), completed.returncode, completed.stdout, completed.stderr)


def _observed_environment(capture: VersionCapture) -> ObservedEnvironment:
    raw_output = capture.stdout + capture.stderr
    return ObservedEnvironment(
        json_object({
            "opencode": json_object({
                "command": json_array(capture.command),
                "return_code": capture.return_code,
                "raw_output": raw_output,
                "stdout_path": "logs/environment-opencode-version.stdout.txt",
                "stderr_path": "logs/environment-opencode-version.stderr.txt",
                "stdout_sha256": hashlib.sha256(capture.stdout.encode()).hexdigest(),
                "stderr_sha256": hashlib.sha256(capture.stderr.encode()).hexdigest(),
            }),
            "python": platform.python_version(),
            "platform": platform.platform(),
        }),
        raw_output,
    )


def _persist_version(output_directory: Path, capture: VersionCapture) -> None:
    _persist_streams(output_directory, RawStreams("environment-opencode-version", capture.stdout, capture.stderr, ".stdout.txt"))


def _build_static_manifest(plan: RunExecutionPlan) -> JsonObject:
    options = plan.options
    return json_object({
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "contract": MANIFEST_CONTRACT,
        "generated_at_utc": datetime.now(UTC).isoformat(),
        "evidence_phase": options.phase,
        "selection": json_object({"variants": json_array(variant.id for variant in plan.variants), "prompts": json_array(prompt.id for prompt in plan.prompts), "runs_per_query": options.runs_per_query, "workers": options.workers, "timeout_seconds": options.timeout_seconds, "retries": options.retries, "seed": options.seed}),
        "execution_contract": json_object({"model": options.model, "agent": "build", "format": "json", "pure": True, "python_major_minor": f"{platform.python_version_tuple()[0]}.{platform.python_version_tuple()[1]}"}),
        "execution": json_object({"workers": options.workers, "timeout_seconds": options.timeout_seconds, "retries": options.retries, "seed": options.seed, "permission_policy": json_object({"*": "deny", "skill": "allow"})}),
        "source_hashes": json_object(source_hashes_for(plan.benchmark_root, plan.specification)),
        "preflight": json_array(()),
        "reference_manifest": None,
    })


def _build_manifest(static_manifest: JsonObject, observed_environment: ObservedEnvironment) -> JsonObject:
    manifest = json_object(static_manifest)
    manifest["environment_parity"] = json_object({"opencode_output": observed_environment.opencode_output, "python": platform.python_version(), "platform": platform.platform()})
    manifest["observed_environment"] = observed_environment.document
    return manifest


def _validate_reference_parity(plan: RunExecutionPlan, static_manifest: JsonObject) -> ReferenceValidation:
    expected_phase = expected_reference_phase(plan.options.phase)
    reference_manifest = plan.options.reference_manifest
    if expected_phase is None:
        if reference_manifest is not None:
            raise RunExecutionError("this phase must not accept --reference-manifest")
        return ReferenceValidation(None, None)
    if reference_manifest is None:
        raise RunExecutionError("this phase requires --reference-manifest")
    try:
        reference = validate_evidence(reference_manifest.parent, plan.benchmark_root, plan.specification)
        if reference_manifest.resolve() != reference.evidence_root / "manifest.json":
            raise RunExecutionError("reference manifest must name the evidence manifest")
        if reference.phase != expected_phase:
            raise RunExecutionError("reference evidence phase is not authorized for this run")
        reference_parity = ManifestParity(
            reference.environment_signature,
            reference.execution_signature,
            reference.execution_parity_signature,
            reference.source_signature,
        )
        require_static_parity(static_manifest, reference_parity)
    except EvidenceValidationError as error:
        raise RunExecutionError(str(error)) from error
    if plan.options.phase == RunPhase.TARGETED:
        decision = evaluate_base(plan.specification, reference.records)
        requested_prompt = plan.prompts[0].id
        if decision.outcome != GateOutcome.TARGETED_REQUIRED or requested_prompt not in decision.targeted_prompt_ids:
            raise RunExecutionError("targeted prompt is not authorized by the fixed-base decision")
    return ReferenceValidation(json_object(reference_document(reference_manifest, expected_phase, plan.benchmark_root)), reference_parity)


def _run_preflight(options: RunOptions, variants: tuple[Variant, ...], command: str) -> JsonArray | PreflightFailure:
    return run_preflight(options, variants, command)


def _preflight_incomplete(plan: RunExecutionPlan) -> JsonObject:
    completeness = check_matrix_completeness([], plan.variants, plan.prompts, plan.options.runs_per_query)
    return json_object({"expected_cells": completeness.expected_cells, "missing_cells": json_array(completeness.missing_cells), "duplicate_valid_cells": json_array(completeness.duplicate_valid_cells)})


def _persist_streams(output_directory: Path, streams: RawStreams) -> tuple[str, str]:
    stdout_path = output_directory / "logs" / f"{streams.prefix}{streams.stdout_suffix}"
    stderr_path = output_directory / "logs" / f"{streams.prefix}.stderr.txt"
    stdout_path.write_text(streams.stdout, encoding="utf-8", newline="\n")
    stderr_path.write_text(streams.stderr, encoding="utf-8", newline="\n")
    return str(stdout_path.relative_to(output_directory)).replace("\\", "/"), str(stderr_path.relative_to(output_directory)).replace("\\", "/")


def _write_final_manifest(output_directory: Path, manifest: JsonObject) -> None:
    manifest["artifact_hashes"] = json_object({
        str(path.relative_to(output_directory)).replace("\\", "/"): _sha256(path)
        for path in output_directory.rglob("*")
        if path.is_file() and path.name != "manifest.json"
    })
    (output_directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def _opencode_command() -> str:
    return shutil.which("opencode.cmd") or "opencode"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()
