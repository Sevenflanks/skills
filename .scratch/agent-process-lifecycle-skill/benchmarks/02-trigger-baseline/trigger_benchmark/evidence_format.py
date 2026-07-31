from __future__ import annotations

import hashlib
import json
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import TypeAlias, TypeGuard

from .models import RunPhase


JsonValue: TypeAlias = str | int | float | bool | None | list["JsonValue"] | dict[str, "JsonValue"]
JsonArray: TypeAlias = list[JsonValue]
JsonObject: TypeAlias = dict[str, JsonValue]


class EvidenceValidationError(Exception):
    """Raised when release evidence is missing, unauthorized, or inconsistent."""


class EvidenceIncompleteError(EvidenceValidationError):
    """Raised when otherwise parseable evidence lacks its required valid cells."""


def document(path: Path) -> dict[str, JsonValue]:
    return document_text(path.read_text(encoding="utf-8"), path.name)


def document_text(text: str, location: str) -> dict[str, JsonValue]:
    try:
        parsed = _json_value(json.loads(text))
    except json.JSONDecodeError as error:
        raise EvidenceValidationError(f"{location} is not valid JSON") from error
    return mapping(parsed, location)


def json_array(values: Iterable[JsonValue]) -> JsonArray:
    return list(values)


def json_object(values: Mapping[str, JsonValue]) -> JsonObject:
    return dict(values)


def _json_value(value: object) -> JsonValue:
    if value is None or isinstance(value, str | bool):
        return value
    if isinstance(value, int | float):
        return value
    if _is_json_list(value):
        return json_array(_json_value(item) for item in value)
    if _is_json_object(value):
        document: JsonObject = {}
        for key, item in value.items():
            if not isinstance(key, str):
                raise EvidenceValidationError("JSON object keys must be strings")
            document[key] = _json_value(item)
        return document
    raise EvidenceValidationError("JSON contains an unsupported value")


def _is_json_list(value: object) -> TypeGuard[list[object]]:
    return isinstance(value, list)


def _is_json_object(value: object) -> TypeGuard[dict[object, object]]:
    return isinstance(value, dict)


def mapping(value: JsonValue | None, location: str) -> dict[str, JsonValue]:
    if not isinstance(value, dict):
        raise EvidenceValidationError(f"{location} must be a JSON object")
    return value


def hash_mapping(value: JsonValue | None, location: str) -> dict[str, str]:
    return {key: string(item, location) for key, item in mapping(value, location).items()}


def strings(value: JsonValue | None, location: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise EvidenceValidationError(f"{location} must be a list of strings")
    return tuple(string(item, location) for item in value)


def string(value: JsonValue | None, location: str) -> str:
    if not isinstance(value, str):
        raise EvidenceValidationError(f"{location} must be a string")
    return value


def integer(value: JsonValue | None, location: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise EvidenceValidationError(f"{location} must be an integer")
    return value


def optional_integer(value: JsonValue | None, location: str) -> int | None:
    return None if value is None else integer(value, location)


def number(value: JsonValue | None, location: str) -> float:
    if not isinstance(value, int | float) or isinstance(value, bool):
        raise EvidenceValidationError(f"{location} must be a number")
    return float(value)


def phase(value: str) -> RunPhase:
    try:
        return RunPhase(value)
    except ValueError as error:
        raise EvidenceValidationError("manifest phase is unknown") from error


def signature(value: dict[str, JsonValue] | dict[str, str]) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()
