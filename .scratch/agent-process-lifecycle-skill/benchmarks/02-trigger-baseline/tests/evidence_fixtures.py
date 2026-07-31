from __future__ import annotations

import hashlib
import json
import platform
from dataclasses import replace
from pathlib import Path

from trigger_benchmark.evidence import MANIFEST_CONTRACT, MANIFEST_SCHEMA_VERSION, source_hashes_for
from trigger_benchmark.evidence_format import JsonArray, JsonObject, json_array, json_object
from trigger_benchmark.execution import RunExecutionPlan, VersionCapture
from trigger_benchmark.models import Prompt, RunOptions, RunPhase, RunShape, TrialRecord, Variant
from trigger_benchmark.spec import load_specification


BENCHMARK_ROOT = Path(__file__).resolve().parents[1]


def make_plan(phase: RunPhase, *, prompt_ids: tuple[str, ...] = ()) -> RunExecutionPlan:
    specification = load_specification(BENCHMARK_ROOT)
    variants: tuple[Variant, ...]
    prompts: tuple[Prompt, ...]
    runs: int
    if phase == RunPhase.TARGETED:
        variants = (specification.variants[1],)
        prompts = tuple(prompt for prompt in specification.prompts if prompt.id in prompt_ids)
        runs = 7
    else:
        variants = specification.variants
        prompts = specification.prompts
        runs = 3
    options = RunOptions(phase, runs, 1, 1.0, 0, 1, BENCHMARK_ROOT / "unused", "test-model", (), prompt_ids, None)
    return RunExecutionPlan(BENCHMARK_ROOT, options, specification, variants, prompts)


def make_manifest_template(plan: RunExecutionPlan) -> JsonObject:
    version_stdout = "opencode test"
    return json_object({
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "contract": MANIFEST_CONTRACT,
        "generated_at_utc": "2026-07-28T00:00:00+00:00",
        "evidence_phase": plan.options.phase.value,
        "selection": json_object({"variants": json_array(variant.id for variant in plan.variants), "prompts": json_array(prompt.id for prompt in plan.prompts), "runs_per_query": plan.options.runs_per_query, "workers": plan.options.workers, "timeout_seconds": plan.options.timeout_seconds, "retries": plan.options.retries, "seed": plan.options.seed}),
        "execution_contract": json_object({"model": plan.options.model, "agent": "build", "format": "json", "pure": True, "python_major_minor": f"{platform.python_version_tuple()[0]}.{platform.python_version_tuple()[1]}"}),
        "execution": json_object({"workers": plan.options.workers, "timeout_seconds": plan.options.timeout_seconds, "retries": plan.options.retries, "seed": plan.options.seed, "permission_policy": json_object({"*": "deny", "skill": "allow"})}),
        "environment_parity": json_object({"opencode_output": version_stdout, "python": platform.python_version(), "platform": platform.platform()}),
        "observed_environment": json_object({"opencode": json_object({"command": json_array(("opencode", "--version")), "return_code": 0, "raw_output": version_stdout, "stdout_path": "logs/environment-opencode-version.stdout.txt", "stderr_path": "logs/environment-opencode-version.stderr.txt", "stdout_sha256": hashlib.sha256(version_stdout.encode()).hexdigest(), "stderr_sha256": hashlib.sha256(b"").hexdigest()}), "python": platform.python_version(), "platform": platform.platform()}),
        "source_hashes": json_object({}),
        "preflight": json_array(()),
        "reference_manifest": None,
    })


def write_evidence(root: Path, manifest: JsonObject, shape: RunShape) -> None:
    root.mkdir(parents=True)
    logs = root / "logs"
    logs.mkdir()
    version_stdout = logs / "environment-opencode-version.stdout.txt"
    version_stderr = logs / "environment-opencode-version.stderr.txt"
    version_stdout.write_text("opencode test", encoding="utf-8")
    version_stderr.write_text("", encoding="utf-8")
    preflight: JsonArray = []
    for variant in shape.variants:
        stdout = logs / f"preflight-{variant.id}.stdout.txt"
        stderr = logs / f"preflight-{variant.id}.stderr.txt"
        fixture_id = f"preflight-{variant.id}"
        candidate_location = root / "fixtures" / fixture_id / ".opencode" / "skills" / variant.skill_name / "SKILL.md"
        stdout.write_text(_preflight_stream(variant, candidate_location), encoding="utf-8")
        stderr.write_text("", encoding="utf-8")
        preflight.append(json_object({"variant_id": variant.id, "fixture_id": fixture_id, "command": json_array(("opencode", "debug", "skill", "--pure")), "return_code": 0, "fixture_candidate_count": 1, "candidate_name": variant.skill_name, "candidate_location": str(candidate_location.resolve()), "stdout_path": f"logs/{stdout.name}", "stderr_path": f"logs/{stderr.name}", "stdout_sha256": hash_file(stdout), "stderr_sha256": hash_file(stderr)}))
    records = _records_for_evidence(root, shape, logs)
    trials = root / "trials.ndjson"
    trials.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
    manifest["evidence_phase"] = shape.phase.value
    manifest["selection"] = json_object({"variants": json_array(variant.id for variant in shape.variants), "prompts": json_array(prompt.id for prompt in shape.prompts), "runs_per_query": shape.runs_per_query, "workers": shape.workers})
    manifest["execution"] = json_object({"workers": shape.workers, "timeout_seconds": 1.0, "retries": 0, "seed": 1, "permission_policy": json_object({"*": "deny", "skill": "allow"})})
    manifest["preflight"] = preflight
    manifest["source_hashes"] = json_object(source_hashes_for(BENCHMARK_ROOT, load_specification(BENCHMARK_ROOT)))
    manifest["artifact_hashes"] = json_object({str(path.relative_to(root)).replace("\\", "/"): hash_file(path) for path in root.rglob("*") if path.is_file()})
    (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")


def make_reference_record(manifest_path: Path, phase: RunPhase) -> JsonObject:
    return json_object({"path": manifest_path.resolve().relative_to(BENCHMARK_ROOT).as_posix(), "sha256": hash_file(manifest_path), "expected_phase": phase.value})


def make_version_capture() -> VersionCapture:
    return VersionCapture(("opencode", "--version"), 0, "opencode test", "")


def make_valid_records(shape: RunShape) -> tuple[TrialRecord, ...]:
    return tuple(TrialRecord.valid(variant.id, prompt.id, prompt.label, logical_run, 1, prompt.label == "positive") for variant in shape.variants for prompt in shape.prompts for logical_run in range(1, shape.runs_per_query + 1))


def hash_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _records_for_evidence(root: Path, shape: RunShape, logs: Path) -> list[JsonObject]:
    logs.mkdir(parents=True, exist_ok=True)
    records: list[JsonObject] = []
    for variant in shape.variants:
        for prompt in shape.prompts:
            for logical_run in range(1, shape.runs_per_query + 1):
                triggered = variant.id == "candidate" and prompt.label == "positive"
                attempt_number = len(records) + 1
                fixture_id = f"fixture-{attempt_number}"
                stdout = logs / f"trial-{attempt_number}.stdout.ndjson"
                stderr = logs / f"trial-{attempt_number}.stderr.txt"
                stream = _stream(variant.skill_name, triggered)
                stdout.write_text(stream, encoding="utf-8")
                stderr.write_text("", encoding="utf-8")
                command = ("opencode", "run", "--pure", "--format", "json", "--model", "test-model", "--agent", "build", "--dir", str((root / "fixtures" / fixture_id).resolve()), prompt.body)
                record = TrialRecord.from_completed_process(variant.id, prompt.id, prompt.label, logical_run, 1, command, stream, "", 0, 1.0, variant.skill_name)
                records.append(_record_document(replace(record, stdout_path=f"logs/{stdout.name}", stderr_path=f"logs/{stderr.name}", stdout_sha256=hash_file(stdout), stderr_sha256=hash_file(stderr)), fixture_id, variant.skill_name))
    return records


def _record_document(record: TrialRecord, fixture_id: str, fixture_candidate_name: str) -> JsonObject:
    return json_object({"variant_id": record.variant_id, "prompt_id": record.prompt_id, "label": record.label, "logical_run": record.logical_run, "attempt": record.attempt, "status": record.status.value, "triggered": record.triggered, "candidate_selected": record.candidate_selected, "command": json_array(record.command), "return_code": record.return_code, "duration_seconds": record.duration_seconds, "stdout_sha256": record.stdout_sha256, "stderr_sha256": record.stderr_sha256, "stdout_path": record.stdout_path, "stderr_path": record.stderr_path, "tool_uses": json_array(record.tool_uses), "non_skill_tool_uses": json_array(record.non_skill_tool_uses), "fixture_id": fixture_id, "fixture_candidate_name": fixture_candidate_name})


def _stream(skill_name: str, triggered: bool) -> str:
    tool_use = f'{{"type":"tool_use","part":{{"type":"tool","tool":"skill","state":{{"status":"completed","input":{{"name":"{skill_name}"}}}}}}}}\n' if triggered else ""
    return tool_use + '{"type":"step_finish","part":{"type":"step-finish"}}'


def _preflight_stream(variant: Variant, candidate_location: Path) -> str:
    return json.dumps([{"name": variant.skill_name, "description": variant.description, "location": str(candidate_location.resolve())}])
