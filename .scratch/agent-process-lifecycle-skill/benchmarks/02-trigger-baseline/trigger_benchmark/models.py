from __future__ import annotations

import hashlib
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Final


class AttemptStatus(StrEnum):
    TRIGGERED = "triggered"
    NOT_TRIGGERED = "not_triggered"
    INVALID_TIMEOUT = "invalid_timeout"
    INVALID_MALFORMED_STREAM = "invalid_malformed_stream"
    INVALID_PROCESS_FAILURE = "invalid_process_failure"
    INVALID_MISSING_COMPLETION = "invalid_missing_completion"


VALID_STATUSES: Final = frozenset({AttemptStatus.TRIGGERED, AttemptStatus.NOT_TRIGGERED})


class RunPhase(StrEnum):
    CALIBRATION = "calibration"
    FIXED_BASE = "fixed-base"
    TARGETED = "targeted"
    EXPLORATORY = "exploratory"


@dataclass(frozen=True, slots=True)
class Prompt:
    id: str
    label: str
    body: str


@dataclass(frozen=True, slots=True)
class Metadata:
    name: str
    description: str


@dataclass(frozen=True, slots=True)
class Variant:
    id: str
    skill_name: str
    description: str
    skill_path: str


@dataclass(frozen=True, slots=True)
class Specification:
    prompts: tuple[Prompt, ...]
    variants: tuple[Variant, ...]


@dataclass(frozen=True, slots=True)
class RunShape:
    phase: RunPhase
    variants: tuple[Variant, ...]
    prompts: tuple[Prompt, ...]
    runs_per_query: int
    workers: int


@dataclass(frozen=True, slots=True)
class RunOptions:
    phase: RunPhase
    runs_per_query: int
    workers: int
    timeout_seconds: float
    retries: int
    seed: int
    output_directory: Path
    model: str
    variant_ids: tuple[str, ...]
    prompt_ids: tuple[str, ...]
    reference_manifest: Path | None


@dataclass(frozen=True, slots=True)
class StreamResult:
    stream_is_valid: bool
    candidate_selected: bool
    invalid_status: AttemptStatus | None
    tool_uses: tuple[str, ...]
    non_skill_tool_uses: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class TrialRecord:
    variant_id: str
    prompt_id: str
    label: str
    logical_run: int
    attempt: int
    status: AttemptStatus
    triggered: bool | None
    candidate_selected: bool
    command: tuple[str, ...]
    return_code: int | None
    duration_seconds: float
    stdout_sha256: str
    stderr_sha256: str
    stdout_path: str = ""
    stderr_path: str = ""
    tool_uses: tuple[str, ...] = ()
    non_skill_tool_uses: tuple[str, ...] = ()
    fixture_id: str = ""
    fixture_candidate_name: str = ""

    @classmethod
    def valid(cls, variant_id: str, prompt_id: str, label: str, logical_run: int, attempt: int, triggered: bool, *, tool_uses: tuple[str, ...] = (), non_skill_tool_uses: tuple[str, ...] = ()) -> TrialRecord:
        status = AttemptStatus.TRIGGERED if triggered else AttemptStatus.NOT_TRIGGERED
        return cls(variant_id, prompt_id, label, logical_run, attempt, status, triggered, triggered, (), 0, 0.0, "", "", tool_uses=tool_uses, non_skill_tool_uses=non_skill_tool_uses)

    @classmethod
    def invalid(cls, variant_id: str, prompt_id: str, label: str, logical_run: int, attempt: int, status: AttemptStatus, *, candidate_selected: bool, tool_uses: tuple[str, ...] = (), non_skill_tool_uses: tuple[str, ...] = ()) -> TrialRecord:
        return cls(variant_id, prompt_id, label, logical_run, attempt, status, None, candidate_selected, (), None, 0.0, "", "", tool_uses=tool_uses, non_skill_tool_uses=non_skill_tool_uses)

    @classmethod
    def from_completed_process(
        cls,
        variant_id: str,
        prompt_id: str,
        label: str,
        logical_run: int,
        attempt: int,
        command: tuple[str, ...],
        stdout: str,
        stderr: str,
        return_code: int,
        duration_seconds: float,
        candidate_name: str,
    ) -> TrialRecord:
        from .events import classify_ndjson

        stdout_hash = hashlib.sha256(stdout.encode()).hexdigest()
        stderr_hash = hashlib.sha256(stderr.encode()).hexdigest()
        stream = classify_ndjson(stdout, candidate_name)
        if return_code != 0:
            return cls(variant_id, prompt_id, label, logical_run, attempt, AttemptStatus.INVALID_PROCESS_FAILURE, None, stream.candidate_selected, command, return_code, duration_seconds, stdout_hash, stderr_hash, tool_uses=stream.tool_uses, non_skill_tool_uses=stream.non_skill_tool_uses)
        if not stream.stream_is_valid:
            return cls(variant_id, prompt_id, label, logical_run, attempt, stream.invalid_status or AttemptStatus.INVALID_MISSING_COMPLETION, None, stream.candidate_selected, command, return_code, duration_seconds, stdout_hash, stderr_hash, tool_uses=stream.tool_uses, non_skill_tool_uses=stream.non_skill_tool_uses)
        status = AttemptStatus.TRIGGERED if stream.candidate_selected else AttemptStatus.NOT_TRIGGERED
        return cls(variant_id, prompt_id, label, logical_run, attempt, status, stream.candidate_selected, stream.candidate_selected, command, return_code, duration_seconds, stdout_hash, stderr_hash, tool_uses=stream.tool_uses, non_skill_tool_uses=stream.non_skill_tool_uses)

    @property
    def is_valid(self) -> bool:
        return self.status in VALID_STATUSES
