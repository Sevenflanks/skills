from __future__ import annotations

import hashlib
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import TypeAlias

from .fixture import Fixture, FixtureIdentifierError, validate_fixture_id
from .evidence_format import EvidenceValidationError, integer, string, strings
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


class PreflightValidationError(RuntimeError):
    """Raised when pure-mode discovery does not prove the fixture candidate."""


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
    discovery = validate_candidate_discovery(completed.stdout, fixture.skill_file.parent.parent, expected)
    if completed.returncode != 0:
        raise PreflightValidationError("opencode debug skill --pure must exit zero")
    evidence = PreflightEvidence(variant.id, validate_fixture_id(fixture.project_directory.name), (command, "debug", "skill", "--pure"), completed.returncode, _hash(completed.stdout), _hash(completed.stderr), discovery.fixture_candidate_count, discovery.candidate.name, str(discovery.candidate.location))
    return PreflightCapture(evidence, completed.stdout, completed.stderr)


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
    candidates = _fixture_candidates(stdout, fixture_skill_root)
    matches = [candidate for candidate in candidates if candidate == expected]
    if len(candidates) != 1 or len(matches) != 1:
        raise PreflightValidationError("opencode debug skill --pure did not discover exactly one expected fixture candidate")
    return CandidateDiscovery(len(candidates), matches[0])


def _fixture_candidates(stdout: str, fixture_skill_root: Path) -> list[FixtureCandidate]:
    try:
        document: JsonValue = json.loads(stdout)
    except json.JSONDecodeError as error:
        raise PreflightValidationError("opencode debug skill --pure did not return JSON") from error
    if not isinstance(document, list):
        raise PreflightValidationError("opencode debug skill --pure did not return a JSON array")
    fixture_root = fixture_skill_root.resolve()
    candidates: list[FixtureCandidate] = []
    for entry in document:
        if not isinstance(entry, dict):
            continue
        location = entry.get("location")
        if isinstance(location, str) and _normalized_location(location).is_relative_to(fixture_root):
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
        command = strings(entry.get("command"), "preflight.command")
        fixture_id = string(entry.get("fixture_id"), "preflight.fixture_id")
        candidate_location = string(entry.get("candidate_location"), "preflight.candidate_location")
        if len(command) != 4 or not command[0] or command[1:] != ("debug", "skill", "--pure") or integer(entry.get("return_code"), "preflight.return_code") != 0 or integer(entry.get("fixture_candidate_count"), "preflight.fixture_candidate_count") != 1 or string(entry.get("candidate_name"), "preflight.candidate_name") != variant.skill_name:
            raise EvidenceValidationError("preflight metadata does not match variant")
        stdout = _evidence_path(root, string(entry.get("stdout_path"), "preflight.stdout_path"))
        stderr = _evidence_path(root, string(entry.get("stderr_path"), "preflight.stderr_path"))
        if _file_hash(stdout) != string(entry.get("stdout_sha256"), "preflight.stdout_sha256") or _file_hash(stderr) != string(entry.get("stderr_sha256"), "preflight.stderr_sha256"):
            raise EvidenceValidationError("preflight raw stream hash does not match manifest")
        try:
            discovery = validate_retained_candidate_discovery(stdout.read_text(encoding="utf-8"), _RetainedCandidateEvidence(root, fixture_id, candidate_location, variant))
        except PreflightValidationError as error:
            raise EvidenceValidationError(str(error)) from error
        if discovery.fixture_candidate_count != integer(entry.get("fixture_candidate_count"), "preflight.fixture_candidate_count") or discovery.candidate.name != string(entry.get("candidate_name"), "preflight.candidate_name") or str(discovery.candidate.location) != candidate_location:
            raise EvidenceValidationError("preflight candidate metadata does not match reparsed stdout")


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
