from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from evidence_fixtures import hash_file, make_plan, make_valid_records, make_version_capture
from trigger_benchmark.evidence import EvidenceValidationError, validate_calibration_evidence, validate_evidence
from trigger_benchmark.evidence_format import JsonObject, document, hash_mapping, integer, mapping, objects, string, strings
from trigger_benchmark.execution import RunExecutionPlan, execute_run
from trigger_benchmark.models import RunPhase, RunShape
from trigger_benchmark.preflight import PreflightCapture, PreflightEvidence, validate_preflight_evidence
from trigger_benchmark.preflight_execution import PreflightFailure, run_preflight


class PreflightRetryTests(unittest.TestCase):
    def test_run_preflight_when_streams_contain_lf_persists_exact_utf8_bytes_and_evidence_hashes(self) -> None:
        plan = _calibration_plan()
        variant = plan.variants[0]
        stdout = "preflight stdout\n"
        stderr = "preflight stderr\n"
        capture = PreflightCapture(
            PreflightEvidence(variant.id, "fixture", ("opencode", "debug", "skill", "--pure"), 0, hashlib.sha256(stdout.encode("utf-8")).hexdigest(), hashlib.sha256(stderr.encode("utf-8")).hexdigest(), 1, variant.skill_name, ""),
            stdout,
            stderr,
        )

        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            output = Path(temporary_directory) / "evidence"
            (output / "logs").mkdir(parents=True)
            (output / "fixtures").mkdir()
            options = replace(plan.options, output_directory=output)
            with patch("trigger_benchmark.preflight_execution.verify_candidate_discovery", return_value=capture):
                match run_preflight(options, (variant,), "opencode"):
                    case list() as evidence:
                        entry = mapping(evidence[0], "preflight")
                    case PreflightFailure(reason=reason):
                        self.fail(f"expected successful preflight evidence, received failure: {reason}")

            for stream, expected in (("stdout", stdout), ("stderr", stderr)):
                path = output / string(entry.get(f"{stream}_path"), f"preflight.{stream}_path")
                with self.subTest(stream=stream, assertion="bytes"):
                    self.assertEqual(path.read_bytes(), expected.encode("utf-8"))
                with self.subTest(stream=stream, assertion="hash"):
                    self.assertEqual(string(entry.get(f"{stream}_sha256"), f"preflight.{stream}_sha256"), hash_file(path))

    def test_preflight_when_first_omission_then_second_success_retains_verified_attempts(self) -> None:
        plan = _calibration_plan()
        shape = RunShape(plan.options.phase, plan.variants, plan.prompts, plan.options.runs_per_query, plan.options.workers)
        calls: list[Path] = []
        blocked_overrides = ("OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "OPENCODE_CONFIG_DIR", "OPENCODE_PERMISSION", "OPENCODE_DISABLE_PROJECT_CONFIG")
        inherited_environment = {"XDG_CONFIG_HOME": "inherited-config", "XDG_DATA_HOME": "inherited-data", "XDG_CACHE_HOME": "inherited-cache", "XDG_STATE_HOME": "inherited-state", "ANTHROPIC_API_KEY": "test-provider-auth", "HOME": "inherited-home", "USERPROFILE": "inherited-userprofile", "OPENCODE_CONFIG": "hostile-config.json", "OPENCODE_CONFIG_CONTENT": "hostile-config-content", "OPENCODE_CONFIG_DIR": "hostile-config-directory", "OPENCODE_PERMISSION": "hostile-permission", "OPENCODE_DISABLE_PROJECT_CONFIG": "1", "OPENCODE_TEST_HOME": "hostile-test-home", "OPENCODE_DISABLE_EXTERNAL_SKILLS": "0"}

        def discovery(command: list[str], **kwargs: str | Path | bool | int | dict[str, str]) -> CompletedProcess[str]:
            cwd = Path(str(kwargs["cwd"]))
            environment = kwargs.get("env")
            if not isinstance(environment, dict):
                self.fail("preflight subprocess call must receive a copied environment")
            self.assertIsNot(environment, os.environ)
            self.assertEqual(environment["XDG_CONFIG_HOME"], str(cwd.resolve()))
            for override in blocked_overrides:
                self.assertFalse(override in environment, f"{override} must be absent from the subprocess environment")
            self.assertEqual(environment["OPENCODE_TEST_HOME"], str(cwd.resolve()))
            self.assertEqual(environment["OPENCODE_DISABLE_EXTERNAL_SKILLS"], "1")
            self.assertEqual(environment["PATH"], os.environ["PATH"])
            self.assertEqual(environment["ANTHROPIC_API_KEY"], "test-provider-auth")
            self.assertEqual(environment["XDG_DATA_HOME"], "inherited-data")
            self.assertEqual(environment["XDG_CACHE_HOME"], "inherited-cache")
            self.assertEqual(environment["XDG_STATE_HOME"], "inherited-state")
            self.assertEqual(environment["HOME"], "inherited-home")
            self.assertEqual(environment["USERPROFILE"], "inherited-userprofile")
            calls.append(cwd)
            if len(calls) == 1:
                return CompletedProcess(command, 0, "[]", "first omission")
            skill_file, = (cwd / ".opencode" / "skills").glob("*/SKILL.md")
            variant = next(item for item in plan.variants if item.skill_name == skill_file.parent.name)
            return CompletedProcess(command, 0, json.dumps([{"name": variant.skill_name, "description": variant.description, "location": str(skill_file.resolve())}]), f"stderr-{len(calls)}")

        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            root = Path(temporary_directory) / "evidence"
            run_plan = replace(plan, options=replace(plan.options, output_directory=root))
            with patch.dict(os.environ, inherited_environment, clear=False):
                with patch("trigger_benchmark.execution._observe_version", return_value=make_version_capture()), patch("trigger_benchmark.preflight.subprocess.run", side_effect=discovery), patch("trigger_benchmark.execution.run_trials", return_value=make_valid_records(shape)):
                    self.assertEqual(execute_run(run_plan), 0)
            manifest = document(root / "manifest.json")
            entry = _preflight_entries(manifest)[0]
            attempts = objects(entry.get("attempts"), "preflight.attempts")
            self.assertEqual(integer(entry.get("successful_attempt"), "successful_attempt"), 2)
            self.assertEqual(len(attempts), 2)
            self.assertEqual(calls[0], calls[1])
            validate_preflight_evidence(root, manifest.get("preflight"), shape, plan.specification)
            original_first = attempts[0].copy()
            for changes in ({"attempt": 2}, {"outcome": "success"}, {"stdout_path": string(attempts[1].get("stdout_path"), "stdout_path"), "stdout_sha256": string(attempts[1].get("stdout_sha256"), "stdout_sha256")}, {"stderr_path": string(attempts[1].get("stderr_path"), "stderr_path"), "stderr_sha256": string(attempts[1].get("stderr_sha256"), "stderr_sha256")}):
                attempts[0].update(changes)
                with self.assertRaises(EvidenceValidationError):
                    validate_preflight_evidence(root, manifest.get("preflight"), shape, plan.specification)
                attempts[0].clear()
                attempts[0].update(original_first)
            single_success = objects(_preflight_entries(manifest)[1].get("attempts"), "preflight.attempts")[0]
            single_success["outcome"] = "semantic-discovery-omission"
            with self.assertRaises(EvidenceValidationError):
                validate_preflight_evidence(root, manifest.get("preflight"), shape, plan.specification)

    def test_preflight_when_two_omissions_writes_protocol_abort_before_trials(self) -> None:
        plan = _calibration_plan()
        calls: list[Path] = []

        def omission(command: list[str], **kwargs: str | Path | bool | int) -> CompletedProcess[str]:
            calls.append(Path(str(kwargs["cwd"])))
            return CompletedProcess(command, 0, "[]", "omission")

        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            root = Path(temporary_directory) / "evidence"
            run_plan = replace(plan, options=replace(plan.options, output_directory=root))
            with patch("trigger_benchmark.execution._observe_version", return_value=make_version_capture()), patch("trigger_benchmark.preflight.subprocess.run", side_effect=omission), patch("trigger_benchmark.execution.run_trials") as run_trials:
                self.assertEqual(execute_run(run_plan), 2)
            manifest = document(root / "manifest.json")
            completeness = mapping(manifest.get("matrix_completeness"), "matrix_completeness")
            self.assertEqual(integer(completeness.get("expected_cells"), "expected_cells"), 4)
            self.assertEqual(set(strings(completeness.get("missing_cells"), "missing_cells")), {"current::listener-local-server::run-1", "current::sync-long-command::run-1", "candidate::listener-local-server::run-1", "candidate::sync-long-command::run-1"})
            abort_entry = objects(manifest.get("preflight"), "preflight")[0]
            attempts = objects(abort_entry.get("attempts"), "preflight.attempts")
            self.assertEqual(len(attempts), 2)
            for attempt in attempts:
                self.assertTrue((root / string(attempt.get("stdout_path"), "stdout_path")).is_file())
                self.assertTrue((root / string(attempt.get("stderr_path"), "stderr_path")).is_file())
            environment = mapping(manifest.get("observed_environment"), "observed_environment")
            version = mapping(environment.get("opencode"), "observed_environment.opencode")
            self.assertTrue((root / string(version.get("stdout_path"), "version.stdout_path")).is_file())
            self.assertTrue((root / string(version.get("stderr_path"), "version.stderr_path")).is_file())
            hashes = hash_mapping(manifest.get("artifact_hashes"), "artifact_hashes")
            for path in (string(version.get("stdout_path"), "version.stdout_path"), string(version.get("stderr_path"), "version.stderr_path"), *(string(attempt.get(field), field) for attempt in attempts for field in ("stdout_path", "stderr_path"))):
                self.assertIn(path, hashes)
            self.assertTrue((root / "incomplete.json").is_file())
            self.assertFalse((root / "trials.ndjson").exists())
            run_trials.assert_not_called()
            self.assertEqual(calls[0], calls[1])
            with self.assertRaises(EvidenceValidationError):
                validate_evidence(root, BENCHMARK_ROOT, plan.specification)
            with self.assertRaises(EvidenceValidationError):
                validate_calibration_evidence(root, BENCHMARK_ROOT, plan.specification)

    def test_preflight_when_discovery_is_not_genuine_omission_does_not_retry(self) -> None:
        plan = _calibration_plan()
        cases = ("nonzero", "malformed", "missing-location", "relative-location", "outside-fixture-skills", "wrong-description", "wrong-name", "duplicate")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
                calls: list[Path] = []

                def failure(command: list[str], **kwargs: str | Path | bool | int) -> CompletedProcess[str]:
                    cwd = Path(str(kwargs["cwd"]))
                    calls.append(cwd)
                    location = cwd / ".opencode" / "skills" / "playwright-server-lifecycle" / "SKILL.md"
                    document_value: list[dict[str, str]] = [{"name": "playwright-server-lifecycle", "description": plan.variants[0].description, "location": str(location.resolve())}]
                    if case == "nonzero":
                        return CompletedProcess(command, 9, "[]", "process failure")
                    if case == "malformed":
                        return CompletedProcess(command, 0, "{", "malformed")
                    if case == "missing-location":
                        document_value = [{"name": "playwright-server-lifecycle", "description": plan.variants[0].description}]
                    if case == "relative-location":
                        document_value[0]["location"] = ".opencode/skills/playwright-server-lifecycle/SKILL.md"
                    if case == "outside-fixture-skills":
                        document_value[0]["location"] = str((cwd / ".opencode" / "other" / "SKILL.md").resolve())
                    if case == "wrong-description":
                        document_value[0]["description"] = "wrong"
                    if case == "wrong-name":
                        document_value[0]["name"] = "wrong"
                    if case == "duplicate":
                        document_value.append(document_value[0].copy())
                    return CompletedProcess(command, 0, json.dumps(document_value), "invalid")

                root = Path(temporary_directory) / "evidence"
                run_plan = replace(plan, options=replace(plan.options, output_directory=root))
                with patch("trigger_benchmark.execution._observe_version", return_value=make_version_capture()), patch("trigger_benchmark.preflight.subprocess.run", side_effect=failure), patch("trigger_benchmark.execution.run_trials") as run_trials:
                    self.assertEqual(execute_run(run_plan), 2)
                self.assertEqual(len(calls), 1)
                run_trials.assert_not_called()


def _preflight_entries(manifest: JsonObject) -> list[JsonObject]:
    return objects(manifest.get("preflight"), "preflight")


def _calibration_plan() -> RunExecutionPlan:
    plan = make_plan(RunPhase.CALIBRATION)
    prompts = tuple(prompt for prompt in plan.specification.prompts if prompt.id in {"listener-local-server", "sync-long-command"})
    return replace(plan, prompts=prompts, options=replace(plan.options, runs_per_query=1))
