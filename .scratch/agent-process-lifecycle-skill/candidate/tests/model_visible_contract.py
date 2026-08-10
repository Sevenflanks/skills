from __future__ import annotations

from dataclasses import dataclass
from typing import assert_never

from model_visible_json import BoundaryError, JsonArray, JsonObject, JsonValue, expect_array, expect_object, expect_string, json_document


@dataclass(frozen=True, slots=True)
class ExpectedEquals:
    path: str
    expected: JsonValue


@dataclass(frozen=True, slots=True)
class AnyEquals:
    paths: tuple[str, ...]
    expected: JsonValue


@dataclass(frozen=True, slots=True)
class Case:
    identifier: str
    prompt: str
    response_equals: tuple[ExpectedEquals, ...]
    response_any_equals: tuple[AnyEquals, ...]
    response_has_keys: tuple[str, ...]
    allowed_tools: frozenset[str]
    reference_reads: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Discovery:
    name: str
    location: str


@dataclass(frozen=True, slots=True)
class StreamEvent:
    kind: str
    part: JsonObject | None


@dataclass(frozen=True, slots=True)
class ModelResponse:
    text: str
    payload: JsonObject


@dataclass(frozen=True, slots=True)
class InvalidModelResponse:
    text: str
    reason: str


def load_cases(text: str, expected_skill_name: str) -> tuple[Case, ...]:
    metadata = expect_object(json_document(text, "eval metadata"), "eval metadata")
    skill_name = expect_string(metadata.required("skill_name", "eval metadata"), "eval metadata.skill_name")
    if skill_name != expected_skill_name:
        raise BoundaryError("eval metadata.skill_name", f"expected {expected_skill_name!r}")
    entries = expect_array(metadata.required("evals", "eval metadata"), "eval metadata.evals")
    return tuple(_case(expect_object(value, f"evals[{index}]"), index) for index, value in enumerate(entries.values))


def parse_preflight(text: str) -> tuple[Discovery, ...]:
    entries = expect_array(json_document(text, "OpenCode preflight"), "OpenCode preflight")
    return tuple(_discovery(expect_object(value, f"OpenCode preflight[{index}]"), index) for index, value in enumerate(entries.values))


def parse_events(text: str) -> tuple[StreamEvent, ...]:
    lines = tuple(line for line in text.splitlines() if line.strip())
    return tuple(_stream_event(json_document(line, f"NDJSON event {index}"), index) for index, line in enumerate(lines))


def parse_response(text: str) -> ModelResponse | InvalidModelResponse:
    try:
        return ModelResponse(text, expect_object(json_document(text, "model response"), "model response"))
    except BoundaryError as error:
        return InvalidModelResponse(text, str(error))


def _case(entry: JsonObject, index: int) -> Case:
    location = f"evals[{index}]"
    assertions = expect_object(entry.required("assertions", location), f"{location}.assertions")
    equals = expect_object(assertions.required("response_equals", f"{location}.assertions"), f"{location}.assertions.response_equals")
    any_equals = _optional_array(assertions, "response_any_equals", f"{location}.assertions")
    return Case(
        expect_string(entry.required("id", location), f"{location}.id"),
        expect_string(entry.required("prompt", location), f"{location}.prompt"),
        tuple(ExpectedEquals(path, value) for path, value in equals.entries),
        tuple(_any_equals(expect_object(value, f"{location}.assertions.response_any_equals[{position}]"), position, location) for position, value in enumerate(any_equals.values)),
        _string_tuple(assertions.required("response_has_keys", f"{location}.assertions"), f"{location}.assertions.response_has_keys"),
        frozenset(_string_tuple(assertions.required("allowed_tools", f"{location}.assertions"), f"{location}.assertions.allowed_tools")),
        _string_tuple(assertions.required("reference_reads", f"{location}.assertions"), f"{location}.assertions.reference_reads"),
    )


def _any_equals(entry: JsonObject, index: int, location: str) -> AnyEquals:
    item_location = f"{location}.assertions.response_any_equals[{index}]"
    return AnyEquals(_string_tuple(entry.required("paths", item_location), f"{item_location}.paths"), entry.required("equals", item_location))


def _discovery(entry: JsonObject, index: int) -> Discovery:
    location = f"OpenCode preflight[{index}]"
    return Discovery(expect_string(entry.required("name", location), f"{location}.name"), expect_string(entry.required("location", location), f"{location}.location"))


def _stream_event(value: JsonValue, index: int) -> StreamEvent:
    location = f"NDJSON event {index}"
    event = expect_object(value, location)
    part = event.find("part")
    match part.value:
        case JsonObject() as parsed_part:
            return StreamEvent(expect_string(event.required("type", location), f"{location}.type"), parsed_part)
        case None:
            return StreamEvent(expect_string(event.required("type", location), f"{location}.type"), None)
        case bool() | int() | float() | str() | JsonArray():
            raise BoundaryError(f"{location}.part", "expected object or null")
        case unreachable:
            assert_never(unreachable)


def _optional_array(value: JsonObject, key: str, location: str) -> JsonArray:
    field = value.find(key)
    return expect_array(field.value, f"{location}.{key}") if field.present else JsonArray(())


def _string_tuple(value: JsonValue, location: str) -> tuple[str, ...]:
    array = expect_array(value, location)
    return tuple(expect_string(item, f"{location}[{index}]") for index, item in enumerate(array.values))
