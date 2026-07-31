from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from dataclasses import asdict, replace
from pathlib import Path

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))

from trigger_benchmark.evidence import EvidenceValidationError, source_hashes_for, validate_evidence
from trigger_benchmark.models import RunPhase, RunShape, TrialRecord
from trigger_benchmark.release_gate import select_calibration
from trigger_benchmark.spec import load_specification
from evidence_fixtures import make_manifest_template, make_plan, write_evidence


class EvidenceTests(unittest.TestCase):
    def test_evidence_when_raw_stream_matches_record_accepts_all_artifact_and_source_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            evidence_root = Path(temporary_directory)
            write_exploratory_evidence(evidence_root)

            evidence = validate_evidence(evidence_root, BENCHMARK_ROOT, load_specification(BENCHMARK_ROOT))

            self.assertEqual(evidence.records[0].tool_uses, ("skill",))
            self.assertEqual(evidence.records[0].non_skill_tool_uses, ())

    def test_evidence_when_trial_claim_disagrees_with_raw_stdout_rejects_reparsed_stream(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            evidence_root = Path(temporary_directory)
            write_exploratory_evidence(evidence_root)
            trial_path = evidence_root / "trials.ndjson"
            document = json.loads(trial_path.read_text(encoding="utf-8"))
            document["status"] = "not_triggered"
            document["triggered"] = False
            trial_path.write_text(json.dumps(document) + "\n", encoding="utf-8")
            manifest_path = evidence_root / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["artifact_hashes"]["trials.ndjson"] = _hash(trial_path)
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaises(EvidenceValidationError):
                validate_evidence(evidence_root, BENCHMARK_ROOT, load_specification(BENCHMARK_ROOT))

    def test_calibration_when_no_complete_matrix_blocks_without_trigger_outcomes(self) -> None:
        decision = select_calibration(())

        self.assertEqual(decision.exit_code, 1)
        self.assertNotIn("triggered", decision.to_document())

    def test_evidence_when_version_stream_disagrees_with_raw_output_rejects(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_exploratory_evidence(root)
            manifest_path = root / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["observed_environment"]["opencode"]["raw_output"] = "wrong"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaises(EvidenceValidationError):
                validate_evidence(root, BENCHMARK_ROOT, load_specification(BENCHMARK_ROOT))

    def test_evidence_when_preflight_hash_disagrees_rejects(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_exploratory_evidence(root)
            manifest_path = root / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["preflight"][0]["stdout_sha256"] = "0" * 64
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaises(EvidenceValidationError):
                validate_evidence(root, BENCHMARK_ROOT, load_specification(BENCHMARK_ROOT))

    def test_evidence_when_unrelated_discovery_location_is_relative_ignores_global_entry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_exploratory_evidence(root)
            preflight_path = root / "logs" / "preflight.stdout.txt"
            discovery = json.loads(preflight_path.read_text(encoding="utf-8"))
            discovery.append({"name": "global-skill", "description": "outside fixture", "location": "relative/SKILL.md"})
            _replace_preflight_stdout(root, json.dumps(discovery))

            evidence = validate_evidence(root, BENCHMARK_ROOT, load_specification(BENCHMARK_ROOT))

            self.assertTrue(evidence.is_complete)

    def test_evidence_when_preflight_stdout_is_not_the_selected_fixture_candidate_rejects(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        candidate = specification.variants[1]
        for name in ("invalid JSON", "malformed candidate", "empty candidates", "wrong description", "wrong location", "multiple candidates"):
            with self.subTest(case=name), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                write_exploratory_evidence(root)
                expected_location = _candidate_location(root, candidate.skill_name)
                cases = {
                    "invalid JSON": "{",
                    "malformed candidate": json.dumps([{"name": candidate.skill_name, "location": str(expected_location.resolve())}]),
                    "empty candidates": "[]",
                    "wrong description": _preflight_stdout(candidate.skill_name, "wrong description", candidate.skill_name, root=root),
                    "wrong location": _preflight_stdout(candidate.skill_name, candidate.description, "other", root=root),
                    "multiple candidates": _preflight_stdout(candidate.skill_name, candidate.description, candidate.skill_name, root=root, duplicate=True),
                }
                _replace_preflight_stdout(root, cases[name])

                with self.assertRaises(EvidenceValidationError):
                    validate_evidence(root, BENCHMARK_ROOT, specification)

    def test_evidence_when_trial_command_drifts_from_execution_contract_or_prompt_rejects(self) -> None:
        for field, value in (("model", "other-model"), ("prompt", "wrong prompt")):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                write_exploratory_evidence(root)
                trials = root / "trials.ndjson"
                record = json.loads(trials.read_text(encoding="utf-8"))
                if field == "model":
                    command = record["command"]
                    command[6] = value
                else:
                    record["command"][-1] = value
                trials.write_text(json.dumps(record) + "\n", encoding="utf-8")
                update_artifact_hash(root, "trials.ndjson")

                with self.assertRaises(EvidenceValidationError):
                    validate_evidence(root, BENCHMARK_ROOT, load_specification(BENCHMARK_ROOT))

    def test_evidence_when_fixture_identity_or_raw_stream_is_reused_rejects(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        shape = RunShape(RunPhase.CALIBRATION, specification.variants, (specification.prompts[0], specification.prompts[8]), 1, 1)
        for field in ("fixture_id", "stdout_path", "fixture_candidate_name"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory) / "evidence"
                write_evidence(root, make_manifest_template(make_plan(RunPhase.CALIBRATION)), shape)
                trials = root / "trials.ndjson"
                records = [json.loads(line) for line in trials.read_text(encoding="utf-8").splitlines()]
                records[1][field] = "wrong-skill" if field == "fixture_candidate_name" else records[0][field]
                trials.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
                update_artifact_hash(root, "trials.ndjson")

                with self.assertRaises(EvidenceValidationError):
                    validate_evidence(root, BENCHMARK_ROOT, specification)


def write_exploratory_evidence(evidence_root: Path) -> None:
    logs = evidence_root / "logs"
    logs.mkdir()
    stdout_path = logs / "candidate.stdout.ndjson"
    stderr_path = logs / "candidate.stderr.txt"
    stdout = "\n".join(
        (
            '{"type":"tool_use","part":{"type":"tool","tool":"skill","state":{"status":"completed","input":{"name":"agent-process-lifecycle"}}}}',
            '{"type":"step_finish","part":{"type":"step-finish"}}',
        )
    )
    stdout_path.write_text(stdout, encoding="utf-8")
    stderr_path.write_text("", encoding="utf-8")
    version_stdout = logs / "version.stdout.txt"
    version_stderr = logs / "version.stderr.txt"
    version_stdout.write_text("opencode test", encoding="utf-8")
    version_stderr.write_text("", encoding="utf-8")
    specification = load_specification(BENCHMARK_ROOT)
    candidate = specification.variants[1]
    preflight_stdout = logs / "preflight.stdout.txt"
    preflight_stderr = logs / "preflight.stderr.txt"
    preflight_fixture_id = "preflight-candidate"
    preflight_stdout.write_text(_preflight_stdout(candidate.skill_name, candidate.description, candidate.skill_name, root=evidence_root, fixture_id=preflight_fixture_id), encoding="utf-8")
    preflight_stderr.write_text("", encoding="utf-8")
    fixture_id = "candidate__listener-local-server__run-1__attempt-1"
    record = replace(
        TrialRecord.from_completed_process(
            "candidate",
            "listener-local-server",
            "positive",
            1,
            1,
            ("opencode", "run", "--pure", "--format", "json", "--model", "test-model", "--agent", "build", "--dir", str((evidence_root / "fixtures" / fixture_id).resolve()), specification.prompts[0].body),
            stdout,
            "",
            0,
            1.0,
            "agent-process-lifecycle",
        ),
        stdout_path="logs/candidate.stdout.ndjson",
        stderr_path="logs/candidate.stderr.txt",
        stdout_sha256=_hash(stdout_path),
        stderr_sha256=_hash(stderr_path),
    )
    trial_path = evidence_root / "trials.ndjson"
    record_document = asdict(record)
    record_document["candidate_selected"] = record.triggered
    record_document["fixture_id"] = fixture_id
    record_document["fixture_candidate_name"] = candidate.skill_name
    trial_path.write_text(json.dumps(record_document) + "\n", encoding="utf-8")
    manifest = {
        "schema_version": 2,
        "contract": "routing-release-gate-v1",
        "evidence_phase": "exploratory",
        "selection": {"variants": ["candidate"], "prompts": ["listener-local-server"], "runs_per_query": 1, "workers": 1},
        "execution_contract": {"model": "test-model", "agent": "build", "format": "json", "pure": True, "python_major_minor": "3.12"},
        "execution": {"workers": 1, "timeout_seconds": 1.0, "retries": 0, "seed": 1, "permission_policy": {"*": "deny", "skill": "allow"}},
        "environment_parity": {"opencode_output": "opencode test", "python": "3.12", "platform": "test"},
        "observed_environment": {"opencode": {"command": ["opencode", "--version"], "return_code": 0, "raw_output": "opencode test", "stdout_path": "logs/version.stdout.txt", "stderr_path": "logs/version.stderr.txt", "stdout_sha256": _hash(version_stdout), "stderr_sha256": _hash(version_stderr)}, "python": "3.12", "platform": "test"},
        "preflight": [{"variant_id": "candidate", "fixture_id": preflight_fixture_id, "command": ["opencode", "debug", "skill", "--pure"], "return_code": 0, "fixture_candidate_count": 1, "candidate_name": candidate.skill_name, "candidate_location": str(_candidate_location(evidence_root, candidate.skill_name, preflight_fixture_id).resolve()), "stdout_path": "logs/preflight.stdout.txt", "stderr_path": "logs/preflight.stderr.txt", "stdout_sha256": _hash(preflight_stdout), "stderr_sha256": _hash(preflight_stderr)}],
        "reference_manifest": None,
        "source_hashes": source_hashes_for(BENCHMARK_ROOT, specification),
        "artifact_hashes": {
            "trials.ndjson": _hash(trial_path),
            "logs/candidate.stdout.ndjson": _hash(stdout_path),
            "logs/candidate.stderr.txt": _hash(stderr_path),
            "logs/version.stdout.txt": _hash(version_stdout),
            "logs/version.stderr.txt": _hash(version_stderr),
            "logs/preflight.stdout.txt": _hash(preflight_stdout),
            "logs/preflight.stderr.txt": _hash(preflight_stderr),
        },
    }
    (evidence_root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")


def _hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _replace_preflight_stdout(root: Path, stdout: str) -> None:
    path = root / "logs" / "preflight.stdout.txt"
    path.write_text(stdout, encoding="utf-8")
    manifest_path = root / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["preflight"][0]["stdout_sha256"] = _hash(path)
    manifest["artifact_hashes"]["logs/preflight.stdout.txt"] = _hash(path)
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")


def update_artifact_hash(root: Path, relative_path: str) -> None:
    manifest_path = root / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["artifact_hashes"][relative_path] = _hash(root / relative_path)
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")


def _preflight_stdout(name: str, description: str, location: str, *, root: Path | None = None, fixture_id: str = "preflight-candidate", duplicate: bool = False) -> str:
    evidence_root = root if root is not None else Path.cwd()
    candidate_location = _candidate_location(evidence_root, location, fixture_id)
    document = {"name": name, "description": description, "location": str(candidate_location.resolve())}
    return json.dumps([document, document] if duplicate else [document])


def _candidate_location(root: Path, name: str, fixture_id: str = "preflight-candidate") -> Path:
    return root / "fixtures" / fixture_id / ".opencode" / "skills" / name / "SKILL.md"
