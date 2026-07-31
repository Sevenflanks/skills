from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import evaluate_routing_release_gate
from evidence_fixtures import hash_file, make_manifest_template, make_plan, make_reference_record, make_valid_records, make_version_capture, write_evidence
from trigger_benchmark.evidence_format import document, mapping
from trigger_benchmark.models import RunPhase, RunShape
from trigger_benchmark.runner import main as run_benchmark


class SelectedWorkerContractTests(unittest.TestCase):
    def test_documented_fixed_base_and_targeted_commands_pass_the_selected_worker_option(self) -> None:
        readme = (BENCHMARK_ROOT / "README.md").read_text(encoding="utf-8")
        command_blocks = tuple(block.partition("```")[0] for block in readme.split("```powershell")[1:])
        fixed_base = next(block for block in command_blocks if "--phase fixed-base" in block)
        targeted = next(block for block in command_blocks if "--phase targeted" in block)

        self.assertIn("$SelectedWorkers", readme)
        self.assertIn("worker-calibration.json", fixed_base)
        self.assertIn("worker-calibration.json", targeted)
        self.assertIn("--workers $SelectedWorkers", fixed_base)
        self.assertIn("--workers $SelectedWorkers", targeted)
        self.assertIn('$BenchmarkRoot = ".scratch/agent-process-lifecycle-skill/benchmarks/02-trigger-baseline"', readme)
        self.assertIn('$GateRoot = "results/<gate-root>"', readme)
        self.assertIn('Get-Content -Raw "$BenchmarkRoot/$GateRoot/worker-calibration.json"', fixed_base)
        self.assertIn('Get-Content -Raw "$BenchmarkRoot/$GateRoot/worker-calibration.json"', targeted)
        self.assertIn('"$BenchmarkRoot/run_trigger_baseline.py"', fixed_base)
        self.assertIn('"$BenchmarkRoot/run_trigger_baseline.py"', targeted)

    def test_selected_worker_four_drives_fixed_base_and_targeted_option_reference_parity(self) -> None:
        calibration_plan = make_plan(RunPhase.CALIBRATION)
        specification = calibration_plan.specification
        calibration_shape = RunShape(RunPhase.CALIBRATION, specification.variants, (specification.prompts[0], specification.prompts[8]), 1, 4)
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            root = Path(temporary_directory)
            for workers in (1, 2, 4):
                write_evidence(root / f"calibration-w{workers}", make_manifest_template(calibration_plan), RunShape(calibration_shape.phase, calibration_shape.variants, calibration_shape.prompts, calibration_shape.runs_per_query, workers))
            self.assertEqual(evaluate_routing_release_gate.main(("calibrate", "--gate-root", str(root))), 0)
            calibration = document(root / "worker-calibration.json")
            selected_workers = mapping(calibration.get("selected"), "selected")["workers"]
            if not isinstance(selected_workers, int):
                self.fail("selected calibration worker must be an integer")

            fixed_output = root / "fixed-output"
            fixed_shape = RunShape(RunPhase.FIXED_BASE, specification.variants, specification.prompts, 3, selected_workers)
            fixed_arguments = ("--phase", "fixed-base", "--workers", str(selected_workers), "--model", "test-model", "--timeout-seconds", "1", "--retries", "0", "--seed", "1", "--output-dir", str(fixed_output), "--reference-manifest", str(root / f"calibration-w{selected_workers}" / "manifest.json"))
            with patch("trigger_benchmark.execution._observe_version", return_value=make_version_capture()), patch("trigger_benchmark.execution._run_preflight", return_value=[]), patch("trigger_benchmark.execution.run_trials", return_value=make_valid_records(fixed_shape)):
                self.assertEqual(run_benchmark(fixed_arguments), 0)
            fixed_manifest = document(fixed_output / "manifest.json")
            self.assertEqual(mapping(fixed_manifest.get("selection"), "selection")["workers"], selected_workers)
            self.assertEqual(fixed_manifest.get("reference_manifest"), make_reference_record(root / f"calibration-w{selected_workers}" / "manifest.json", RunPhase.CALIBRATION))

            base_manifest = make_manifest_template(calibration_plan)
            base_manifest["reference_manifest"] = make_reference_record(root / f"calibration-w{selected_workers}" / "manifest.json", RunPhase.CALIBRATION)
            write_evidence(root / "base", base_manifest, RunShape(RunPhase.FIXED_BASE, specification.variants, specification.prompts, 3, selected_workers))
            _make_base_prompt_targeted(root / "base")

            targeted_output = root / "targeted-output"
            targeted_shape = RunShape(RunPhase.TARGETED, (specification.variants[1],), (specification.prompts[0],), 7, selected_workers)
            targeted_arguments = ("--phase", "targeted", "--workers", str(selected_workers), "--model", "test-model", "--timeout-seconds", "1", "--retries", "0", "--seed", "1", "--prompt", "listener-local-server", "--output-dir", str(targeted_output), "--reference-manifest", str(root / "base" / "manifest.json"))
            with patch("trigger_benchmark.execution._observe_version", return_value=make_version_capture()), patch("trigger_benchmark.execution._run_preflight", return_value=[]), patch("trigger_benchmark.execution.run_trials", return_value=make_valid_records(targeted_shape)):
                self.assertEqual(run_benchmark(targeted_arguments), 0)
            targeted_manifest = document(targeted_output / "manifest.json")
            self.assertEqual(mapping(targeted_manifest.get("selection"), "selection")["workers"], selected_workers)
            self.assertEqual(targeted_manifest.get("reference_manifest"), make_reference_record(root / "base" / "manifest.json", RunPhase.FIXED_BASE))


def _make_base_prompt_targeted(root: Path) -> None:
    trials = root / "trials.ndjson"
    records = [json.loads(line) for line in trials.read_text(encoding="utf-8").splitlines()]
    record = next(item for item in records if item["variant_id"] == "candidate" and item["prompt_id"] == "listener-local-server" and item["logical_run"] == 3)
    stdout = root / record["stdout_path"]
    stdout.write_text('{"type":"step_finish","part":{"type":"step-finish"}}', encoding="utf-8")
    record["status"] = "not_triggered"
    record["triggered"] = False
    record["candidate_selected"] = False
    record["tool_uses"] = []
    record["non_skill_tool_uses"] = []
    record["stdout_sha256"] = hash_file(stdout)
    trials.write_text("".join(json.dumps(item) + "\n" for item in records), encoding="utf-8")
    manifest_path = root / "manifest.json"
    manifest = document(manifest_path)
    mapping(manifest.get("artifact_hashes"), "artifact_hashes")["trials.ndjson"] = hash_file(trials)
    mapping(manifest.get("artifact_hashes"), "artifact_hashes")[record["stdout_path"]] = hash_file(stdout)
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
