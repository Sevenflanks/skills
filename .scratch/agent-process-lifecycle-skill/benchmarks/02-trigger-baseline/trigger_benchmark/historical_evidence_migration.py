from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Final

from .artifact_paths import StreamPaths, preflight_paths, trial_paths, version_paths
from .evidence_format import JsonValue

_SEARCH_AREAS: Final = ("results", "reference")


@dataclass(frozen=True, slots=True)
class MigrationError(Exception):
    message: str

    def __str__(self) -> str:
        return self.message


@dataclass(frozen=True, slots=True)
class _Move:
    source: Path
    destination: Path
    sha256: str


@dataclass(frozen=True, slots=True)
class _Write:
    path: Path
    content: bytes
    expected_prior: bytes | None


@dataclass(frozen=True, slots=True)
class MigrationReceipt:
    raw_files: int
    documents: int
    evidence_roots: int
    raw_sha256_before: dict[str, str]
    raw_sha256_after: dict[str, str]


@dataclass(frozen=True, slots=True)
class MigrationPlan:
    benchmark_root: Path
    moves: tuple[_Move, ...]
    writes: tuple[_Write, ...]
    receipt: MigrationReceipt


def plan_migration(benchmark_root: Path) -> MigrationPlan:
    """Validate and prepare every tracked historical evidence mutation without writing."""
    root = benchmark_root.resolve()
    manifests = _manifests(root)
    documents = {path: _document(path) for path in manifests}
    newlines = {path: _newline(path.read_bytes()) for path in manifests}
    changes: dict[Path, dict[str, str]] = {}
    trial_contents: dict[Path, bytes] = {}
    moves: list[_Move] = []
    for path, manifest in documents.items():
        evidence_root = path.parent
        _validate_artifacts(evidence_root, manifest)
        stream_changes, trials = _rewrite_evidence(evidence_root, manifest)
        changes[evidence_root] = stream_changes
        moves.extend(_moves(evidence_root, stream_changes))
        if trials is not None:
            trial_contents[evidence_root / "trials.ndjson"] = trials
    _validate_moves(moves)
    _rewrite_manifests(root, documents, changes, trial_contents, newlines)
    writes = _writes(documents, trial_contents, newlines) + _gate_writes(root, documents, newlines)
    before = {move.destination.relative_to(root).as_posix(): move.sha256 for move in moves}
    receipt = MigrationReceipt(len(moves), len(writes), len(documents), before, dict(before))
    return MigrationPlan(root, tuple(moves), tuple(writes), receipt)


def apply_migration(plan: MigrationPlan) -> MigrationReceipt:
    """Apply a prevalidated plan; repeating an empty plan is a no-op."""
    _validate_moves(plan.moves)
    _validate_writes(plan.writes)
    for move in plan.moves:
        move.source.replace(move.destination)
    for write in plan.writes:
        write.path.write_bytes(write.content)
    after = {move.destination.relative_to(plan.benchmark_root).as_posix(): _sha256(move.destination) for move in plan.moves}
    expected = {move.destination.relative_to(plan.benchmark_root).as_posix(): move.sha256 for move in plan.moves}
    if after != expected:
        raise MigrationError("raw artifact hash changed during migration")
    return MigrationReceipt(plan.receipt.raw_files, plan.receipt.documents, plan.receipt.evidence_roots, expected, after)


def _manifests(benchmark_root: Path) -> tuple[Path, ...]:
    manifests = tuple(sorted(path for area in _SEARCH_AREAS if (benchmark_root / area).is_dir() for path in (benchmark_root / area).rglob("manifest.json")))
    if not manifests:
        raise MigrationError("no evidence manifests found under results or reference")
    return manifests


def _document(path: Path) -> dict[str, JsonValue]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MigrationError(f"cannot read {path}") from error
    if not isinstance(value, dict):
        raise MigrationError(f"{path} must contain a JSON object")
    return value


def _validate_artifacts(root: Path, manifest: dict[str, JsonValue]) -> None:
    hashes = _mapping(manifest.get("artifact_hashes"), "artifact_hashes")
    actual = {path.relative_to(root).as_posix(): _sha256(path) for path in root.rglob("*") if path.is_file() and path.name != "manifest.json"}
    if hashes != actual:
        raise MigrationError(f"artifact hashes do not match {root}")


def _rewrite_evidence(root: Path, manifest: dict[str, JsonValue]) -> tuple[dict[str, str], bytes | None]:
    changes: dict[str, str] = {}
    environment = _mapping(manifest.get("observed_environment"), "observed_environment")
    _rewrite_stream(root, _mapping(environment.get("opencode"), "observed_environment.opencode"), version_paths(), changes)
    for entry in _objects(manifest.get("preflight"), "preflight"):
        variant = _string(entry.get("variant_id"), "preflight.variant_id")
        attempts = entry.get("attempts")
        if attempts is None:
            _rewrite_stream(root, entry, preflight_paths(variant, 1), changes)
            continue
        for position, attempt in enumerate(_objects(attempts, "preflight.attempts"), start=1):
            if _integer(attempt.get("attempt"), "preflight.attempt") != position:
                raise MigrationError("preflight attempt does not match its manifest position")
            _rewrite_stream(root, attempt, preflight_paths(variant, position), changes)
        if "stdout_path" in entry:
            successful = _integer(entry.get("successful_attempt"), "preflight.successful_attempt")
            _rewrite_stream(root, entry, preflight_paths(variant, successful), changes)
    records, newline = _records(root / "trials.ndjson")
    for record in records:
        _rewrite_stream(root, record, trial_paths(_string(record.get("fixture_id"), "trial.fixture_id")), changes)
    content = _serialize_records(records, newline)
    return changes, content if content != (root / "trials.ndjson").read_bytes() else None


def _rewrite_stream(root: Path, document: dict[str, JsonValue], paths: StreamPaths, changes: dict[str, str]) -> None:
    for field, destination in (("stdout_path", paths.stdout), ("stderr_path", paths.stderr)):
        source = _string(document.get(field), field)
        declared = PurePosixPath(source)
        components = source.split("/")
        if (
            "\\" in source
            or declared.is_absolute()
            or source != declared.as_posix()
            or any(component in {"", ".", ".."} for component in components)
            or not declared.parts
            or declared.parts[0] != "logs"
        ):
            raise MigrationError(f"declared stream does not match {source}")
        declared_source_path = root
        for component in declared.parts:
            declared_source_path /= component
            if declared_source_path.is_symlink():
                raise MigrationError(f"declared stream does not match {source}")
        source_path = declared_source_path.resolve()
        expected = _string(document.get(field.replace("path", "sha256")), field.replace("path", "sha256"))
        if not source_path.is_relative_to((root / "logs").resolve()) or not source_path.is_file() or _sha256(source_path) != expected:
            raise MigrationError(f"declared stream does not match {source}")
        previous = changes.setdefault(source, destination)
        if previous != destination:
            raise MigrationError(f"one source maps to multiple destinations: {source}")
        document[field] = destination


def _records(path: Path) -> tuple[list[dict[str, JsonValue]], bytes]:
    content = path.read_bytes()
    try:
        lines = content.decode("utf-8").splitlines()
        records = [value for line in lines if line and isinstance(value := json.loads(line), dict)]
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MigrationError("trials.ndjson is invalid") from error
    if len(records) != len(lines):
        raise MigrationError("trials.ndjson must contain only JSON objects")
    return records, b"\r\n" if b"\r\n" in content else b"\n"


def _serialize_records(records: list[dict[str, JsonValue]], newline: bytes) -> bytes:
    return newline.join(json.dumps(record).encode("utf-8") for record in records) + newline


def _moves(root: Path, changes: dict[str, str]) -> list[_Move]:
    return [_Move(root / source, root / destination, _sha256(root / source)) for source, destination in changes.items() if source != destination]


def _validate_moves(moves: list[_Move] | tuple[_Move, ...]) -> None:
    sources = {move.source for move in moves}
    destinations: set[Path] = set()
    for move in moves:
        if move.source.is_symlink() or not move.source.is_file() or _sha256(move.source) != move.sha256:
            raise MigrationError(f"raw source changed: {move.source}")
        if move.destination in destinations or (_path_is_occupied(move.destination) and move.destination not in sources):
            raise MigrationError(f"raw destination collision: {move.destination}")
        destinations.add(move.destination)


def _path_is_occupied(path: Path) -> bool:
    return path.is_symlink() or path.exists()


def _rewrite_manifests(benchmark_root: Path, documents: dict[Path, dict[str, JsonValue]], changes: dict[Path, dict[str, str]], trials: dict[Path, bytes], newlines: dict[Path, bytes]) -> None:
    pending = dict(documents)
    rendered: dict[Path, bytes] = {}
    while pending:
        ready = [path for path, manifest in pending.items() if _reference_path(manifest, benchmark_root) not in pending]
        if not ready:
            raise MigrationError("reference manifests form a cycle")
        for path in sorted(ready):
            manifest = pending.pop(path)
            reference = _reference_path(manifest, benchmark_root)
            if reference is not None:
                if reference not in rendered:
                    raise MigrationError(f"reference manifest is outside migration roots: {reference}")
                _mapping(manifest.get("reference_manifest"), "reference_manifest")["sha256"] = _sha256_bytes(rendered[reference])
            manifest["artifact_hashes"] = _artifact_hashes(path.parent, manifest, changes[path.parent], trials)
            rendered[path] = _json_bytes(manifest, newlines[path])
    for path, content in rendered.items():
        documents[path] = json.loads(content)


def _reference_path(manifest: dict[str, JsonValue], benchmark_root: Path) -> Path | None:
    reference = manifest.get("reference_manifest")
    if reference is None:
        return None
    value = _mapping(reference, "reference_manifest")
    return (benchmark_root / _string(value.get("path"), "reference_manifest.path")).resolve()


def _artifact_hashes(root: Path, manifest: dict[str, JsonValue], changes: dict[str, str], trials: dict[Path, bytes]) -> dict[str, str]:
    original = _mapping(manifest.get("artifact_hashes"), "artifact_hashes")
    result: dict[str, str] = {}
    for relative in original:
        target = changes.get(relative, relative)
        content = trials.get(root / target)
        result[target] = _sha256_bytes(content) if content is not None else _sha256(root / relative)
    return result


def _writes(documents: dict[Path, dict[str, JsonValue]], trials: dict[Path, bytes], newlines: dict[Path, bytes]) -> list[_Write]:
    writes = [_planned_write(path, content) for path, content in trials.items()]
    writes.extend(_planned_write(path, _json_bytes(document, newlines[path])) for path, document in documents.items())
    return [write for write in writes if write is not None]


def _gate_writes(benchmark_root: Path, manifests: dict[Path, dict[str, JsonValue]], newlines: dict[Path, bytes]) -> list[_Write]:
    writes: list[_Write] = []
    for path in sorted((benchmark_root / "results").rglob("worker-calibration.json")):
        document = _document(path)
        newline = _newline(path.read_bytes())
        if _rewrite_calibration_hashes(document, path.parent, manifests, newlines):
            write = _planned_write(path, _json_bytes(document, newline))
            if write is not None:
                writes.append(write)
    for path in sorted((benchmark_root / "results").rglob("decision.json")):
        document = _document(path)
        newline = _newline(path.read_bytes())
        if _rewrite_decision_hashes(document, path.parent.parent, manifests, newlines):
            write = _planned_write(path, _json_bytes(document, newline))
            if write is not None:
                writes.append(write)
            report_newline = _newline(path.with_name("report.md").read_bytes())
            report = _planned_write(path.with_name("report.md"), _report(document).replace("\n", report_newline.decode()).encode("utf-8"))
            if report is not None:
                writes.append(report)
    return writes


def _planned_write(path: Path, content: bytes) -> _Write | None:
    expected_prior = path.read_bytes() if path.exists() else None
    return None if expected_prior == content else _Write(path, content, expected_prior)


def _validate_writes(writes: tuple[_Write, ...]) -> None:
    for write in writes:
        if write.expected_prior is None:
            if _path_is_occupied(write.path):
                raise MigrationError(f"write target changed: {write.path}")
            continue
        if write.path.is_symlink() or not write.path.is_file() or write.path.read_bytes() != write.expected_prior:
            raise MigrationError(f"write target changed: {write.path}")


def _rewrite_calibration_hashes(document: dict[str, JsonValue], gate_root: Path, manifests: dict[Path, dict[str, JsonValue]], newlines: dict[Path, bytes]) -> bool:
    changed = False
    for entry in _objects(document.get("entries"), "worker-calibration.entries") + ([ _mapping(document.get("selected"), "worker-calibration.selected") ] if document.get("selected") is not None else []):
        path = gate_root / _string(entry.get("run_path"), "worker-calibration.run_path") / "manifest.json"
        if path not in manifests:
            raise MigrationError(f"calibration references unknown manifest: {path}")
        digest = _sha256_bytes(_json_bytes(manifests[path], newlines[path]))
        if entry.get("manifest_sha256") != digest:
            entry["manifest_sha256"] = digest
            changed = True
    return changed


def _rewrite_decision_hashes(document: dict[str, JsonValue], gate_root: Path, manifests: dict[Path, dict[str, JsonValue]], newlines: dict[Path, bytes]) -> bool:
    changed = False
    hashes = _mapping(document.get("artifact_hashes"), "decision.artifact_hashes")
    for relative in tuple(hashes):
        if not relative.endswith("manifest.json"):
            continue
        path = gate_root / relative
        if path not in manifests:
            raise MigrationError(f"decision references unknown manifest: {path}")
        digest = _sha256_bytes(_json_bytes(manifests[path], newlines[path]))
        if hashes[relative] != digest:
            hashes[relative] = digest
            changed = True
    return changed


def _report(document: dict[str, JsonValue]) -> str:
    return "\n".join(["# Routing Release Gate", "", *[f"- {key}: `{json.dumps(value, sort_keys=True)}`" for key, value in document.items()]]) + "\n"


def _mapping(value: JsonValue | None, location: str) -> dict[str, JsonValue]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise MigrationError(f"{location} must be an object")
    return value


def _objects(value: JsonValue | None, location: str) -> list[dict[str, JsonValue]]:
    if not isinstance(value, list):
        raise MigrationError(f"{location} must be a list")
    return [_mapping(item, location) for item in value]


def _string(value: JsonValue | None, location: str) -> str:
    if not isinstance(value, str):
        raise MigrationError(f"{location} must be a string")
    return value


def _integer(value: JsonValue | None, location: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise MigrationError(f"{location} must be an integer")
    return value


def _sha256(path: Path) -> str:
    return _sha256_bytes(path.read_bytes())


def _sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def _json_bytes(value: dict[str, JsonValue], newline: bytes) -> bytes:
    return (json.dumps(value, indent=2) + "\n").replace("\n", newline.decode("utf-8")).encode("utf-8")


def _newline(content: bytes) -> bytes:
    return b"\r\n" if b"\r\n" in content else b"\n"
