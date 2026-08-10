from __future__ import annotations

import json
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))

import evaluate_routing_release_gate
from evidence_fixtures import hash_file, make_manifest_template, make_plan, make_reference_record, write_evidence
from trigger_benchmark.evidence_format import document, mapping
from trigger_benchmark.models import RunPhase, RunShape
from trigger_benchmark.spec import load_specification


class EvaluatorLayoutTests(unittest.TestCase):
    def test_final_when_targeted_directory_differs_from_manifest_prompt_rejects(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        calibration_shape = RunShape(RunPhase.CALIBRATION, specification.variants, (specification.prompts[0], specification.prompts[8]), 1, 4)
        base_shape = RunShape(RunPhase.FIXED_BASE, specification.variants, specification.prompts, 3, 4)
        target_prompt = specification.prompts[0]
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            root = Path(temporary_directory)
            for workers in (1, 2, 4):
                write_evidence(root / f"calibration-w{workers}", make_manifest_template(make_plan(RunPhase.CALIBRATION)), RunShape(calibration_shape.phase, calibration_shape.variants, calibration_shape.prompts, calibration_shape.runs_per_query, workers))
            self.assertEqual(evaluate_routing_release_gate.main(("calibrate", "--gate-root", str(root))), 0)
            base = root / "base"
            write_evidence(base, make_manifest_template(make_plan(RunPhase.FIXED_BASE)), base_shape)
            _make_base_prompt_targeted(base, target_prompt.id)
            base_manifest = document(base / "manifest.json")
            base_manifest["reference_manifest"] = make_reference_record(root / "calibration-w4" / "manifest.json", RunPhase.CALIBRATION)
            aggregate = base / "aggregate.json"
            aggregate.write_text("{}\n", encoding="utf-8")
            mapping(base_manifest.get("artifact_hashes"), "artifact_hashes")["aggregate.json"] = hash_file(aggregate)
            (base / "manifest.json").write_text(json.dumps(base_manifest), encoding="utf-8")
            self.assertEqual(evaluate_routing_release_gate.main(("evaluate", "--gate-root", str(root), "--stage", "base")), 3)
            target_plan = make_plan(RunPhase.TARGETED, prompt_ids=(target_prompt.id,))
            target_plan = replace(target_plan, options=replace(target_plan.options, workers=4))
            target_shape = RunShape(RunPhase.TARGETED, target_plan.variants, target_plan.prompts, 7, 4)
            target = root / "targeted" / "wrong-prompt-id"
            write_evidence(target, make_manifest_template(target_plan), target_shape)
            target_manifest = document(target / "manifest.json")
            target_manifest["reference_manifest"] = make_reference_record(base / "manifest.json", RunPhase.FIXED_BASE)
            (target / "manifest.json").write_text(json.dumps(target_manifest), encoding="utf-8")

            self.assertEqual(evaluate_routing_release_gate.main(("evaluate", "--gate-root", str(root), "--stage", "final")), 2)


def _make_base_prompt_targeted(root: Path, prompt_id: str) -> None:
    trials_path = root / "trials.ndjson"
    records = [json.loads(line) for line in trials_path.read_text(encoding="utf-8").splitlines()]
    record = next(item for item in records if item["variant_id"] == "candidate" and item["prompt_id"] == prompt_id and item["logical_run"] == 1)
    stdout_path = root / record["stdout_path"]
    stdout_path.write_text('{"type":"step_finish","part":{"type":"step-finish"}}', encoding="utf-8")
    record["status"] = "not_triggered"
    record["triggered"] = False
    record["candidate_selected"] = False
    record["tool_uses"] = []
    record["non_skill_tool_uses"] = []
    record["stdout_sha256"] = hash_file(stdout_path)
    trials_path.write_text("".join(json.dumps(item) + "\n" for item in records), encoding="utf-8")
    manifest_path = root / "manifest.json"
    manifest = document(manifest_path)
    hashes = mapping(manifest.get("artifact_hashes"), "artifact_hashes")
    hashes[record["stdout_path"]] = hash_file(stdout_path)
    hashes["trials.ndjson"] = hash_file(trials_path)
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
