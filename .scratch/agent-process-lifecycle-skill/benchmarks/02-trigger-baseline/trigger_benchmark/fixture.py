from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path, PureWindowsPath
from typing import Final

from .models import Variant


PERMISSION_POLICY: Final = {"*": "deny", "skill": "allow"}
_REMOVED_ENVIRONMENT_KEYS: Final = ("OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "OPENCODE_CONFIG_DIR", "OPENCODE_PERMISSION", "OPENCODE_DISABLE_PROJECT_CONFIG")


class FixtureIdentifierError(Exception):
    """Raised when retained evidence names more than one fixture directory."""


@dataclass(frozen=True, slots=True)
class Fixture:
    project_directory: Path
    skill_file: Path
    permission_policy: dict[str, str]


def create_fixture(project_directory: Path, variant: Variant) -> Fixture:
    """Create a project with precisely one inert candidate skill and deny-by-default tools."""
    skill_file = project_directory / ".opencode" / "skills" / variant.skill_name / "SKILL.md"
    skill_file.parent.mkdir(parents=True, exist_ok=True)
    skill_file.write_text(_skill_document(variant), encoding="utf-8")
    (project_directory / "opencode.json").write_text(json.dumps({"permission": PERMISSION_POLICY}, indent=2) + "\n", encoding="utf-8")
    files = fixture_skill_files(project_directory)
    if files != [skill_file]:
        raise RuntimeError("fixture contains an unexpected candidate skill")
    return Fixture(project_directory, skill_file, PERMISSION_POLICY)


def fixture_environment(project_directory: Path) -> dict[str, str]:
    environment = dict(os.environ)
    for key in _REMOVED_ENVIRONMENT_KEYS:
        environment.pop(key, None)
    fixture_home = str(project_directory.resolve())
    environment["XDG_CONFIG_HOME"] = fixture_home
    environment["OPENCODE_TEST_HOME"] = fixture_home
    environment["OPENCODE_DISABLE_EXTERNAL_SKILLS"] = "1"
    return environment


def fixture_skill_files(project_directory: Path) -> list[Path]:
    return sorted((project_directory / ".opencode" / "skills").glob("*/SKILL.md"))


def validate_fixture_id(value: str) -> str:
    """Accept only one cross-platform-safe basename for an evidence fixture."""
    path = Path(value)
    windows_path = PureWindowsPath(value)
    if not value or value in {".", ".."} or "/" in value or "\\" in value or path.is_absolute() or path.name != value or path.anchor or windows_path.is_absolute() or windows_path.drive:
        raise FixtureIdentifierError("fixture identifier must be one safe basename")
    return value


def _skill_document(variant: Variant) -> str:
    return f"---\nname: {variant.skill_name}\ndescription: {variant.description}\nlicense: MIT\nmetadata:\n  author: benchmark-fixture\n  version: 0.0.0\n---\n\n# Benchmark Fixture\n\nClassify lifecycle ownership requests. Do not execute commands, edit files, or start processes for this fixture.\n"
