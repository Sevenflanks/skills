from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .completeness import check_matrix_completeness
from .evidence_format import EvidenceIncompleteError, EvidenceValidationError, JsonValue, document as _document, document_text as _document_text, hash_mapping as _hash_mapping, integer as _integer, mapping as _mapping, number as _number, optional_integer as _optional_integer, phase as _phase, sha256 as _sha256, string as _string, strings as _strings
from .events import classify_ndjson
from .models import AttemptStatus, RunPhase, RunShape, Specification, TrialRecord
from .phase import PhaseShapeError, validate_phase_shape
from .preflight import validate_preflight_evidence
from .reference import ReferenceManifest, manifest_parity, reference_record
from .trial_contract import TrialCommandContext, execution_contract, observed_executable


MANIFEST_SCHEMA_VERSION = 2
MANIFEST_CONTRACT = "routing-release-gate-v1"


@dataclass(frozen=True, slots=True)
class ValidatedEvidence:
    evidence_root: Path
    phase: RunPhase
    shape: RunShape
    records: tuple[TrialRecord, ...]
    environment_signature: str
    execution_signature: str
    execution_parity_signature: str
    source_signature: str
    reference_manifest: ReferenceManifest | None
    is_complete: bool


@dataclass(frozen=True, slots=True)
class _ValidationContext:
    benchmark_root: Path
    specification: Specification
    ancestor_roots: frozenset[Path]

    def with_ancestor(self, root: Path) -> _ValidationContext:
        return _ValidationContext(self.benchmark_root, self.specification, self.ancestor_roots | {root})


def source_hashes_for(benchmark_root: Path, specification: Specification) -> dict[str, str]:
    """Hash every executable benchmark source and its two routing inputs."""
    hashes = {
        str(path.relative_to(benchmark_root)).replace("\\", "/"): _sha256(path)
        for path in sorted(benchmark_root.rglob("*.py"))
    }
    hashes["inputs/trigger-evals.json"] = _sha256(benchmark_root / "trigger-evals.json")
    hashes["inputs/variants.json"] = _sha256(benchmark_root / "variants.json")
    for variant in specification.variants:
        hashes[f"variants/{variant.id}/SKILL.md"] = _sha256((benchmark_root / variant.skill_path).resolve())
    return hashes


def validate_evidence(evidence_root: Path, benchmark_root: Path, specification: Specification) -> ValidatedEvidence:
    return _validate_evidence(evidence_root, _ValidationContext(benchmark_root, specification, frozenset()), require_complete=True)


def validate_calibration_evidence(evidence_root: Path, benchmark_root: Path, specification: Specification) -> ValidatedEvidence:
    """Validate calibration evidence while retaining an incomplete matrix for selection audit."""
    return _validate_evidence(evidence_root, _ValidationContext(benchmark_root, specification, frozenset()), require_complete=False)


def _validate_evidence(evidence_root: Path, context: _ValidationContext, *, require_complete: bool) -> ValidatedEvidence:
    """Validate an evidence directory before it can enter release-gate arithmetic."""
    root = evidence_root.resolve()
    if root in context.ancestor_roots:
        raise EvidenceValidationError("reference manifest cycle is not allowed")
    try:
        manifest = _document(root / "manifest.json")
    except OSError as error:
        raise EvidenceValidationError("manifest cannot be read") from error
    if _integer(manifest.get("schema_version"), "schema_version") != MANIFEST_SCHEMA_VERSION or _string(manifest.get("contract"), "contract") != MANIFEST_CONTRACT:
        raise EvidenceValidationError("manifest schema or contract does not match the release gate")
    phase = _phase(_string(manifest.get("evidence_phase"), "evidence_phase"))
    shape = _shape(manifest, context.specification, phase)
    try:
        validate_phase_shape(shape)
    except PhaseShapeError as error:
        raise EvidenceValidationError(str(error)) from error
    if _hash_mapping(manifest.get("source_hashes"), "source_hashes") != source_hashes_for(context.benchmark_root, context.specification):
        raise EvidenceValidationError("manifest source hashes do not match the executable benchmark")
    _validate_artifacts(root, _hash_mapping(manifest.get("artifact_hashes"), "artifact_hashes"))
    if manifest.get("protocol_abort") is not None:
        raise EvidenceValidationError("preflight protocol abort cannot become release-gate evidence")
    environment = _mapping(manifest.get("observed_environment"), "observed_environment")
    opencode = _mapping(environment.get("opencode"), "observed_environment.opencode")
    if _integer(opencode.get("return_code"), "observed_environment.opencode.return_code") != 0 or not _string(opencode.get("raw_output"), "observed_environment.opencode.raw_output").strip():
        raise EvidenceValidationError("observed OpenCode version must be nonempty and exit zero")
    trial_context = TrialCommandContext(execution_contract(manifest.get("execution_contract")), observed_executable(opencode), root)
    _validate_environment_streams(root, opencode)
    validate_preflight_evidence(root, manifest.get("preflight"), shape, context.specification)
    records = _records(root / "trials.ndjson")
    is_complete = _validate_records(root, records, shape, context.specification, trial_context, require_complete=require_complete)
    parity = manifest_parity(manifest)
    reference = reference_record(manifest, phase, context.benchmark_root)
    if reference is not None:
        referenced = _validate_evidence(reference.manifest_path.parent, context.with_ancestor(root), require_complete=True)
        if referenced.phase != reference.expected_phase:
            raise EvidenceValidationError("referenced evidence phase does not match the reference record")
    return ValidatedEvidence(
        root,
        phase,
        shape,
        records,
        parity.environment_signature,
        parity.execution_signature,
        parity.execution_parity_signature,
        parity.source_signature,
        reference,
        is_complete,
    )


def _shape(manifest: dict[str, JsonValue], specification: Specification, phase: RunPhase) -> RunShape:
    selection = _mapping(manifest.get("selection"), "selection")
    variant_ids = _strings(selection.get("variants"), "selection.variants")
    prompt_ids = _strings(selection.get("prompts"), "selection.prompts")
    if len(set(variant_ids)) != len(variant_ids) or len(set(prompt_ids)) != len(prompt_ids):
        raise EvidenceValidationError("selection contains duplicate variants or prompts")
    variants = tuple(variant for variant in specification.variants if variant.id in variant_ids)
    prompts = tuple(prompt for prompt in specification.prompts if prompt.id in prompt_ids)
    if tuple(variant.id for variant in variants) != variant_ids or tuple(prompt.id for prompt in prompts) != prompt_ids:
        raise EvidenceValidationError("selection contains unknown or unordered variants or prompts")
    return RunShape(phase, variants, prompts, _integer(selection.get("runs_per_query"), "selection.runs_per_query"), _integer(selection.get("workers"), "selection.workers"))


def _validate_artifacts(root: Path, hashes: dict[str, str]) -> None:
    actual = {
        str(path.relative_to(root)).replace("\\", "/"): _sha256(path)
        for path in root.rglob("*")
        if path.is_file() and path.name != "manifest.json"
    }
    if hashes != actual:
        raise EvidenceValidationError("evidence artifact hashes are missing, extra, or mismatched")


def _validate_environment_streams(root: Path, opencode: dict[str, JsonValue]) -> None:
    stdout = _evidence_path(root, _string(opencode.get("stdout_path"), "version.stdout_path"))
    stderr = _evidence_path(root, _string(opencode.get("stderr_path"), "version.stderr_path"))
    if _sha256(stdout) != _string(opencode.get("stdout_sha256"), "version.stdout_sha256") or _sha256(stderr) != _string(opencode.get("stderr_sha256"), "version.stderr_sha256"):
        raise EvidenceValidationError("version raw stream hash does not match manifest")
    if stdout.read_text(encoding="utf-8") + stderr.read_text(encoding="utf-8") != _string(opencode.get("raw_output"), "version.raw_output"):
        raise EvidenceValidationError("version raw output does not match persisted streams")


def _records(path: Path) -> tuple[TrialRecord, ...]:
    if not path.is_file():
        raise EvidenceValidationError("trials.ndjson is missing")
    records: list[TrialRecord] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line:
            raise EvidenceValidationError(f"trials.ndjson line {line_number} is empty")
        records.append(_record(_document_text(line, f"trials.ndjson line {line_number}")))
    return tuple(records)


def _record(value: dict[str, JsonValue]) -> TrialRecord:
    try:
        status = AttemptStatus(_string(value.get("status"), "trial.status"))
    except ValueError as error:
        raise EvidenceValidationError("trial has an unknown status") from error
    triggered = value.get("triggered")
    if not isinstance(triggered, bool) and triggered is not None:
        raise EvidenceValidationError("trial.triggered must be boolean or null")
    candidate_selected = value.get("candidate_selected")
    if not isinstance(candidate_selected, bool):
        raise EvidenceValidationError("trial.candidate_selected must be boolean")
    return TrialRecord(
        _string(value.get("variant_id"), "trial.variant_id"),
        _string(value.get("prompt_id"), "trial.prompt_id"),
        _string(value.get("label"), "trial.label"),
        _integer(value.get("logical_run"), "trial.logical_run"),
        _integer(value.get("attempt"), "trial.attempt"),
        status,
        triggered,
        candidate_selected,
        _strings(value.get("command"), "trial.command"),
        _optional_integer(value.get("return_code"), "trial.return_code"),
        _number(value.get("duration_seconds"), "trial.duration_seconds"),
        _string(value.get("stdout_sha256"), "trial.stdout_sha256"),
        _string(value.get("stderr_sha256"), "trial.stderr_sha256"),
        _string(value.get("stdout_path"), "trial.stdout_path"),
        _string(value.get("stderr_path"), "trial.stderr_path"),
        _strings(value.get("tool_uses"), "trial.tool_uses"),
        _strings(value.get("non_skill_tool_uses"), "trial.non_skill_tool_uses"),
        _string(value.get("fixture_id"), "trial.fixture_id"),
        _string(value.get("fixture_candidate_name"), "trial.fixture_candidate_name"),
    )


def _validate_records(root: Path, records: tuple[TrialRecord, ...], shape: RunShape, specification: Specification, trial_context: TrialCommandContext, *, require_complete: bool) -> bool:
    variants = {variant.id: variant for variant in specification.variants}
    prompts = {prompt.id: prompt for prompt in specification.prompts}
    expected_variant_ids = {variant.id for variant in shape.variants}
    expected_prompt_ids = {prompt.id for prompt in shape.prompts}
    attempt_keys: set[tuple[str, str, int, int]] = set()
    fixture_ids: set[str] = set()
    raw_paths: set[str] = set()
    for record in records:
        key = (record.variant_id, record.prompt_id, record.logical_run, record.attempt)
        if key in attempt_keys or record.attempt < 1:
            raise EvidenceValidationError("trials contain duplicate or unauthorized attempts")
        attempt_keys.add(key)
        if record.variant_id not in expected_variant_ids or record.prompt_id not in expected_prompt_ids or not 1 <= record.logical_run <= shape.runs_per_query:
            raise EvidenceValidationError("trials contain an unauthorized matrix cell")
        if record.label != prompts[record.prompt_id].label:
            raise EvidenceValidationError("trial prompt label does not match the fixed specification")
        if record.fixture_id in fixture_ids or record.stdout_path in raw_paths or record.stderr_path in raw_paths:
            raise EvidenceValidationError("trials reuse a fixture or raw stream path across attempts")
        fixture_ids.add(record.fixture_id)
        raw_paths.update((record.stdout_path, record.stderr_path))
        trial_context.validate(record, prompts[record.prompt_id], variants[record.variant_id])
        _validate_raw_record(root, record, variants[record.variant_id].skill_name)
    completeness = check_matrix_completeness(list(records), shape.variants, shape.prompts, shape.runs_per_query)
    if require_complete and not completeness.is_complete:
        raise EvidenceIncompleteError("trials do not contain exactly one valid result for every matrix cell")
    return completeness.is_complete


def _validate_raw_record(root: Path, record: TrialRecord, candidate_name: str) -> None:
    stdout_path = _evidence_path(root, record.stdout_path)
    stderr_path = _evidence_path(root, record.stderr_path)
    if _sha256(stdout_path) != record.stdout_sha256 or _sha256(stderr_path) != record.stderr_sha256:
        raise EvidenceValidationError("trial raw stream hash does not match its record")
    parsed = classify_ndjson(stdout_path.read_text(encoding="utf-8"), candidate_name)
    if parsed.tool_uses != record.tool_uses or parsed.non_skill_tool_uses != record.non_skill_tool_uses or parsed.candidate_selected != record.candidate_selected:
        raise EvidenceValidationError("trial observation does not match raw stdout")
    if record.is_valid and record.triggered != record.candidate_selected:
        raise EvidenceValidationError("valid trial trigger does not match candidate selection")
    if not record.is_valid and record.triggered is not None:
        raise EvidenceValidationError("invalid trial cannot claim a trigger")
    if record.status == AttemptStatus.INVALID_TIMEOUT:
        return
    if record.return_code is None:
        raise EvidenceValidationError("non-timeout trial is missing its return code")
    reparsed = TrialRecord.from_completed_process(record.variant_id, record.prompt_id, record.label, record.logical_run, record.attempt, record.command, stdout_path.read_text(encoding="utf-8"), stderr_path.read_text(encoding="utf-8"), record.return_code, record.duration_seconds, candidate_name)
    if reparsed.status != record.status or reparsed.triggered != record.triggered or reparsed.candidate_selected != record.candidate_selected:
        raise EvidenceValidationError("trial result does not match reparsed raw stdout")


def _evidence_path(root: Path, relative_path: str) -> Path:
    path = (root / relative_path).resolve()
    if not relative_path.startswith("logs/") or not path.is_relative_to(root) or not path.is_file():
        raise EvidenceValidationError("raw stream path is missing or unauthorized")
    return path
