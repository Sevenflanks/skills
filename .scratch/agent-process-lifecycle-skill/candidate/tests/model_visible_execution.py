from __future__ import annotations

import hashlib
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import assert_never

from model_visible_contract import AnyEquals, BoundaryError, Case, InvalidModelResponse, ModelResponse, StreamEvent, parse_events, parse_preflight, parse_response
from model_visible_json import JsonArray, JsonObject, JsonValue, expect_object, expect_string, json_text, lookup, portable, record, reference_paths, values_equal


@dataclass(frozen=True, slots=True)
class ExecutionConfig:
    skill_directory: Path
    skill_name: str
    model: str
    opencode: str


@dataclass(frozen=True, slots=True)
class ToolEvent:
    index: int
    name: str
    status: str | None
    input: JsonObject

    def evidence(self) -> JsonObject:
        return record(("index", self.index), ("name", self.name), ("status", self.status), ("input", self.input))


@dataclass(frozen=True, slots=True)
class RunObservation:
    valid_stream: bool
    candidate_loaded: bool
    tool_events: tuple[ToolEvent, ...]
    reference_reads: tuple[str, ...]
    response: ModelResponse | InvalidModelResponse


@dataclass(frozen=True, slots=True)
class CaseResult:
    identifier: str
    observation: RunObservation
    assertions: tuple[str, ...]

    def evidence(self) -> JsonObject:
        response = _response_text(self.observation.response)
        return record(
            ("identifier", self.identifier),
            ("valid_stream", self.observation.valid_stream),
            ("candidate_loaded", self.observation.candidate_loaded),
            ("tool_events", JsonArray(tuple(event.evidence() for event in self.observation.tool_events))),
            ("tool_names", JsonArray(tuple(event.name for event in self.observation.tool_events))),
            ("reference_reads", JsonArray(self.observation.reference_reads)),
            ("response", response),
            ("response_sha256", hashlib.sha256(response.encode()).hexdigest()),
            ("assertions", JsonArray(self.assertions)),
            ("passed", not self.assertions),
        )


def run_case(case: Case, config: ExecutionConfig) -> CaseResult:
    stream = _with_fixture(case.prompt, config)
    events = parse_events(stream.stdout)
    tool_events = _tool_events(events, stream.candidate_directory)
    response = parse_response("\n".join(_text(event) for event in events if _text(event)))
    observation = RunObservation(
        stream.returncode == 0 and _finished(events),
        _candidate_loaded(tool_events, config.skill_name),
        tool_events,
        tuple(path for event in tool_events for path in reference_paths(event.input)),
        response,
    )
    return CaseResult(case.identifier, observation, _grade(case, observation))


@dataclass(frozen=True, slots=True)
class FixtureStream:
    returncode: int
    stdout: str
    candidate_directory: str


def _with_fixture(prompt: str, config: ExecutionConfig) -> FixtureStream:
    with tempfile.TemporaryDirectory(prefix="ticket-16-agent-process-lifecycle-") as temporary_directory:
        project = Path(temporary_directory)
        skill_path = project / ".opencode/skills" / config.skill_name
        shutil.copytree(config.skill_directory, skill_path)
        (project / "opencode.json").write_text('{"permission":{"*":"deny","skill":"allow","read":"allow"}}\n', encoding="utf-8")
        preflight = _command((config.opencode, "debug", "skill", "--pure"), project, 30)
        discovered = parse_preflight(preflight.stdout)
        expected_location = str((skill_path / "SKILL.md").resolve())
        matching = tuple(entry for entry in discovered if entry.name == config.skill_name and entry.location == expected_location)
        if preflight.returncode != 0 or len(matching) != 1:
            raise BoundaryError("OpenCode preflight", "fixture did not discover exactly the candidate skill")
        completed = _command((config.opencode, "run", "--pure", "--format", "json", "--model", config.model, "--agent", "build", "--dir", str(project), prompt), project, 120)
        return FixtureStream(completed.returncode, completed.stdout, str(skill_path.resolve()))


def _command(arguments: tuple[str, ...], cwd: Path, timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(arguments, cwd=cwd, capture_output=True, text=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        return subprocess.CompletedProcess(arguments, 124, _timeout_text(error.stdout), _timeout_text(error.stderr))


def _tool_events(events: tuple[StreamEvent, ...], candidate_directory: str) -> tuple[ToolEvent, ...]:
    collected: list[ToolEvent] = []
    for index, event in enumerate(events):
        if event.part is None or not event.part.contains("tool"):
            continue
        name = expect_string(event.part.required("tool", f"NDJSON event {index}.part"), f"NDJSON event {index}.part.tool")
        state = event.part.find("state").value
        match state:
            case JsonObject() as state_object:
                status = _optional_string(state_object, "status", f"NDJSON event {index}.part.state")
                input_value = _optional_object(state_object, "input", f"NDJSON event {index}.part.state")
            case None:
                status = None
                input_value = JsonObject(())
            case bool() | int() | float() | str() | JsonArray():
                raise BoundaryError(f"NDJSON event {index}.part.state", "expected object or null")
            case unreachable:
                assert_never(unreachable)
        collected.append(ToolEvent(index, name, status, expect_object(portable(input_value, candidate_directory), f"NDJSON event {index}.part.state.input")))
    return tuple(collected)


def _candidate_loaded(events: tuple[ToolEvent, ...], skill_name: str) -> bool:
    return any(event.name == "skill" and event.status == "completed" and event.input.find("name").value == skill_name for event in events)


def _grade(case: Case, observation: RunObservation) -> tuple[str, ...]:
    failures: list[str] = []
    if not observation.valid_stream:
        failures.append("stream was incomplete or command failed")
    if not observation.candidate_loaded:
        failures.append("candidate skill was not completed")
    unexpected_tools = sorted({event.name for event in observation.tool_events} - case.allowed_tools)
    if unexpected_tools:
        failures.append(f"forbidden tools: {', '.join(unexpected_tools)}")
    if observation.reference_reads != case.reference_reads:
        failures.append(f"reference reads {observation.reference_reads!r} did not equal {case.reference_reads!r}")
    match observation.response:
        case ModelResponse(payload=payload):
            failures.extend(_response_failures(case, payload))
        case InvalidModelResponse(reason=reason):
            failures.append(f"response was not a JSON object: {reason}")
        case unreachable:
            assert_never(unreachable)
    return tuple(failures)


def _response_failures(case: Case, payload: JsonObject) -> tuple[str, ...]:
    failures: list[str] = []
    for expected in case.response_equals:
        actual = lookup(payload, expected.path)
        if not actual.found or not values_equal(actual.value, expected.expected):
            failures.append(f"response field {expected.path!r} did not equal its expected value")
    for expected in case.response_any_equals:
        if not _matches_any(payload, expected):
            failures.append(f"none of {expected.paths!r} equaled its expected value")
    for key in case.response_has_keys:
        if not payload.contains(key):
            failures.append(f"response did not include {key!r}")
    return tuple(failures)


def _matches_any(payload: JsonObject, expected: AnyEquals) -> bool:
    return any(found.found and values_equal(found.value, expected.expected) for found in (lookup(payload, path) for path in expected.paths))


def _optional_string(value: JsonObject, key: str, location: str) -> str | None:
    field = value.find(key)
    return expect_string(field.value, f"{location}.{key}") if field.present else None


def _optional_object(value: JsonObject, key: str, location: str) -> JsonObject:
    field = value.find(key)
    return expect_object(field.value, f"{location}.{key}") if field.present else JsonObject(())


def _text(event: StreamEvent) -> str:
    if event.kind != "text" or event.part is None:
        return ""
    field = event.part.find("text")
    return expect_string(field.value, "text event.part.text") if field.present else ""


def _finished(events: tuple[StreamEvent, ...]) -> bool:
    return any(event.kind == "step_finish" and event.part is not None and event.part.find("type").value == "step-finish" for event in events)


def _response_text(response: ModelResponse | InvalidModelResponse) -> str:
    match response:
        case ModelResponse(text=text) | InvalidModelResponse(text=text):
            return text
        case unreachable:
            assert_never(unreachable)


def _timeout_text(value: str | bytes | None) -> str:
    match value:
        case bytes() as bytes_value:
            return bytes_value.decode(errors="replace")
        case str() as text:
            return text
        case None:
            return ""
        case unreachable:
            assert_never(unreachable)
