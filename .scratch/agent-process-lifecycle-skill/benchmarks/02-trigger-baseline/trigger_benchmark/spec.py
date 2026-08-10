from __future__ import annotations

import json
from pathlib import Path
from .evidence_format import JsonValue
from .models import Metadata, Prompt, Specification, Variant


CANDIDATE_DESCRIPTION = "Use when lifecycle-decision routing is needed for an Agent-caused local OS process: a foreground local command may hang or outlive the initiating tool call, a lingering, zombie, or unclear-owner local process needs cleanup or reconciliation, or the task explicitly requests a lifecycle decision for an Agent-started or managed current-run binding. On Windows, select the first viable execution tier and handle readiness, Stop, Preserve, handoff, or reconciliation. On non-Windows, classify an Agent-caused local process only to hand off or block before launch; do not perform lifecycle execution. Do not use for a command that remains synchronous until normal exit, regardless of duration. Do not load this skill merely to classify, Preserve, observe, check status, or use a resource when the prompt already identifies a framework, IDE, Kubernetes, Docker, Windows Service, CI, or other external or runtime owner and states its complete lifecycle contract; follow that owner's contract directly."
EXPECTED_VARIANT_SOURCES = (
    ("current", "../../../../skills/playwright-server-lifecycle/SKILL.md", "playwright-server-lifecycle"),
    ("candidate", "../../candidate/agent-process-lifecycle/SKILL.md", "agent-process-lifecycle"),
)


class SpecificationError(Exception):
    """Raised when frozen benchmark controls no longer describe the published skill."""


def load_specification(benchmark_root: Path) -> Specification:
    """Load the fixed prompts and the two source-controlled frontmatters."""
    variants_document = _load_document(benchmark_root / "variants.json")
    evaluations_document = _load_document(benchmark_root / "trigger-evals.json")
    variants = _load_variants(benchmark_root, variants_document)
    prompts = tuple(Prompt(_string(item["id"], "prompt.id"), _string(item["label"], "prompt.label"), _string(item["body"], "prompt.body")) for item in _mappings(evaluations_document["prompts"], "prompts"))
    _validate(prompts, variants)
    return Specification(prompts, variants)


def _load_variants(benchmark_root: Path, document: dict[str, JsonValue]) -> tuple[Variant, ...]:
    if document.get("schema_version") != 2 or set(document) != {"schema_version", "variants"}:
        raise SpecificationError("variants.json must use schema 2 with only variants")
    entries = _mappings(document["variants"], "variants")
    expected_ids = tuple(entry[0] for entry in EXPECTED_VARIANT_SOURCES)
    found_ids = tuple(_string(entry.get("id"), "variant.id") for entry in entries)
    if found_ids != expected_ids:
        raise SpecificationError("variants.json must retain exactly current and candidate")
    variants: list[Variant] = []
    for entry, (expected_id, expected_path, expected_name) in zip(entries, EXPECTED_VARIANT_SOURCES, strict=True):
        if set(entry) != {"id", "skill_path"}:
            raise SpecificationError("variant entries must contain only id and skill_path")
        skill_path = _string(entry["skill_path"], "variant.skill_path")
        if skill_path != expected_path:
            raise SpecificationError(f"{expected_id} source path changed")
        metadata = _read_frontmatter((benchmark_root / skill_path).resolve())
        if metadata.name != expected_name:
            raise SpecificationError(f"{expected_id} frontmatter name changed")
        if expected_id == "candidate" and metadata.description != CANDIDATE_DESCRIPTION:
            raise SpecificationError("candidate frontmatter description changed")
        variants.append(Variant(expected_id, metadata.name, metadata.description, skill_path))
    return tuple(variants)


def _load_document(path: Path) -> dict[str, JsonValue]:
    try:
        document: JsonValue = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SpecificationError(f"invalid JSON in {path.name}: {error.msg}") from error
    if not isinstance(document, dict):
        raise SpecificationError(f"{path.name} must be a JSON object")
    return document


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


def _validate(prompts: tuple[Prompt, ...], variants: tuple[Variant, ...]) -> None:
    if tuple(variant.id for variant in variants) != ("current", "candidate"):
        raise SpecificationError("variants must retain the exact two-way design")
    if len(prompts) != 16 or sum(prompt.label == "positive" for prompt in prompts) != 8 or sum(prompt.label == "negative" for prompt in prompts) != 8:
        raise SpecificationError("trigger-evals.json must contain eight positive and eight negative prompts")
    candidate_names = {variant.skill_name for variant in variants}
    if any(name in prompt.body for name in candidate_names for prompt in prompts):
        raise SpecificationError("benchmark prompts must not name a candidate skill")
