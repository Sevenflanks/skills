from __future__ import annotations

import hashlib
from dataclasses import dataclass
from enum import StrEnum
from typing import Final


class AttemptStatus(StrEnum):
    TRIGGERED = "triggered"
    NOT_TRIGGERED = "not_triggered"
    INVALID_TIMEOUT = "invalid_timeout"
    INVALID_MALFORMED_STREAM = "invalid_malformed_stream"
    INVALID_PROCESS_FAILURE = "invalid_process_failure"
    INVALID_MISSING_COMPLETION = "invalid_missing_completion"


VALID_STATUSES: Final = frozenset({AttemptStatus.TRIGGERED, AttemptStatus.NOT_TRIGGERED})


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


@dataclass(frozen=True, slots=True)
class Specification:
    prompts: tuple[Prompt, ...]
    variants: tuple[Variant, ...]
    current_metadata: Metadata
    published_skill_path: str


@dataclass(frozen=True, slots=True)
class StreamResult:
    stream_is_valid: bool
    triggered: bool
    invalid_status: AttemptStatus | None


@dataclass(frozen=True, slots=True)
class TrialRecord:
    variant_id: str
    prompt_id: str
    label: str
    logical_run: int
    attempt: int
    status: AttemptStatus
    triggered: bool | None
    command: tuple[str, ...]
    return_code: int | None
    duration_seconds: float
    stdout_sha256: str
    stderr_sha256: str
    stdout_path: str = ""
    stderr_path: str = ""

    @classmethod
    def valid(cls, variant_id: str, prompt_id: str, label: str, logical_run: int, attempt: int, triggered: bool) -> TrialRecord:
        status = AttemptStatus.TRIGGERED if triggered else AttemptStatus.NOT_TRIGGERED
        return cls(variant_id, prompt_id, label, logical_run, attempt, status, triggered, (), 0, 0.0, "", "")

    @classmethod
    def invalid(cls, variant_id: str, prompt_id: str, label: str, logical_run: int, attempt: int, status: AttemptStatus) -> TrialRecord:
        return cls(variant_id, prompt_id, label, logical_run, attempt, status, None, (), None, 0.0, "", "")

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
        if return_code != 0:
            return cls(variant_id, prompt_id, label, logical_run, attempt, AttemptStatus.INVALID_PROCESS_FAILURE, None, command, return_code, duration_seconds, stdout_hash, stderr_hash)
        stream = classify_ndjson(stdout, candidate_name)
        if not stream.stream_is_valid:
            return cls(variant_id, prompt_id, label, logical_run, attempt, stream.invalid_status or AttemptStatus.INVALID_MISSING_COMPLETION, None, command, return_code, duration_seconds, stdout_hash, stderr_hash)
        status = AttemptStatus.TRIGGERED if stream.triggered else AttemptStatus.NOT_TRIGGERED
        return cls(variant_id, prompt_id, label, logical_run, attempt, status, stream.triggered, command, return_code, duration_seconds, stdout_hash, stderr_hash)

    @property
    def is_valid(self) -> bool:
        return self.status in VALID_STATUSES
