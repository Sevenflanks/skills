from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from .evidence import ValidatedEvidence, validate_calibration_evidence
from .evidence_format import EvidenceValidationError, JsonObject, json_array, json_object
from .models import RunPhase, Specification
from .release_gate import CalibrationDecision, CalibrationInput, GateOutcome, select_calibration


CALIBRATION_WORKERS: Final = (1, 2, 4)


@dataclass(frozen=True, slots=True)
class CalibrationAudit:
    decision: CalibrationDecision
    document: JsonObject
    selected: ValidatedEvidence | None


def recompute_calibration(root: Path, benchmark_root: Path, specification: Specification, schema_version: int) -> CalibrationAudit:
    evidence = tuple(_evidence_for(root, benchmark_root, specification, workers) for workers in CALIBRATION_WORKERS)
    reference = evidence[0]
    inputs = tuple(CalibrationInput(item.shape.workers, item.is_complete, _parity(item, reference), item.evidence_root.name) for item in evidence)
    decision = select_calibration(inputs)
    entries = _entries(evidence, inputs)
    selected = next((item for item in evidence if item.shape.workers == decision.selected_workers), None)
    selected_document = next((entry for entry in entries if entry["workers"] == decision.selected_workers), None)
    document = json_object({
        "schema_version": schema_version,
        "stage": "calibration",
        "status": "passed" if decision.outcome == GateOutcome.PASS else "blocked",
        "outcome": decision.outcome,
        "exit_code": decision.exit_code,
        "selection_rule": "highest_complete_parity_workers",
        "entries": json_array(entries),
        "selected": selected_document,
        "reason_codes": json_array(()) if selected_document is not None else json_array(("calibration_no_complete_parity",)),
    })
    return CalibrationAudit(decision, document, selected)


def _evidence_for(root: Path, benchmark_root: Path, specification: Specification, workers: int) -> ValidatedEvidence:
    path = root / f"calibration-w{workers}"
    if not path.is_dir():
        raise EvidenceValidationError("calibration evidence directories must be exactly w1, w2, and w4")
    item = validate_calibration_evidence(path, benchmark_root, specification)
    if item.phase != RunPhase.CALIBRATION or item.shape.workers != workers:
        raise EvidenceValidationError("calibration accepts only matching calibration evidence")
    _validate_candidate_negative_safety(item)
    return item


def _validate_candidate_negative_safety(evidence: ValidatedEvidence) -> None:
    if any(record.variant_id == "candidate" and record.label == "negative" and record.candidate_selected and record.non_skill_tool_uses for record in evidence.records):
        raise EvidenceValidationError("calibration candidate-negative tool isolation is invalid")


def _entries(evidence: tuple[ValidatedEvidence, ...], inputs: tuple[CalibrationInput, ...]) -> list[JsonObject]:
    return [
        json_object({
            "workers": item.shape.workers,
            "complete": item.is_complete,
            "parity": "match" if input_item.has_reference_parity else "mismatch",
            "run_path": item.evidence_root.name,
            "manifest_sha256": _sha256(item.evidence_root / "manifest.json"),
            "reason_codes": json_array(()) if input_item.has_reference_parity else json_array(("calibration_parity_mismatch",)),
        })
        for item, input_item in zip(evidence, inputs, strict=True)
    ]


def _parity(left: ValidatedEvidence, right: ValidatedEvidence) -> bool:
    return left.environment_signature == right.environment_signature and left.execution_parity_signature == right.execution_parity_signature and left.source_signature == right.source_signature


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()
