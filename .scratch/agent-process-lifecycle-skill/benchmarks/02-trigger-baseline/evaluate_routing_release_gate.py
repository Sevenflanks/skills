#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.0"
# dependencies = []
# ///

from __future__ import annotations

import argparse
import hashlib
import json
from collections.abc import Sequence
from pathlib import Path
from typing import TypedDict

from trigger_benchmark.calibration import recompute_calibration
from trigger_benchmark.evidence import EvidenceValidationError, ValidatedEvidence, validate_evidence
from trigger_benchmark.evidence_format import document as _document, hash_mapping as _hash_mapping
from trigger_benchmark.models import RunPhase, Specification, TrialRecord
from trigger_benchmark.release_gate import GateDecision, GateOutcome, evaluate_base, evaluate_final
from trigger_benchmark.spec import load_specification

BENCHMARK_ROOT = Path(__file__).resolve().parent
SCHEMA_VERSION = 1
ALLOWED_ROOT_NAMES = frozenset({"calibration-w1", "calibration-w2", "calibration-w4", "worker-calibration.json", "base", "targeted", "base-decision", "final-decision"})
DECISION_ARTIFACT_NAMES = frozenset({"decision.json", "report.md"})


class EvaluationError(Exception):
    """Raised when gate evidence cannot establish an authorized decision."""


class Metric(TypedDict):
    triggered: int
    valid: int
    invalid_attempts: int


def main(arguments: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Evaluate deterministic routing release-gate evidence.")
    commands = parser.add_subparsers(dest="command", required=True)
    calibration = commands.add_parser("calibrate")
    calibration.add_argument("--gate-root", required=True)
    evaluation = commands.add_parser("evaluate")
    evaluation.add_argument("--gate-root", required=True)
    evaluation.add_argument("--stage", choices=("base", "final"), required=True)
    parsed = parser.parse_args(arguments)
    stage = "calibration" if parsed.command == "calibrate" else parsed.stage
    root: Path | None = None
    try:
        root = _gate_root(parsed.gate_root)
        _validate_root_names(root)
        return _calibrate(root) if parsed.command == "calibrate" else _evaluate(root, parsed.stage)
    except (EvidenceValidationError, EvaluationError, OSError, json.JSONDecodeError) as error:
        if root is not None:
            try:
                _write_invalid(root, stage, str(error))
            except OSError:
                pass
        return 2


def _gate_root(value: str) -> Path:
    root = Path(value).resolve() if Path(value).is_absolute() else (BENCHMARK_ROOT / value).resolve()
    if not root.is_relative_to(BENCHMARK_ROOT):
        raise EvaluationError("gate root must remain under the benchmark root")
    return root


def _validate_root_names(root: Path) -> None:
    if root.exists() and any(path.name not in ALLOWED_ROOT_NAMES for path in root.iterdir()):
        raise EvaluationError("gate root contains unauthorized evidence")


def _calibrate(root: Path) -> int:
    specification = load_specification(BENCHMARK_ROOT)
    audit = recompute_calibration(root, BENCHMARK_ROOT, specification, SCHEMA_VERSION)
    root.mkdir(parents=True, exist_ok=True)
    _write_json(root / "worker-calibration.json", audit.document)
    return audit.decision.exit_code


def _evaluate(root: Path, stage: str) -> int:
    specification = load_specification(BENCHMARK_ROOT)
    calibration = _selected_calibration(root, specification)
    base = validate_evidence(root / "base", BENCHMARK_ROOT, specification)
    _validate_parity(base, calibration, RunPhase.FIXED_BASE)
    base_decision = evaluate_base(specification, base.records)
    if stage == "base":
        _write_gate(root, "base", base_decision, base, ())
        return base_decision.exit_code
    _validate_base_decision(root, base_decision, base)
    if base_decision.outcome != GateOutcome.TARGETED_REQUIRED:
        if (root / "targeted").exists():
            raise EvaluationError("targeted evidence is unauthorized when base does not require it")
        _write_gate(root, "final", base_decision, base, ())
        return base_decision.exit_code
    targeted_root = root / "targeted"
    if not targeted_root.is_dir() or any(not path.is_dir() for path in targeted_root.iterdir()):
        raise EvaluationError("targeted evidence must be directories only")
    targeted = tuple(validate_evidence(path, BENCHMARK_ROOT, specification) for path in sorted(targeted_root.iterdir()))
    if any(item.evidence_root.name != item.shape.prompts[0].id for item in targeted):
        raise EvaluationError("targeted evidence directory must match its manifest prompt")
    prompt_ids = tuple(item.shape.prompts[0].id for item in targeted)
    if set(prompt_ids) != set(base_decision.targeted_prompt_ids) or len(set(prompt_ids)) != len(prompt_ids):
        raise EvaluationError("targeted evidence must exactly match authorized base prompts")
    for item in targeted:
        _validate_parity(item, base, RunPhase.TARGETED)
    decision = evaluate_final(specification, base.records, tuple(record for item in targeted for record in item.records))
    _write_gate(root, "final", decision, base, targeted)
    return decision.exit_code


def _selected_calibration(root: Path, specification: Specification) -> ValidatedEvidence:
    document = _document(root / "worker-calibration.json")
    audit = recompute_calibration(root, BENCHMARK_ROOT, specification, SCHEMA_VERSION)
    if document != audit.document or audit.decision.outcome != GateOutcome.PASS or audit.selected is None:
        raise EvaluationError("a passing calibration artifact is required")
    return audit.selected


def _validate_parity(evidence: ValidatedEvidence, reference: ValidatedEvidence, phase: RunPhase) -> None:
    if evidence.phase != phase or evidence.shape.workers != reference.shape.workers or not _parity(evidence, reference):
        raise EvaluationError("evidence phase, workers, or parity differs")
    manifest = evidence.reference_manifest
    if manifest is None or manifest.manifest_path != reference.evidence_root / "manifest.json" or manifest.sha256 != _sha256(manifest.manifest_path):
        raise EvaluationError("evidence reference does not match the selected manifest")


def _write_gate(root: Path, stage: str, decision: GateDecision, base: ValidatedEvidence, targeted: tuple[ValidatedEvidence, ...]) -> None:
    document = _gate_document(stage, decision, base, targeted)
    directory = _decision_directory(root, stage)
    _write_json(directory / "decision.json", document)
    (directory / "report.md").write_text(_report(document), encoding="utf-8")
    _assert_decision_artifacts(directory)


def _decision_directory(root: Path, stage: str) -> Path:
    directory = root / f"{stage}-decision"
    if directory.exists():
        if not directory.is_dir() or any(path.name not in DECISION_ARTIFACT_NAMES for path in directory.iterdir()):
            raise EvaluationError("decision directory contains unauthorized artifacts")
    else:
        directory.mkdir(parents=True)
    return directory


def _assert_decision_artifacts(directory: Path) -> None:
    if not directory.is_dir() or frozenset(path.name for path in directory.iterdir()) != DECISION_ARTIFACT_NAMES or any(not (directory / name).is_file() for name in DECISION_ARTIFACT_NAMES):
        raise EvaluationError("decision directory artifacts are incomplete or unauthorized")


def _validate_base_decision(root: Path, decision: GateDecision, base: ValidatedEvidence) -> None:
    directory = root / "base-decision"
    expected = _gate_document("base", decision, base, ())
    if not directory.is_dir() or frozenset(path.name for path in directory.iterdir()) != DECISION_ARTIFACT_NAMES or _document(directory / "decision.json") != expected or (directory / "report.md").read_text(encoding="utf-8") != _report(expected):
        raise EvaluationError("base decision artifacts do not match the recomputed base decision")


def _gate_document(stage: str, decision: GateDecision, base: ValidatedEvidence, targeted: tuple[ValidatedEvidence, ...]) -> dict[str, object]:
    aggregate = base.evidence_root / "aggregate.json"
    if not aggregate.is_file():
        raise EvaluationError("fixed-base aggregate.json is required")
    base_manifest = _document(base.evidence_root / "manifest.json")
    source_hashes = _hash_mapping(base_manifest.get("source_hashes"), "base source_hashes")
    return {"schema_version": SCHEMA_VERSION, "stage": stage, "status": _status(decision), "outcome": decision.outcome, "exit_code": decision.exit_code, "reason_codes": _reason_codes(decision), "reasons": list(decision.reasons), "fixed_base_counts": _counts(base.records), "total_invalid_attempts": sum(not record.is_valid for record in base.records), "base_aggregate": {"path": "base/aggregate.json", "sha256": _sha256(aggregate)}, "required_targeted_prompt_ids": list(decision.targeted_prompt_ids), "targeted": _targeted_counts(targeted), "parity_status": "matched", "safety_status": "blocked" if any("non-skill" in reason for reason in decision.reasons) else "passed", "source_hashes": source_hashes, "artifact_hashes": {"base/manifest.json": _sha256(base.evidence_root / "manifest.json"), "base/aggregate.json": _sha256(aggregate), **{f"targeted/{item.evidence_root.name}/manifest.json": _sha256(item.evidence_root / "manifest.json") for item in targeted}}}


def _report(document: dict[str, object]) -> str:
    return "\n".join(["# Routing Release Gate", "", *[f"- {key}: `{json.dumps(value, sort_keys=True)}`" for key, value in document.items()]]) + "\n"


def _counts(records: tuple[TrialRecord, ...]) -> dict[str, dict[str, Metric]]:
    return {variant: {label: {"triggered": sum(record.is_valid and record.triggered is True and record.variant_id == variant and record.label == label for record in records), "valid": sum(record.is_valid and record.variant_id == variant and record.label == label for record in records), "invalid_attempts": sum(not record.is_valid and record.variant_id == variant and record.label == label for record in records)} for label in ("positive", "negative")} for variant in ("current", "candidate")}


def _targeted_counts(items: tuple[ValidatedEvidence, ...]) -> dict[str, dict[str, Metric]]:
    return {item.shape.prompts[0].id: _counts(item.records)["candidate"] for item in items}


def _status(decision: GateDecision) -> str:
    return {GateOutcome.PASS: "passed", GateOutcome.BLOCK: "blocked", GateOutcome.TARGETED_REQUIRED: "targeted_required"}[decision.outcome]


def _reason_codes(decision: GateDecision) -> list[str]:
    if decision.outcome == GateOutcome.TARGETED_REQUIRED:
        return ["targeted_evidence_required"]
    return ["gate_blocked"] if decision.outcome == GateOutcome.BLOCK else []


def _parity(left: ValidatedEvidence, right: ValidatedEvidence) -> bool:
    return left.environment_signature == right.environment_signature and left.execution_parity_signature == right.execution_parity_signature and left.source_signature == right.source_signature


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def _write_invalid(root: Path, stage: str, reason: str) -> None:
    invalid_reason = "calibration evidence is invalid" if stage == "calibration" else reason
    document = {"schema_version": SCHEMA_VERSION, "stage": stage, "status": "invalid_evidence", "outcome": "invalid_evidence", "exit_code": 2, "reason_codes": ["invalid_evidence"], "reasons": [invalid_reason]}
    root.mkdir(parents=True, exist_ok=True)
    if stage == "calibration":
        _write_json(root / "worker-calibration.json", document)
        return
    directory = root / f"{stage}-decision"
    if directory.exists() and (not directory.is_dir() or any(path.name not in DECISION_ARTIFACT_NAMES for path in directory.iterdir())):
        return
    directory.mkdir(exist_ok=True)
    _write_json(directory / "decision.json", document)
    (directory / "report.md").write_text("# Routing Release Gate\n\n- status: `invalid_evidence`\n", encoding="utf-8")
    _assert_decision_artifacts(directory)


if __name__ == "__main__":
    raise SystemExit(main())
