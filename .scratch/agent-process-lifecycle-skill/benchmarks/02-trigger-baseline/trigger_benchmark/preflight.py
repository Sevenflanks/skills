from __future__ import annotations

import hashlib
import json
import subprocess
from dataclasses import dataclass, replace
from pathlib import Path
from typing import TypeAlias

from .fixture import Fixture, FixtureIdentifierError, validate_fixture_id
from .evidence_format import EvidenceValidationError, integer, objects, string, strings
from .models import RunShape, Specification, Variant


JsonValue: TypeAlias = str | int | float | bool | None | list["JsonValue"] | dict[str, "JsonValue"]


@dataclass(frozen=True, slots=True)
class PreflightEvidence:
    variant_id: str
    fixture_id: str
    command: tuple[str, ...]
    return_code: int
    stdout_sha256: str
    stderr_sha256: str
    fixture_candidate_count: int
    candidate_name: str
    candidate_location: str
    stdout_path: str = ""
    stderr_path: str = ""


@dataclass(frozen=True, slots=True)
class PreflightCapture:
    evidence: PreflightEvidence
    stdout: str
    stderr: str
    failure: PreflightValidationError | None = None


class PreflightValidationError(RuntimeError):
    """Raised when pure-mode discovery does not prove the fixture candidate."""

    @property
    def is_retryable_omission(self) -> bool:
        return False

    @property
    def outcome(self) -> str:
        return "validation-error"


class CandidateDiscoveryOmissionError(PreflightValidationError):
    """Raised only when a successful pure discovery omits every fixture candidate."""

    @property
    def is_retryable_omission(self) -> bool:
        return True

    @property
    def outcome(self) -> str:
        return "semantic-discovery-omission"


@dataclass(frozen=True, slots=True)
class FixtureCandidate:
    name: str
    description: str
    location: Path


@dataclass(frozen=True, slots=True)
class CandidateDiscovery:
    fixture_candidate_count: int
    candidate: FixtureCandidate


@dataclass(frozen=True, slots=True)
class _RetainedCandidateEvidence:
    evidence_root: Path
    fixture_id: str
    candidate_location: str
    variant: Variant


def verify_candidate_discovery(command: str, fixture: Fixture, variant: Variant) -> PreflightCapture:
    """Verify that pure-mode skill discovery exposes this fixture candidate exactly once."""
    completed = subprocess.run([command, "debug", "skill", "--pure"], cwd=fixture.project_directory, capture_output=True, text=True, check=False, timeout=30)
    expected = FixtureCandidate(variant.skill_name, variant.description, fixture.skill_file.resolve())
    evidence = PreflightEvidence(variant.id, validate_fixture_id(fixture.project_directory.name), (command, "debug", "skill", "--pure"), completed.returncode, _hash(completed.stdout), _hash(completed.stderr), 0, "", "")
    if completed.returncode != 0:
        return PreflightCapture(evidence, completed.stdout, completed.stderr, PreflightValidationError("opencode debug skill --pure must exit zero"))
    try:
        discovery = validate_candidate_discovery(completed.stdout, fixture.skill_file.parent.parent, expected)
    except PreflightValidationError as error:
        return PreflightCapture(evidence, completed.stdout, completed.stderr, error)
    return PreflightCapture(replace(evidence, fixture_candidate_count=discovery.fixture_candidate_count, candidate_name=discovery.candidate.name, candidate_location=str(discovery.candidate.location)), completed.stdout, completed.stderr)


def validate_retained_candidate_discovery(stdout: str, retained: _RetainedCandidateEvidence) -> CandidateDiscovery:
    """Revalidate persisted discovery stdout against its recorded fixture candidate."""
    try:
        fixture_id = validate_fixture_id(retained.fixture_id)
    except FixtureIdentifierError as error:
        raise PreflightValidationError("retained preflight fixture identity is invalid") from error
    expected = FixtureCandidate(retained.variant.skill_name, retained.variant.description, _expected_candidate_location(retained.evidence_root, fixture_id, retained.variant))
    if _normalized_location(retained.candidate_location) != expected.location:
        raise PreflightValidationError("recorded fixture candidate location does not match its retained fixture")
    return validate_candidate_discovery(stdout, _fixture_skill_root(expected), expected)


def validate_candidate_discovery(stdout: str, fixture_skill_root: Path, expected: FixtureCandidate) -> CandidateDiscovery:
    """Parse pure discovery JSON and require one exact candidate beneath the fixture root."""
    candidates = _fixture_candidates(stdout, expected)
    if not candidates:
        raise CandidateDiscoveryOmissionError("opencode debug skill --pure omitted the fixture candidate")
    matches = [candidate for candidate in candidates if candidate == expected]
    if len(candidates) != 1 or len(matches) != 1:
        raise PreflightValidationError("opencode debug skill --pure did not discover exactly one expected fixture candidate")
    return CandidateDiscovery(len(candidates), matches[0])


def _fixture_candidates(stdout: str, expected: FixtureCandidate) -> list[FixtureCandidate]:
    try:
        document: JsonValue = json.loads(stdout)
    except json.JSONDecodeError as error:
        raise PreflightValidationError("opencode debug skill --pure did not return JSON") from error
    if not isinstance(document, list):
        raise PreflightValidationError("opencode debug skill --pure did not return a JSON array")
    fixture_root = _fixture_skill_root(expected)
    fixture_hierarchy = fixture_root.parent
    candidates: list[FixtureCandidate] = []
    for entry in document:
        if not isinstance(entry, dict):
            continue
        location = entry.get("location")
        if not isinstance(location, str):
            if entry.get("name") == expected.name or entry.get("description") == expected.description:
                raise PreflightValidationError("fixture-looking candidate discovery lacks a location")
            continue
        try:
            normalized_location = _normalized_location(location)
        except PreflightValidationError:
            if entry.get("name") == expected.name or ".opencode" in Path(location).parts:
                raise
            continue
        if normalized_location.is_relative_to(fixture_hierarchy):
            if not normalized_location.is_relative_to(fixture_root):
                raise PreflightValidationError("fixture candidate location is outside the skills hierarchy")
            candidates.append(_candidate(entry))
    return candidates


def _candidate(value: dict[str, JsonValue]) -> FixtureCandidate:
    name = value.get("name")
    description = value.get("description")
    location = value.get("location")
    if not isinstance(name, str) or not isinstance(description, str) or not isinstance(location, str):
        raise PreflightValidationError("fixture candidate discovery lacks name, description, or location")
    return FixtureCandidate(name, description, _normalized_location(location))


def _fixture_skill_root(candidate: FixtureCandidate) -> Path:
    location = candidate.location
    if location.name != "SKILL.md" or location.parent.name != candidate.name or location.parent.parent.name != "skills" or location.parent.parent.parent.name != ".opencode":
        raise PreflightValidationError("recorded fixture candidate location is not a normalized skill path")
    return location.parent.parent


def _expected_candidate_location(evidence_root: Path, fixture_id: str, variant: Variant) -> Path:
    return (evidence_root.resolve() / "fixtures" / fixture_id / ".opencode" / "skills" / variant.skill_name / "SKILL.md").resolve()


def _normalized_location(value: str) -> Path:
    location = Path(value)
    if not location.is_absolute() or str(location) != str(location.resolve()):
        raise PreflightValidationError("fixture candidate location must be normalized and absolute")
    return location.resolve()


def validate_preflight_evidence(root: Path, value: JsonValue | None, shape: RunShape, specification: Specification) -> None:
    """Reparse every retained preflight stream before it can support gate evidence."""
    entries = _entries(value)
    expected = {variant.id: variant for variant in shape.variants}
    if {string(entry.get("variant_id"), "preflight.variant_id") for entry in entries} != set(expected) or len(entries) != len(expected):
        raise EvidenceValidationError("preflight variants are missing, duplicate, or unauthorized")
    for entry in entries:
        variant = expected[string(entry.get("variant_id"), "preflight.variant_id")]
        attempts, successful_attempt = _attempts(entry)
        paths: set[str] = set()
        for index, attempt in enumerate(attempts, start=1):
            if "attempts" in entry:
                if integer(attempt.get("attempt"), "preflight.attempt") != index:
                    raise EvidenceValidationError("preflight attempt number does not match its position")
                if string(attempt.get("outcome"), "preflight.attempt.outcome") not in {"success", "semantic-discovery-omission"}:
                    raise EvidenceValidationError("preflight attempt has an unauthorized outcome")
                stdout_path = string(attempt.get("stdout_path"), "preflight.stdout_path")
                stderr_path = string(attempt.get("stderr_path"), "preflight.stderr_path")
                fixture_id = string(attempt.get("fixture_id"), "preflight.fixture_id")
                prefix = f"logs/preflight-{variant.id}-{fixture_id}-attempt-{index}"
                if stdout_path != f"{prefix}.stdout.txt" or stderr_path != f"{prefix}.stderr.txt" or stdout_path in paths or stderr_path in paths:
                    raise EvidenceValidationError("preflight attempt raw streams are not independently named")
                paths.update((stdout_path, stderr_path))
            _validate_stream_hashes(root, attempt)
        success = attempts[successful_attempt - 1]
        if "attempts" in entry and string(success.get("outcome"), "preflight.attempt.outcome") != "success":
            raise EvidenceValidationError("preflight selected successful attempt must have success outcome")
        _validate_success(root, success, variant)
        if len(attempts) == 2:
            _validate_retry(entry, attempts, variant, root)
        if "attempts" in entry:
            _validate_declared_success(entry, success, successful_attempt)


def _attempts(entry: dict[str, JsonValue]) -> tuple[tuple[dict[str, JsonValue], ...], int]:
    if "attempts" not in entry and "successful_attempt" not in entry:
        return (entry,), 1
    attempts = tuple(objects(entry.get("attempts"), "preflight.attempts"))
    successful_attempt = integer(entry.get("successful_attempt"), "preflight.successful_attempt")
    if len(attempts) not in (1, 2) or successful_attempt != len(attempts):
        raise EvidenceValidationError("preflight retry attempts do not stop at the declared success")
    return attempts, successful_attempt


def _validate_stream_hashes(root: Path, entry: dict[str, JsonValue]) -> None:
    stdout = _evidence_path(root, string(entry.get("stdout_path"), "preflight.stdout_path"))
    stderr = _evidence_path(root, string(entry.get("stderr_path"), "preflight.stderr_path"))
    if _file_hash(stdout) != string(entry.get("stdout_sha256"), "preflight.stdout_sha256") or _file_hash(stderr) != string(entry.get("stderr_sha256"), "preflight.stderr_sha256"):
        raise EvidenceValidationError("preflight raw stream hash does not match manifest")


def _validate_success(root: Path, entry: dict[str, JsonValue], variant: Variant) -> None:
    command = strings(entry.get("command"), "preflight.command")
    fixture_id = string(entry.get("fixture_id"), "preflight.fixture_id")
    candidate_location = string(entry.get("candidate_location"), "preflight.candidate_location")
    if len(command) != 4 or not command[0] or command[1:] != ("debug", "skill", "--pure") or integer(entry.get("return_code"), "preflight.return_code") != 0 or integer(entry.get("fixture_candidate_count"), "preflight.fixture_candidate_count") != 1 or string(entry.get("candidate_name"), "preflight.candidate_name") != variant.skill_name:
        raise EvidenceValidationError("preflight metadata does not match variant")
    stdout = _evidence_path(root, string(entry.get("stdout_path"), "preflight.stdout_path"))
    try:
        discovery = validate_retained_candidate_discovery(stdout.read_text(encoding="utf-8"), _RetainedCandidateEvidence(root, fixture_id, candidate_location, variant))
    except PreflightValidationError as error:
        raise EvidenceValidationError(str(error)) from error
    if discovery.fixture_candidate_count != integer(entry.get("fixture_candidate_count"), "preflight.fixture_candidate_count") or discovery.candidate.name != string(entry.get("candidate_name"), "preflight.candidate_name") or str(discovery.candidate.location) != candidate_location:
        raise EvidenceValidationError("preflight candidate metadata does not match reparsed stdout")


def _validate_retry(entry: dict[str, JsonValue], attempts: tuple[dict[str, JsonValue], ...], variant: Variant, root: Path) -> None:
    first, success = attempts
    if string(first.get("outcome"), "preflight.attempt.outcome") != "semantic-discovery-omission" or string(success.get("outcome"), "preflight.attempt.outcome") != "success":
        raise EvidenceValidationError("preflight retry is not an omission followed by success")
    if integer(first.get("attempt"), "preflight.attempt") != 1 or integer(success.get("attempt"), "preflight.attempt") != 2 or string(first.get("variant_id"), "preflight.variant_id") != variant.id or strings(first.get("command"), "preflight.command") != strings(success.get("command"), "preflight.command") or string(first.get("fixture_id"), "preflight.fixture_id") != string(success.get("fixture_id"), "preflight.fixture_id") or integer(first.get("return_code"), "preflight.return_code") != 0 or integer(first.get("fixture_candidate_count"), "preflight.fixture_candidate_count") != 0 or string(first.get("candidate_name"), "preflight.candidate_name") or string(first.get("candidate_location"), "preflight.candidate_location"):
        raise EvidenceValidationError("preflight retry does not use the same omission fixture")
    fixture_id = string(first.get("fixture_id"), "preflight.fixture_id")
    expected = FixtureCandidate(variant.skill_name, variant.description, _expected_candidate_location(root, fixture_id, variant))
    stdout = _evidence_path(root, string(first.get("stdout_path"), "preflight.stdout_path"))
    try:
        if _fixture_candidates(stdout.read_text(encoding="utf-8"), expected):
            raise EvidenceValidationError("preflight retry first attempt was not a fixture omission")
    except PreflightValidationError as error:
        raise EvidenceValidationError(str(error)) from error


def _validate_declared_success(entry: dict[str, JsonValue], success: dict[str, JsonValue], successful_attempt: int) -> None:
    if integer(entry.get("successful_attempt"), "preflight.successful_attempt") != successful_attempt:
        raise EvidenceValidationError("preflight successful attempt does not match its retained stream")
    for field in ("variant_id", "fixture_id", "command", "return_code", "stdout_sha256", "stderr_sha256", "fixture_candidate_count", "candidate_name", "candidate_location", "stdout_path", "stderr_path"):
        if entry.get(field) != success.get(field):
            raise EvidenceValidationError("preflight success metadata does not match the declared attempt")


def _entries(value: JsonValue | None) -> list[dict[str, JsonValue]]:
    if not isinstance(value, list):
        raise EvidenceValidationError("preflight must be a list of objects")
    entries: list[dict[str, JsonValue]] = []
    for entry in value:
        if not isinstance(entry, dict):
            raise EvidenceValidationError("preflight must be a list of objects")
        entries.append(entry)
    return entries


def _evidence_path(root: Path, relative_path: str) -> Path:
    path = (root / relative_path).resolve()
    if not relative_path.startswith("logs/") or not path.is_relative_to(root) or not path.is_file():
        raise EvidenceValidationError("raw stream path is missing or unauthorized")
    return path


def _file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()
