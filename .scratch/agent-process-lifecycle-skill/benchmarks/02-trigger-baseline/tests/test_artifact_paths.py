from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))

from trigger_benchmark.artifact_paths import ArtifactPathError, StreamPaths, ensure_unique_destinations, preflight_paths, trial_paths, version_paths
from trigger_benchmark.evidence import EvidenceValidationError, _validate_environment_streams, _validate_raw_record
from trigger_benchmark.execution import VersionCapture, _observed_environment, _persist_version
from trigger_benchmark.models import RunPhase, RunShape, Specification, TrialRecord, Variant
from trigger_benchmark.preflight import PreflightEvidence, validate_preflight_evidence
from trigger_benchmark.preflight_execution import PreflightCapture, _persist_capture
from trigger_benchmark.trials import StreamOutput, _persist_stream


class ArtifactPathTests(unittest.TestCase):
    def test_version_paths_when_persisted_use_compact_names_and_preserve_bytes_and_hashes(self) -> None:
        stdout = "version stdout\n"
        stderr = "version stderr\n"
        capture = VersionCapture(("opencode", "--version"), 0, stdout, stderr)

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "logs").mkdir()
            environment = _observed_environment(capture).document
            _persist_version(root, capture)

            self.assertEqual(version_paths().stdout, "logs/v.out")
            self.assertEqual(version_paths().stderr, "logs/v.err")
            self.assertEqual((root / "logs/v.out").read_bytes(), stdout.encode("utf-8"))
            self.assertEqual((root / "logs/v.err").read_bytes(), stderr.encode("utf-8"))
            opencode = environment["opencode"]
            self.assertEqual(opencode["stdout_sha256"], hashlib.sha256(stdout.encode("utf-8")).hexdigest())
            self.assertEqual(opencode["stderr_sha256"], hashlib.sha256(stderr.encode("utf-8")).hexdigest())
            _validate_environment_streams(root, opencode)

            legacy = dict(opencode)
            legacy["stdout_path"] = "logs/environment-opencode-version.stdout.txt"
            (root / legacy["stdout_path"]).write_bytes(stdout.encode("utf-8"))
            with self.assertRaises(EvidenceValidationError):
                _validate_environment_streams(root, legacy)

    def test_preflight_paths_when_persisted_use_compact_names_and_preserve_bytes_and_hashes(self) -> None:
        stdout = "preflight stdout\n"
        stderr = "preflight stderr\n"
        capture = PreflightCapture(
            PreflightEvidence(
                "current",
                "fixture-1",
                ("opencode", "debug", "skill", "--pure"),
                0,
                hashlib.sha256(stdout.encode("utf-8")).hexdigest(),
                hashlib.sha256(stderr.encode("utf-8")).hexdigest(),
                1,
                "candidate-skill",
                "",
            ),
            stdout,
            stderr,
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "logs").mkdir()
            persisted = _persist_capture(root, "current", capture, 1)

            self.assertEqual(preflight_paths("current", 1).stdout, "logs/p-current-1.out")
            self.assertEqual(preflight_paths("current", 1).stderr, "logs/p-current-1.err")
            self.assertEqual((root / persisted.evidence.stdout_path).read_bytes(), stdout.encode("utf-8"))
            self.assertEqual((root / persisted.evidence.stderr_path).read_bytes(), stderr.encode("utf-8"))
            self.assertEqual(persisted.evidence.stdout_sha256, hashlib.sha256((root / persisted.evidence.stdout_path).read_bytes()).hexdigest())
            self.assertEqual(persisted.evidence.stderr_sha256, hashlib.sha256((root / persisted.evidence.stderr_path).read_bytes()).hexdigest())

    def test_trial_paths_when_persisted_use_compact_names_and_strictly_revalidate_them(self) -> None:
        stdout = '{"type":"step_finish","part":{"type":"step-finish"}}\n'
        stderr = "trial stderr\n"
        record = TrialRecord.from_completed_process("current", "prompt", "positive", 1, 1, ("opencode",), stdout, stderr, 0, 1.0, "candidate-skill")

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "logs").mkdir()
            persisted = _persist_stream(root, StreamOutput(replace(record, fixture_id="fixture-1"), stdout, stderr))

            self.assertEqual(trial_paths("fixture-1").stdout, "logs/t-fixture-1.out")
            self.assertEqual(trial_paths("fixture-1").stderr, "logs/t-fixture-1.err")
            self.assertEqual((root / persisted.stdout_path).read_bytes(), stdout.encode("utf-8"))
            self.assertEqual((root / persisted.stderr_path).read_bytes(), stderr.encode("utf-8"))
            self.assertEqual(persisted.stdout_sha256, hashlib.sha256((root / persisted.stdout_path).read_bytes()).hexdigest())
            self.assertEqual(persisted.stderr_sha256, hashlib.sha256((root / persisted.stderr_path).read_bytes()).hexdigest())
            _validate_raw_record(root, persisted, "candidate-skill")

            legacy_path = root / "logs/current__prompt__run-1__attempt-1.stdout.ndjson"
            legacy_path.write_bytes(stdout.encode("utf-8"))
            with self.assertRaises(EvidenceValidationError):
                _validate_raw_record(root, replace(persisted, stdout_path="logs/current__prompt__run-1__attempt-1.stdout.ndjson"), "candidate-skill")

    def test_component_paths_when_unsafe_reject_before_constructing_a_destination(self) -> None:
        unsafe_values = ("", ".", "..", "nested/name", "nested\\name", "C:relative", "name with spaces", "name\x00")
        for value in unsafe_values:
            with self.subTest(value=value):
                with self.assertRaises(ArtifactPathError):
                    preflight_paths(value, 1)
                with self.assertRaises(ArtifactPathError):
                    trial_paths(value)
        for attempt in (0, -1, True, 1.5):
            with self.subTest(attempt=attempt):
                with self.assertRaises(ArtifactPathError):
                    preflight_paths("current", attempt)

    def test_destinations_when_reused_reject_before_writing(self) -> None:
        with self.assertRaises(ArtifactPathError):
            ensure_unique_destinations((trial_paths("fixture-1"), trial_paths("fixture-1")))
        with self.assertRaises(ArtifactPathError):
            ensure_unique_destinations((StreamPaths("logs/a.out", "logs/a.out"),))

    def test_retained_preflight_when_compact_paths_reparse_and_legacy_paths_reject(self) -> None:
        variant = Variant("candidate", "candidate-skill", "candidate description", "unused")
        shape = RunShape(RunPhase.EXPLORATORY, (variant,), (), 1, 1)
        specification = Specification((), (variant,))

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "logs").mkdir()
            candidate_location = root / "fixtures/fixture-1/.opencode/skills/candidate-skill/SKILL.md"
            stdout = json.dumps([{"name": variant.skill_name, "description": variant.description, "location": str(candidate_location.resolve())}])
            stderr = ""
            paths = preflight_paths(variant.id, 1)
            (root / paths.stdout).write_bytes(stdout.encode("utf-8"))
            (root / paths.stderr).write_bytes(stderr.encode("utf-8"))
            retained = [{"variant_id": variant.id, "fixture_id": "fixture-1", "command": ["opencode", "debug", "skill", "--pure"], "return_code": 0, "stdout_sha256": hashlib.sha256(stdout.encode("utf-8")).hexdigest(), "stderr_sha256": hashlib.sha256(stderr.encode("utf-8")).hexdigest(), "fixture_candidate_count": 1, "candidate_name": variant.skill_name, "candidate_location": str(candidate_location.resolve()), "stdout_path": paths.stdout, "stderr_path": paths.stderr}]

            validate_preflight_evidence(root, retained, shape, specification)

            retained[0]["stdout_path"] = "logs/preflight-candidate-fixture-1-attempt-1.stdout.txt"
            with self.assertRaises(EvidenceValidationError):
                validate_preflight_evidence(root, retained, shape, specification)
