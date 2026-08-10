from __future__ import annotations

import json
from dataclasses import dataclass
from typing import assert_never

type RawJson = None | bool | int | float | str | list["RawJson"] | dict[str, "RawJson"]
type JsonAtom = None | bool | int | float | str
type JsonValue = JsonAtom | JsonArray | JsonObject


@dataclass(frozen=True, slots=True)
class BoundaryError(RuntimeError):
    location: str
    reason: str

    def __str__(self) -> str:
        return f"{self.location}: {self.reason}"


@dataclass(frozen=True, slots=True)
class JsonField:
    present: bool
    value: JsonValue


@dataclass(frozen=True, slots=True)
class JsonArray:
    values: tuple[JsonValue, ...]


@dataclass(frozen=True, slots=True)
class JsonObject:
    entries: tuple[tuple[str, JsonValue], ...]

    def find(self, key: str) -> JsonField:
        for entry_key, value in self.entries:
            if entry_key == key:
                return JsonField(True, value)
        return JsonField(False, None)

    def required(self, key: str, location: str) -> JsonValue:
        field = self.find(key)
        if field.present:
            return field.value
        raise BoundaryError(location, f"missing {key!r}")

    def contains(self, key: str) -> bool:
        return self.find(key).present


@dataclass(frozen=True, slots=True)
class Lookup:
    found: bool
    value: JsonValue


def json_document(text: str, location: str) -> JsonValue:
    try:
        return _decode(json.loads(text), location)
    except json.JSONDecodeError as error:
        raise BoundaryError(location, "invalid JSON") from error


def expect_object(value: JsonValue, location: str) -> JsonObject:
    match value:
        case JsonObject() as result:
            return result
        case None | bool() | int() | float() | str() | JsonArray():
            raise BoundaryError(location, "expected JSON object")
        case unreachable:
            assert_never(unreachable)


def expect_array(value: JsonValue, location: str) -> JsonArray:
    match value:
        case JsonArray() as result:
            return result
        case None | bool() | int() | float() | str() | JsonObject():
            raise BoundaryError(location, "expected JSON array")
        case unreachable:
            assert_never(unreachable)


def expect_string(value: JsonValue, location: str) -> str:
    match value:
        case str() as result:
            return result
        case None | bool() | int() | float() | JsonArray() | JsonObject():
            raise BoundaryError(location, "expected string")
        case unreachable:
            assert_never(unreachable)


def lookup(payload: JsonObject, path: str) -> Lookup:
    current = payload
    segments = path.split(".")
    for index, segment in enumerate(segments):
        field = current.find(segment)
        if not field.present:
            return Lookup(False, None)
        if index == len(segments) - 1:
            return Lookup(True, field.value)
        match field.value:
            case JsonObject() as nested:
                current = nested
            case None | bool() | int() | float() | str() | JsonArray():
                return Lookup(False, None)
            case unreachable:
                assert_never(unreachable)
    raise BoundaryError("response path", "path must contain a segment")


def reference_paths(value: JsonValue) -> tuple[str, ...]:
    match value:
        case str() as text:
            normalized = text.replace("\\", "/")
            marker = "references/"
            return (normalized[normalized.index(marker):],) if marker in normalized else ()
        case JsonArray(values=values):
            return tuple(path for item in values for path in reference_paths(item))
        case JsonObject(entries=entries):
            return tuple(path for _, item in entries for path in reference_paths(item))
        case None | bool() | int() | float():
            return ()
        case unreachable:
            assert_never(unreachable)


def portable(value: JsonValue, candidate_directory: str) -> JsonValue:
    normalized_directory = candidate_directory.replace("\\", "/").rstrip("/")
    match value:
        case str() as text:
            normalized = text.replace("\\", "/")
            marker = "/.opencode/skills/agent-process-lifecycle/"
            if marker in normalized:
                return normalized.split(marker, 1)[1]
            return normalized.removeprefix(f"{normalized_directory}/")
        case JsonArray(values=values):
            return JsonArray(tuple(portable(item, candidate_directory) for item in values))
        case JsonObject(entries=entries):
            return JsonObject(tuple((key, portable(item, candidate_directory)) for key, item in entries))
        case None | bool() | int() | float():
            return value
        case unreachable:
            assert_never(unreachable)


def values_equal(left: JsonValue, right: JsonValue) -> bool:
    match left, right:
        case JsonObject(entries=left_entries), JsonObject(entries=right_entries):
            right_object = JsonObject(right_entries)
            return len(left_entries) == len(right_entries) and all(field.present and values_equal(value, field.value) for key, value in left_entries if (field := right_object.find(key)))
        case JsonArray(values=left_values), JsonArray(values=right_values):
            return len(left_values) == len(right_values) and all(values_equal(left_value, right_value) for left_value, right_value in zip(left_values, right_values, strict=True))
        case JsonObject() | JsonArray(), _:
            return False
        case _, JsonObject() | JsonArray():
            return False
        case None | bool() | int() | float() | str(), None | bool() | int() | float() | str():
            return left == right
        case unreachable:
            assert_never(unreachable)


def json_text(value: JsonValue, *, indent: int | None = None) -> str:
    match value:
        case JsonObject(entries=entries):
            separator = "," if indent is None else ",\n"
            prefix = "" if indent is None else " " * indent
            content = separator.join(f"{prefix}{json.dumps(key)}: {json_text(item, indent=indent)}" for key, item in entries)
            return f"{{{content}}}" if indent is None else f"{{\n{content}\n}}"
        case JsonArray(values=values):
            separator = "," if indent is None else ",\n"
            prefix = "" if indent is None else " " * indent
            content = separator.join(f"{prefix}{json_text(item, indent=indent)}" for item in values)
            return f"[{content}]" if indent is None else f"[\n{content}\n]"
        case None | bool() | int() | float() | str():
            return json.dumps(value, ensure_ascii=True)
        case unreachable:
            assert_never(unreachable)


def record(*entries: tuple[str, JsonValue]) -> JsonObject:
    return JsonObject(entries)


def _decode(raw: RawJson, location: str) -> JsonValue:
    match raw:
        case None | bool() | int() | float() | str():
            return raw
        case list() as values:
            return JsonArray(tuple(_decode(value, f"{location}[{index}]") for index, value in enumerate(values)))
        case dict() as entries:
            return JsonObject(tuple((key, _decode(value, f"{location}.{key}")) for key, value in entries.items()))
        case unreachable:
            assert_never(unreachable)
