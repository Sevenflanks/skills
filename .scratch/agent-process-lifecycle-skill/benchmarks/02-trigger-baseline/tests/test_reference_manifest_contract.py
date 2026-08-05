from __future__ import annotations

import json
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))

import evaluate_routing_release_gate
from trigger_benchmark.evidence import EvidenceValidationError, validate_evidence
from trigger_benchmark.evidence_format import document, mapping, strings
from trigger_benchmark.execution import RunExecutionError, RunExecutionPlan, execute_run
from trigger_benchmark.models import RunPhase, RunShape
from evidence_fixtures import hash_file, make_manifest_template, make_plan, make_reference_record, make_valid_records, make_version_capture, write_evidence


class ReferenceManifestContractTests(unittest.TestCase):
    def test_fixed_base_when_reference_has_complete_wrong_phase_blocks_before_preflight_and_trials(self) -> None:
        plan = make_plan(RunPhase.FIXED_BASE)
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            reference_root = Path(temporary_directory) / "exploratory-reference"
            specification = plan.specification
            exploratory_shape = RunShape(RunPhase.EXPLORATORY, (specification.variants[1],), (specification.prompts[0],), 1, 1)
            write_evidence(reference_root, make_manifest_template(plan), exploratory_shape)
            invalid_plan = replace(plan, options=replace(plan.options, reference_manifest=reference_root / "manifest.json"))

            _assert_reference_rejects_before_dispatch(self, invalid_plan)

    def test_targeted_when_fixed_base_does_not_authorize_requested_prompt_blocks_before_preflight_and_trials(self) -> None:
        plan = make_plan(RunPhase.TARGETED, prompt_ids=("listener-local-server",))
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            temporary_root = Path(temporary_directory)
            calibration_root = temporary_root / "calibration-reference"
            reference_root = temporary_root / "base-reference"
            specification = plan.specification
            calibration_shape = RunShape(
                RunPhase.CALIBRATION,
                specification.variants,
                tuple(prompt for prompt in specification.prompts if prompt.id in {"listener-local-server", "sync-long-command"}),
                1,
                1,
            )
            base_shape = RunShape(RunPhase.FIXED_BASE, specification.variants, specification.prompts, 3, 1)
            write_evidence(calibration_root, make_manifest_template(plan), calibration_shape)
            base_manifest = make_manifest_template(plan)
            base_manifest["reference_manifest"] = make_reference_record(calibration_root / "manifest.json", RunPhase.CALIBRATION)
            write_evidence(reference_root, base_manifest, base_shape)
            invalid_plan = replace(plan, options=replace(plan.options, reference_manifest=reference_root / "manifest.json"))

            _assert_reference_rejects_before_dispatch(self, invalid_plan)

    def test_fixed_base_when_reference_is_incomplete_blocks_before_creating_output_or_observing_version(self) -> None:
        plan = make_plan(RunPhase.FIXED_BASE)
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            reference_root = Path(temporary_directory) / "calibration-reference"
            specification = plan.specification
            shape = RunShape(
                RunPhase.CALIBRATION,
                specification.variants,
                tuple(prompt for prompt in specification.prompts if prompt.id in {"listener-local-server", "sync-long-command"}),
                1,
                1,
            )
            write_evidence(reference_root, make_manifest_template(plan), shape)
            trials = reference_root / "trials.ndjson"
            trials.write_text("\n".join(trials.read_text(encoding="utf-8").splitlines()[:-1]) + "\n", encoding="utf-8")
            manifest_path = reference_root / "manifest.json"
            manifest = document(manifest_path)
            mapping(manifest.get("artifact_hashes"), "artifact_hashes")["trials.ndjson"] = hash_file(trials)
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            invalid_plan = replace(plan, options=replace(plan.options, reference_manifest=reference_root / "manifest.json"))

            _assert_reference_rejects_before_dispatch(self, invalid_plan)

    def test_fixed_base_when_reference_execution_differs_blocks_before_creating_output_or_observing_version(self) -> None:
        plan = make_plan(RunPhase.FIXED_BASE)
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            reference_root = Path(temporary_directory) / "calibration-reference"
            specification = plan.specification
            shape = RunShape(
                RunPhase.CALIBRATION,
                specification.variants,
                tuple(prompt for prompt in specification.prompts if prompt.id in {"listener-local-server", "sync-long-command"}),
                1,
                1,
            )
            write_evidence(reference_root, make_manifest_template(plan), shape)
            manifest_path = reference_root / "manifest.json"
            manifest = document(manifest_path)
            mapping(manifest.get("execution"), "execution")["seed"] = 2
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            invalid_plan = replace(plan, options=replace(plan.options, reference_manifest=reference_root / "manifest.json"))

            _assert_reference_rejects_before_dispatch(self, invalid_plan)

    def test_fixed_base_when_calibration_reference_is_valid_records_normalized_path_hash_and_phase(self) -> None:
        plan = make_plan(RunPhase.FIXED_BASE)
        specification = plan.specification
        calibration_shape = RunShape(
            RunPhase.CALIBRATION,
            specification.variants,
            tuple(prompt for prompt in specification.prompts if prompt.id in {"listener-local-server", "sync-long-command"}),
            1,
            1,
        )
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            temporary_root = Path(temporary_directory)
            reference_root = temporary_root / "calibration-reference"
            write_evidence(reference_root, make_manifest_template(plan), calibration_shape)
            output_directory = temporary_root / "output"
            run_plan = replace(
                plan,
                options=replace(plan.options, output_directory=output_directory, reference_manifest=reference_root / "manifest.json"),
            )
            with patch("trigger_benchmark.execution._observe_version", return_value=make_version_capture()), patch("trigger_benchmark.execution._run_preflight", return_value=[]), patch("trigger_benchmark.execution.run_trials", return_value=make_valid_records(RunShape(RunPhase.FIXED_BASE, specification.variants, specification.prompts, 3, 1))):
                self.assertEqual(execute_run(run_plan), 0)

            manifest = document(output_directory / "manifest.json")
            self.assertEqual(
                manifest.get("reference_manifest"),
                {
                    "path": (reference_root / "manifest.json").resolve().relative_to(BENCHMARK_ROOT).as_posix(),
                    "sha256": hash_file(reference_root / "manifest.json"),
                    "expected_phase": "calibration",
                },
            )
            opencode = mapping(mapping(manifest.get("observed_environment"), "observed_environment").get("opencode"), "observed_environment.opencode")
            self.assertEqual(opencode["stdout_path"], "logs/environment-opencode-version.stdout.txt")
            self.assertEqual(opencode["stderr_path"], "logs/environment-opencode-version.stderr.txt")
            self.assertEqual(opencode["stdout_sha256"], hash_file(output_directory / "logs" / "environment-opencode-version.stdout.txt"))
            self.assertEqual(opencode["stderr_sha256"], hash_file(output_directory / "logs" / "environment-opencode-version.stderr.txt"))

    def test_evidence_when_gated_phase_has_no_reference_record_rejects(self) -> None:
        plan = make_plan(RunPhase.FIXED_BASE)
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory) / "evidence"
            write_evidence(root, make_manifest_template(plan), RunShape(RunPhase.FIXED_BASE, plan.specification.variants, plan.specification.prompts, 3, 1))

            with self.assertRaises(EvidenceValidationError):
                validate_evidence(root, BENCHMARK_ROOT, plan.specification)

    def test_evaluator_when_base_reference_differs_from_selected_calibration_rejects(self) -> None:
        plan = make_plan(RunPhase.FIXED_BASE)
        specification = plan.specification
        calibration_shape = RunShape(
            RunPhase.CALIBRATION,
            specification.variants,
            tuple(prompt for prompt in specification.prompts if prompt.id in {"listener-local-server", "sync-long-command"}),
            1,
            1,
        )
        base_shape = RunShape(RunPhase.FIXED_BASE, specification.variants, specification.prompts, 3, 4)
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            gate_root = Path(temporary_directory)
            selected = gate_root / "calibration-w1"
            other = gate_root / "calibration-w2"
            highest = gate_root / "calibration-w4"
            base = gate_root / "base"
            write_evidence(selected, make_manifest_template(plan), calibration_shape)
            write_evidence(other, make_manifest_template(plan), RunShape(calibration_shape.phase, calibration_shape.variants, calibration_shape.prompts, calibration_shape.runs_per_query, 2))
            write_evidence(highest, make_manifest_template(plan), RunShape(calibration_shape.phase, calibration_shape.variants, calibration_shape.prompts, calibration_shape.runs_per_query, 4))
            self.assertEqual(evaluate_routing_release_gate.main(("calibrate", "--gate-root", str(gate_root))), 0)
            base_manifest = make_manifest_template(plan)
            base_manifest["reference_manifest"] = make_reference_record(other / "manifest.json", RunPhase.CALIBRATION)
            write_evidence(base, base_manifest, base_shape)

            self.assertEqual(evaluate_routing_release_gate.main(("evaluate", "--gate-root", str(gate_root), "--stage", "base")), 2)
            decision = document(gate_root / "base-decision" / "decision.json")
            self.assertIn("does not match the selected", strings(decision.get("reasons"), "reasons")[0])


def _assert_reference_rejects_before_dispatch(test_case: unittest.TestCase, plan: RunExecutionPlan) -> None:
    with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
        output_directory = Path(temporary_directory) / "output"
        executable_plan = replace(plan, options=replace(plan.options, output_directory=output_directory))
        with patch("trigger_benchmark.execution._prepare_output_directory") as prepared, patch("trigger_benchmark.execution._observe_version", return_value=make_version_capture()) as observed, patch("trigger_benchmark.execution._run_preflight", return_value=[]) as preflight, patch("trigger_benchmark.execution.run_trials", return_value=[]) as trials:
            with test_case.assertRaises(RunExecutionError):
                execute_run(executable_plan)
        prepared.assert_not_called()
        observed.assert_not_called()
        preflight.assert_not_called()
        trials.assert_not_called()
        test_case.assertFalse(output_directory.exists())
