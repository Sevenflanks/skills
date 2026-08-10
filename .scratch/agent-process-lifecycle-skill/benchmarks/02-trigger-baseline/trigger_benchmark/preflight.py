from __future__ import annotations

import hashlib
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import TypeAlias

from .fixture import Fixture
from .models import Variant


JsonValue: TypeAlias = str | int | float | bool | None | list["JsonValue"] | dict[str, "JsonValue"]


@dataclass(frozen=True, slots=True)
class PreflightEvidence:
    variant_id: str
    command: tuple[str, ...]
    return_code: int
    stdout_sha256: str
    stderr_sha256: str
    fixture_candidate_count: int
    candidate_name: str
    candidate_location: str


def verify_candidate_discovery(command: str, fixture: Fixture, variant: Variant) -> PreflightEvidence:
    """Verify that pure-mode skill discovery exposes this fixture candidate exactly once."""
    completed = subprocess.run([command, "debug", "skill", "--pure"], cwd=fixture.project_directory, capture_output=True, text=True, check=False, timeout=30)
    candidates = _fixture_candidates(completed.stdout, fixture.project_directory)
    expected_location = str(fixture.skill_file.resolve())
    matching = [entry for entry in candidates if entry["name"] == variant.skill_name and entry["description"] == variant.description and entry["location"] == expected_location]
    if completed.returncode != 0 or len(candidates) != 1 or len(matching) != 1:
        raise RuntimeError("opencode debug skill --pure did not discover exactly one expected fixture candidate")
    return PreflightEvidence(variant.id, (command, "debug", "skill", "--pure"), completed.returncode, _hash(completed.stdout), _hash(completed.stderr), len(candidates), variant.skill_name, expected_location)


def _fixture_candidates(stdout: str, fixture_directory: Path) -> list[dict[str, str]]:
    try:
        document: JsonValue = json.loads(stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("opencode debug skill --pure did not return JSON") from error
    if not isinstance(document, list):
        raise RuntimeError("opencode debug skill --pure did not return a JSON array")
    fixture_root = (fixture_directory / ".opencode" / "skills").resolve()
    candidates: list[dict[str, str]] = []
    for entry in document:
        if not isinstance(entry, dict):
            continue
        location = entry.get("location")
        if isinstance(location, str) and Path(location).resolve().is_relative_to(fixture_root):
            candidates.append(_entry(entry))
    return candidates


def _entry(value: dict[str, JsonValue]) -> dict[str, str]:
    name = value.get("name")
    description = value.get("description")
    location = value.get("location")
    if not isinstance(name, str) or not isinstance(description, str) or not isinstance(location, str):
        raise RuntimeError("fixture candidate discovery lacks name, description, or location")
    return {"name": name, "description": description, "location": str(Path(location).resolve())}


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()
