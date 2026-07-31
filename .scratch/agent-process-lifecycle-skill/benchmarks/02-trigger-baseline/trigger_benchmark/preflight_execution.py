from __future__ import annotations

import tempfile
from dataclasses import dataclass, replace
from pathlib import Path

from .evidence_format import JsonArray, JsonObject, json_array, json_object
from .fixture import create_fixture
from .models import RunOptions, Variant
from .preflight import PreflightCapture, PreflightEvidence, verify_candidate_discovery


@dataclass(frozen=True, slots=True)
class PreflightFailure:
    evidence: JsonArray
    reason: str


def run_preflight(options: RunOptions, variants: tuple[Variant, ...], command: str) -> JsonArray | PreflightFailure:
    """Retain every preflight stream and retry one confirmed fixture omission once."""
    evidence: JsonArray = []
    for variant in variants:
        with tempfile.TemporaryDirectory(dir=options.output_directory / "fixtures", ignore_cleanup_errors=True) as temporary_directory:
            fixture = create_fixture(Path(temporary_directory), variant)
            first = verify_candidate_discovery(command, fixture, variant)
            first_item = _persist_capture(options.output_directory, variant, first, 1)
            if first.failure is None:
                evidence.append(_preflight_document(first_item, (first_item,), 1))
                continue
            if not first.failure.is_retryable_omission:
                evidence.append(_failed_preflight_document((first_item,)))
                return PreflightFailure(evidence, str(first.failure))
            second = verify_candidate_discovery(command, fixture, variant)
            second_item = _persist_capture(options.output_directory, variant, second, 2)
            attempts = first_item, second_item
            if second.failure is not None:
                evidence.append(_failed_preflight_document(attempts))
                return PreflightFailure(evidence, str(second.failure))
            evidence.append(_preflight_document(second_item, attempts, 2))
    return evidence


def _persist_capture(output_directory: Path, variant: Variant, capture: PreflightCapture, attempt: int) -> PreflightCapture:
    prefix = f"preflight-{variant.id}-{capture.evidence.fixture_id}-attempt-{attempt}"
    stdout_path = output_directory / "logs" / f"{prefix}.stdout.txt"
    stderr_path = output_directory / "logs" / f"{prefix}.stderr.txt"
    stdout_path.write_text(capture.stdout, encoding="utf-8")
    stderr_path.write_text(capture.stderr, encoding="utf-8")
    evidence = replace(capture.evidence, stdout_path=str(stdout_path.relative_to(output_directory)).replace("\\", "/"), stderr_path=str(stderr_path.relative_to(output_directory)).replace("\\", "/"))
    return replace(capture, evidence=evidence)


def _preflight_document(success: PreflightCapture, attempts: tuple[PreflightCapture, ...], successful_attempt: int) -> JsonObject:
    document = _evidence_document(success.evidence)
    document["successful_attempt"] = successful_attempt
    document["attempts"] = json_array(_attempt_document(capture, attempt) for attempt, capture in enumerate(attempts, start=1))
    return document


def _failed_preflight_document(attempts: tuple[PreflightCapture, ...]) -> JsonObject:
    document = _evidence_document(attempts[-1].evidence)
    document["successful_attempt"] = None
    document["attempts"] = json_array(_attempt_document(capture, attempt) for attempt, capture in enumerate(attempts, start=1))
    return document


def _attempt_document(capture: PreflightCapture, attempt: int) -> JsonObject:
    document = _evidence_document(capture.evidence)
    document["attempt"] = attempt
    document["outcome"] = "success" if capture.failure is None else capture.failure.outcome
    return document


def _evidence_document(evidence: PreflightEvidence) -> JsonObject:
    return json_object({"variant_id": evidence.variant_id, "fixture_id": evidence.fixture_id, "command": json_array(evidence.command), "return_code": evidence.return_code, "stdout_sha256": evidence.stdout_sha256, "stderr_sha256": evidence.stderr_sha256, "fixture_candidate_count": evidence.fixture_candidate_count, "candidate_name": evidence.candidate_name, "candidate_location": evidence.candidate_location, "stdout_path": evidence.stdout_path, "stderr_path": evidence.stderr_path})
