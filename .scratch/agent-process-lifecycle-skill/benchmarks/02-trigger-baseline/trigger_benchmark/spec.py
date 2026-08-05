from __future__ import annotations

import json
from pathlib import Path
from typing import TypeAlias

from .models import Metadata, Prompt, Specification, Variant


class SpecificationError(Exception):
    """Raised when frozen benchmark controls no longer describe the published skill."""


JsonValue: TypeAlias = str | int | float | bool | None | list["JsonValue"] | dict[str, "JsonValue"]


def load_specification(benchmark_root: Path) -> Specification:
    """Load frozen inputs and fail if their current-metadata control drifted."""
    variants_document = _load_document(benchmark_root / "variants.json")
    evaluations_document = _load_document(benchmark_root / "trigger-evals.json")
    current = _mapping(variants_document["current_metadata"], "current_metadata")
    current_metadata = Metadata(_string(current["name"], "current_metadata.name"), _string(current["description"], "current_metadata.description"))
    published_skill_path = _string(variants_document["published_skill_path"], "published_skill_path")
    published_path = (benchmark_root / published_skill_path).resolve()
    published = _read_frontmatter(published_path)
    if published != current_metadata:
        raise SpecificationError("variants.json current_metadata no longer matches published SKILL.md")
    generalized_description = _string(variants_document["generalized_description"], "generalized_description")
    variants = tuple(
        Variant(_string(item["id"], "variant.id"), _string(item["skill_name"], "variant.skill_name"), _variant_description(_string(item["description_source"], "variant.description_source"), current_metadata, generalized_description))
        for item in _mappings(variants_document["variants"], "variants")
    )
    prompts = tuple(Prompt(_string(item["id"], "prompt.id"), _string(item["label"], "prompt.label"), _string(item["body"], "prompt.body")) for item in _mappings(evaluations_document["prompts"], "prompts"))
    _validate(prompts, variants)
    return Specification(prompts, variants, current_metadata, published_skill_path)


def _load_document(path: Path) -> dict[str, JsonValue]:
    try:
        document: JsonValue = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SpecificationError(f"invalid JSON in {path.name}: {error.msg}") from error
    if not isinstance(document, dict):
        raise SpecificationError(f"{path.name} must be a JSON object")
    return document


def _mapping(value: JsonValue, location: str) -> dict[str, JsonValue]:
    if not isinstance(value, dict):
        raise SpecificationError(f"{location} must be a JSON object")
    return value


def _mappings(value: JsonValue, location: str) -> list[dict[str, JsonValue]]:
    if not isinstance(value, list):
        raise SpecificationError(f"{location} must be a JSON array of objects")
    mappings: list[dict[str, JsonValue]] = []
    for item in value:
        if not isinstance(item, dict):
            raise SpecificationError(f"{location} must be a JSON array of objects")
        mappings.append(item)
    return mappings


def _string(value: JsonValue, location: str) -> str:
    if not isinstance(value, str):
        raise SpecificationError(f"{location} must be a string")
    return value


def _read_frontmatter(path: Path) -> Metadata:
    lines = path.read_text(encoding="utf-8").splitlines()
    if len(lines) < 4 or lines[0] != "---":
        raise SpecificationError("published SKILL.md lacks frontmatter")
    values: dict[str, str] = {}
    for line in lines[1:]:
        if line == "---":
            break
        key, separator, value = line.partition(":")
        if separator and key in {"name", "description"}:
            values[key] = value.strip()
    try:
        return Metadata(values["name"], values["description"])
    except KeyError as error:
        raise SpecificationError("published SKILL.md lacks name or description") from error


def _variant_description(source: str, current: Metadata, generalized: str) -> str:
    match source:
        case "current_metadata":
            return current.description
        case "generalized_description":
            return generalized
        case unexpected:
            raise SpecificationError(f"unknown description source: {unexpected}")


def _validate(prompts: tuple[Prompt, ...], variants: tuple[Variant, ...]) -> None:
    if [variant.id for variant in variants] != ["current", "generalized-current-name", "generalized-neutral-name"]:
        raise SpecificationError("variants must retain the exact three-way control design")
    if len(prompts) != 16 or sum(prompt.label == "positive" for prompt in prompts) != 8 or sum(prompt.label == "negative" for prompt in prompts) != 8:
        raise SpecificationError("trigger-evals.json must contain eight positive and eight negative prompts")
    candidate_names = {variant.skill_name for variant in variants}
    if any(name in prompt.body for name in candidate_names for prompt in prompts):
        raise SpecificationError("benchmark prompts must not name a candidate skill")
