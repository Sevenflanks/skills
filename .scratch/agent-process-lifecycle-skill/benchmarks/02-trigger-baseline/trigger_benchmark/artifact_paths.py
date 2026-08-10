from __future__ import annotations

import re
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Final


_COMPONENT: Final = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}\Z")


@dataclass(frozen=True, slots=True)
class ArtifactPathError(ValueError):
    component: str
    value: str

    def __str__(self) -> str:
        return f"artifact path {self.component} is unsafe: {self.value!r}"


@dataclass(frozen=True, slots=True)
class StreamPaths:
    stdout: str
    stderr: str


def version_paths() -> StreamPaths:
    return StreamPaths("logs/v.out", "logs/v.err")


def preflight_paths(variant_id: str, attempt: int) -> StreamPaths:
    variant = _component("variant_id", variant_id)
    number = _attempt(attempt)
    return StreamPaths(f"logs/p-{variant}-{number}.out", f"logs/p-{variant}-{number}.err")


def trial_paths(fixture_id: str) -> StreamPaths:
    fixture = _component("fixture_id", fixture_id)
    return StreamPaths(f"logs/t-{fixture}.out", f"logs/t-{fixture}.err")


def ensure_unique_destinations(streams: Iterable[StreamPaths]) -> None:
    destinations: set[str] = set()
    for stream in streams:
        for destination in (stream.stdout, stream.stderr):
            if destination in destinations:
                raise ArtifactPathError("destination", destination)
            destinations.add(destination)


def _component(name: str, value: str) -> str:
    if not isinstance(value, str):
        raise ArtifactPathError(name, repr(value))
    if _COMPONENT.fullmatch(value) is None:
        raise ArtifactPathError(name, value)
    return value


def _attempt(value: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ArtifactPathError("attempt", str(value))
    return value
