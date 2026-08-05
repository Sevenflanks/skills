from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from .models import Variant


PERMISSION_POLICY: Final = {"*": "deny", "skill": "allow"}


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


def fixture_skill_files(project_directory: Path) -> list[Path]:
    return sorted((project_directory / ".opencode" / "skills").glob("*/SKILL.md"))


def _skill_document(variant: Variant) -> str:
    return f"---\nname: {variant.skill_name}\ndescription: {variant.description}\nlicense: MIT\nmetadata:\n  author: benchmark-fixture\n  version: 0.0.0\n---\n\n# Benchmark Fixture\n\nClassify lifecycle ownership requests. Do not execute commands, edit files, or start processes for this fixture.\n"
