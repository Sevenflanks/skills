from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from .evidence_format import EvidenceValidationError, JsonValue, hash_mapping, integer, mapping, number, phase, sha256, signature, string
from .models import RunPhase
from .trial_contract import execution_contract, observed_executable


@dataclass(frozen=True, slots=True)
class ReferenceManifest:
    manifest_path: Path
    sha256: str
    expected_phase: RunPhase


@dataclass(frozen=True, slots=True)
class ManifestParity:
    environment_signature: str
    execution_signature: str
    execution_parity_signature: str
    source_signature: str


@dataclass(frozen=True, slots=True)
class StaticManifestParity:
    execution_signature: str
    execution_parity_signature: str
    source_signature: str


def expected_reference_phase(phase_value: RunPhase) -> RunPhase | None:
    match phase_value:
        case RunPhase.FIXED_BASE:
            return RunPhase.CALIBRATION
        case RunPhase.TARGETED:
            return RunPhase.FIXED_BASE
        case RunPhase.CALIBRATION | RunPhase.EXPLORATORY:
            return None


def reference_record(manifest: dict[str, JsonValue], phase_value: RunPhase, benchmark_root: Path) -> ReferenceManifest | None:
    expected_phase = expected_reference_phase(phase_value)
    value = manifest.get("reference_manifest")
    if expected_phase is None:
        if value is not None:
            raise EvidenceValidationError("calibration and exploratory evidence must not reference another manifest")
        return None
    if value is None:
        raise EvidenceValidationError("gated evidence requires a reference manifest record")
    document = mapping(value, "reference_manifest")
    if set(document) != {"path", "sha256", "expected_phase"}:
        raise EvidenceValidationError("reference manifest record has missing or unauthorized fields")
    path_value = string(document.get("path"), "reference_manifest.path")
    resolved = _normalized_manifest_path(path_value, benchmark_root)
    expected_hash = string(document.get("sha256"), "reference_manifest.sha256")
    if sha256(resolved) != expected_hash:
        raise EvidenceValidationError("reference manifest hash does not match")
    actual_phase = phase(string(document.get("expected_phase"), "reference_manifest.expected_phase"))
    if actual_phase != expected_phase:
        raise EvidenceValidationError("reference manifest phase is not authorized for this run phase")
    return ReferenceManifest(resolved, expected_hash, actual_phase)


def reference_document(manifest_path: Path, expected_phase: RunPhase, benchmark_root: Path) -> dict[str, str]:
    resolved = manifest_path.resolve()
    relative = _relative_manifest_path(resolved, benchmark_root)
    return {"path": relative, "sha256": sha256(resolved), "expected_phase": expected_phase.value}


def manifest_parity(manifest: dict[str, JsonValue]) -> ManifestParity:
    static = static_manifest_parity(manifest)
    environment = mapping(manifest.get("environment_parity"), "environment_parity")
    _require_exact_keys(environment, {"opencode_output", "python", "platform"}, "environment_parity")
    observed_environment = mapping(manifest.get("observed_environment"), "observed_environment")
    observed_opencode = mapping(observed_environment.get("opencode"), "observed_environment.opencode")
    if environment != {
        "opencode_output": string(observed_opencode.get("raw_output"), "observed_environment.opencode.raw_output"),
        "python": string(observed_environment.get("python"), "observed_environment.python"),
        "platform": string(observed_environment.get("platform"), "observed_environment.platform"),
    }:
        raise EvidenceValidationError("environment parity must match the observed environment")
    return ManifestParity(signature(environment), static.execution_signature, signature({"execution_contract": execution_contract(manifest.get("execution_contract")).document(), "execution": _execution_without_workers(manifest), "opencode_command": observed_executable(observed_opencode)}), static.source_signature)


def static_manifest_parity(manifest: dict[str, JsonValue]) -> StaticManifestParity:
    selection = mapping(manifest.get("selection"), "selection")
    workers = integer(selection.get("workers"), "selection.workers")
    if workers < 1:
        raise EvidenceValidationError("selection workers must be positive")
    contract = execution_contract(manifest.get("execution_contract"))
    execution = mapping(manifest.get("execution"), "execution")
    _require_exact_keys(execution, {"workers", "timeout_seconds", "retries", "seed", "permission_policy"}, "execution")
    if integer(execution.get("workers"), "execution.workers") != workers:
        raise EvidenceValidationError("execution workers must match the selected shape")
    if number(execution.get("timeout_seconds"), "execution.timeout_seconds") <= 0 or integer(execution.get("retries"), "execution.retries") < 0:
        raise EvidenceValidationError("execution bounds are invalid")
    integer(execution.get("seed"), "execution.seed")
    policy = mapping(execution.get("permission_policy"), "execution.permission_policy")
    if policy != {"*": "deny", "skill": "allow"}:
        raise EvidenceValidationError("execution permission policy differs from the release protocol")
    sources = hash_mapping(manifest.get("source_hashes"), "source_hashes")
    return StaticManifestParity(
        signature({"contract": contract.document(), "execution": execution}),
        signature({"contract": contract.document(), "execution": _execution_without_workers(manifest)}),
        signature(sources),
    )


def require_exact_parity(current_manifest: dict[str, JsonValue], reference: ManifestParity) -> None:
    current = manifest_parity(current_manifest)
    if current != reference:
        raise EvidenceValidationError("environment, execution, or source parity differs")


def require_static_parity(current_manifest: dict[str, JsonValue], reference: ManifestParity) -> None:
    current = static_manifest_parity(current_manifest)
    if current.execution_signature != reference.execution_signature or current.source_signature != reference.source_signature:
        raise EvidenceValidationError("execution or source parity differs")


def _normalized_manifest_path(value: str, benchmark_root: Path) -> Path:
    candidate = Path(value)
    if candidate.is_absolute():
        raise EvidenceValidationError("reference manifest path must be normalized relative to the benchmark root")
    resolved = (benchmark_root / candidate).resolve()
    expected = _relative_manifest_path(resolved, benchmark_root)
    if value != expected:
        raise EvidenceValidationError("reference manifest path is not normalized")
    return resolved


def _relative_manifest_path(path: Path, benchmark_root: Path) -> str:
    root = benchmark_root.resolve()
    if not path.is_relative_to(root) or path.name != "manifest.json" or not path.is_file():
        raise EvidenceValidationError("reference manifest path is missing or outside the benchmark root")
    return path.relative_to(root).as_posix()


def _require_exact_keys(value: dict[str, JsonValue], expected: set[str], location: str) -> None:
    if set(value) != expected:
        raise EvidenceValidationError(f"{location} has missing or unauthorized fields")


def _execution_without_workers(manifest: dict[str, JsonValue]) -> dict[str, JsonValue]:
    return {key: value for key, value in mapping(manifest.get("execution"), "execution").items() if key != "workers"}
