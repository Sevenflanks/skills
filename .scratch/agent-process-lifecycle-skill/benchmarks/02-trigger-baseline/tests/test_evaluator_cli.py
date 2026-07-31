from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))

import evaluate_routing_release_gate
from evidence_fixtures import hash_file, make_manifest_template, make_plan, make_reference_record, write_evidence
from trigger_benchmark.evidence import ValidatedEvidence
from trigger_benchmark.evidence_format import document, mapping
from trigger_benchmark.models import RunPhase, RunShape
from trigger_benchmark.spec import load_specification


class EvaluatorCliTests(unittest.TestCase):
    def test_calibrate_when_w4_is_incomplete_keeps_entry_selects_w2_and_excludes_trigger_data(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        shape = RunShape(RunPhase.CALIBRATION, specification.variants, (specification.prompts[0], specification.prompts[8]), 1, 1)
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            root = Path(temporary_directory)
            for workers in (1, 2, 4):
                worker_shape = RunShape(shape.phase, shape.variants, shape.prompts, shape.runs_per_query, workers)
                write_evidence(root / f"calibration-w{workers}", make_manifest_template(make_plan(RunPhase.FIXED_BASE)), worker_shape)
            trial_path = root / "calibration-w4" / "trials.ndjson"
            trial_path.write_text("\n".join(trial_path.read_text(encoding="utf-8").splitlines()[:-1]) + "\n", encoding="utf-8")
            manifest_path = root / "calibration-w4" / "manifest.json"
            manifest = document(manifest_path)
            mapping(manifest.get("artifact_hashes"), "artifact_hashes")["trials.ndjson"] = hash_file(trial_path)
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            self.assertEqual(evaluate_routing_release_gate.main(("calibrate", "--gate-root", str(root))), 0)

            calibration = document(root / "worker-calibration.json")
            self.assertEqual(mapping(calibration.get("selected"), "selected")["workers"], 2)
            entries = calibration.get("entries")
            if not isinstance(entries, list) or len(entries) < 3 or not isinstance(entries[2], dict):
                self.fail("calibration entries must retain the expected shape")
            self.assertEqual(entries[2]["complete"], False)
            self.assertEqual(entries[2]["parity"], "match")
            self.assertNotIn("triggered", json.dumps(calibration))

    def test_calibrate_when_incomplete_worker_metadata_drifts_returns_invalid_evidence(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        prompts = (specification.prompts[0], specification.prompts[8])
        cases = ("environment", "execution", "source")
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            root = Path(temporary_directory)
            for workers in (1, 2, 4):
                directory = root / f"calibration-w{workers}"
                directory.mkdir()
                (directory / "manifest.json").write_text("{}", encoding="utf-8")
            for drift in cases:
                with self.subTest(drift=drift):
                    evidence = tuple(
                        _calibration_evidence(
                            root / f"calibration-w{workers}",
                            RunShape(RunPhase.CALIBRATION, specification.variants, prompts, 1, workers),
                            complete=workers != 4,
                            environment_signature="drift" if drift == "environment" and workers == 4 else "environment",
                            execution_parity_signature="drift" if drift == "execution" and workers == 4 else "execution",
                            source_signature="drift" if drift == "source" and workers == 4 else "source",
                        )
                        for workers in (1, 2, 4)
                    )
                    with patch("trigger_benchmark.calibration.validate_calibration_evidence", side_effect=evidence):
                        self.assertEqual(evaluate_routing_release_gate.main(("calibrate", "--gate-root", str(root))), 2)

    def test_calibrate_when_w1_is_incomplete_uses_it_as_the_canonical_parity_run(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        prompts = (specification.prompts[0], specification.prompts[8])
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            root = Path(temporary_directory)
            for workers in (1, 2, 4):
                directory = root / f"calibration-w{workers}"
                directory.mkdir()
                (directory / "manifest.json").write_text("{}", encoding="utf-8")
            evidence = tuple(
                _calibration_evidence(
                    root / f"calibration-w{workers}",
                    RunShape(RunPhase.CALIBRATION, specification.variants, prompts, 1, workers),
                    complete=workers != 1,
                    environment_signature="environment",
                    execution_parity_signature="execution",
                    source_signature="source",
                )
                for workers in (1, 2, 4)
            )
            with patch("trigger_benchmark.calibration.validate_calibration_evidence", side_effect=evidence):
                self.assertEqual(evaluate_routing_release_gate.main(("calibrate", "--gate-root", str(root))), 0)

            calibration = document(root / "worker-calibration.json")
            self.assertEqual(mapping(calibration.get("selected"), "selected")["workers"], 4)

    def test_calibrate_when_an_incomplete_worker_has_model_or_executable_drift_rejects(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        shape = RunShape(RunPhase.CALIBRATION, specification.variants, (specification.prompts[0], specification.prompts[8]), 1, 1)
        for drift in ("model", "executable"):
            with self.subTest(drift=drift), tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
                root = Path(temporary_directory)
                for workers in (1, 2, 4):
                    write_evidence(root / f"calibration-w{workers}", make_manifest_template(make_plan(RunPhase.CALIBRATION)), RunShape(shape.phase, shape.variants, shape.prompts, shape.runs_per_query, workers))
                trials = root / "calibration-w4" / "trials.ndjson"
                trials.write_text("\n".join(trials.read_text(encoding="utf-8").splitlines()[:-1]) + "\n", encoding="utf-8")
                manifest_path = root / "calibration-w4" / "manifest.json"
                manifest = document(manifest_path)
                mapping(manifest.get("artifact_hashes"), "artifact_hashes")["trials.ndjson"] = hash_file(trials)
                if drift == "model":
                    mapping(manifest.get("execution_contract"), "execution_contract")["model"] = "other-model"
                else:
                    mapping(mapping(manifest.get("observed_environment"), "observed_environment").get("opencode"), "opencode")["command"] = ["other-opencode", "--version"]
                manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

                self.assertEqual(evaluate_routing_release_gate.main(("calibrate", "--gate-root", str(root))), 2)

    def test_calibrate_when_gate_root_is_outside_benchmark_returns_invalid_evidence(self) -> None:
        self.assertEqual(evaluate_routing_release_gate.main(("calibrate", "--gate-root", str(BENCHMARK_ROOT.parent))), 2)

    def test_evaluate_base_writes_auditable_artifacts_and_rejects_stray_targeted_evidence(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        calibration_shape = RunShape(RunPhase.CALIBRATION, specification.variants, (specification.prompts[0], specification.prompts[8]), 1, 1)
        base_shape = RunShape(RunPhase.FIXED_BASE, specification.variants, specification.prompts, 3, 4)
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            root = Path(temporary_directory)
            for workers in (1, 2, 4):
                write_evidence(root / f"calibration-w{workers}", make_manifest_template(make_plan(RunPhase.FIXED_BASE)), RunShape(calibration_shape.phase, calibration_shape.variants, calibration_shape.prompts, 1, workers))
            self.assertEqual(evaluate_routing_release_gate.main(("calibrate", "--gate-root", str(root))), 0)
            base = root / "base"
            write_evidence(base, make_manifest_template(make_plan(RunPhase.FIXED_BASE)), base_shape)
            manifest_path = base / "manifest.json"
            manifest = document(manifest_path)
            manifest["reference_manifest"] = make_reference_record(root / "calibration-w4" / "manifest.json", RunPhase.CALIBRATION)
            aggregate = base / "aggregate.json"
            aggregate.write_text("{}\n", encoding="utf-8")
            mapping(manifest.get("artifact_hashes"), "artifact_hashes")["aggregate.json"] = hash_file(aggregate)
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            result = evaluate_routing_release_gate.main(("evaluate", "--gate-root", str(root), "--stage", "base"))
            self.assertEqual(result, 0, (root / "base-decision" / "decision.json").read_text(encoding="utf-8"))

            decision = document(root / "base-decision" / "decision.json")
            decision_text = (root / "base-decision" / "decision.json").read_text(encoding="utf-8")
            self.assertEqual(mapping(decision.get("base_aggregate"), "base_aggregate")["path"], "base/aggregate.json")
            counts = mapping(decision.get("fixed_base_counts"), "fixed_base_counts")
            candidate = mapping(counts.get("candidate"), "candidate")
            self.assertEqual(mapping(candidate.get("positive"), "positive")["valid"], 24)
            self.assertTrue((root / "base-decision" / "report.md").is_file())
            self.assertEqual({path.name for path in (root / "base-decision").iterdir()}, {"decision.json", "report.md"})
            self.assertEqual(evaluate_routing_release_gate.main(("evaluate", "--gate-root", str(root), "--stage", "base")), 0)
            final_directory = root / "final-decision"
            final_directory.mkdir()
            (final_directory / "unexpected.txt").write_text("unexpected", encoding="utf-8")
            self.assertEqual(evaluate_routing_release_gate.main(("evaluate", "--gate-root", str(root), "--stage", "final")), 2)
            self.assertEqual({path.name for path in final_directory.iterdir()}, {"unexpected.txt"})
            (final_directory / "unexpected.txt").unlink()
            final_directory.rmdir()
            report_path = root / "base-decision" / "report.md"
            report = report_path.read_text(encoding="utf-8")
            report_path.unlink()
            self.assertEqual(evaluate_routing_release_gate.main(("evaluate", "--gate-root", str(root), "--stage", "final")), 2)
            report_path.write_text(report, encoding="utf-8")
            mapping(decision.get("base_aggregate"), "base_aggregate")["sha256"] = "0" * 64
            (root / "base-decision" / "decision.json").write_text(json.dumps(decision), encoding="utf-8")
            self.assertEqual(evaluate_routing_release_gate.main(("evaluate", "--gate-root", str(root), "--stage", "final")), 2)
            (root / "base-decision" / "decision.json").write_text(decision_text, encoding="utf-8")
            (root / "base-decision" / "unexpected.txt").write_text("unexpected", encoding="utf-8")
            self.assertEqual(evaluate_routing_release_gate.main(("evaluate", "--gate-root", str(root), "--stage", "final")), 2)
            (root / "base-decision" / "unexpected.txt").unlink()
            (root / "targeted").mkdir()
            self.assertEqual(evaluate_routing_release_gate.main(("evaluate", "--gate-root", str(root), "--stage", "final")), 2)

    def test_evaluate_when_nonselected_calibration_artifact_is_deleted_or_drifted_rejects(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        calibration_shape = RunShape(RunPhase.CALIBRATION, specification.variants, (specification.prompts[0], specification.prompts[8]), 1, 4)
        base_shape = RunShape(RunPhase.FIXED_BASE, specification.variants, specification.prompts, 3, 4)
        for case in ("deleted", "model-drift"):
            with self.subTest(case=case), tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
                root = Path(temporary_directory)
                for workers in (1, 2, 4):
                    write_evidence(root / f"calibration-w{workers}", make_manifest_template(make_plan(RunPhase.CALIBRATION)), RunShape(calibration_shape.phase, calibration_shape.variants, calibration_shape.prompts, calibration_shape.runs_per_query, workers))
                self.assertEqual(evaluate_routing_release_gate.main(("calibrate", "--gate-root", str(root))), 0)
                base = root / "base"
                write_evidence(base, make_manifest_template(make_plan(RunPhase.FIXED_BASE)), base_shape)
                base_manifest = document(base / "manifest.json")
                base_manifest["reference_manifest"] = make_reference_record(root / "calibration-w4" / "manifest.json", RunPhase.CALIBRATION)
                aggregate = base / "aggregate.json"
                aggregate.write_text("{}\n", encoding="utf-8")
                mapping(base_manifest.get("artifact_hashes"), "artifact_hashes")["aggregate.json"] = hash_file(aggregate)
                (base / "manifest.json").write_text(json.dumps(base_manifest), encoding="utf-8")
                if case == "deleted":
                    (root / "calibration-w1" / "manifest.json").unlink()
                else:
                    manifest_path = root / "calibration-w1" / "manifest.json"
                    manifest = document(manifest_path)
                    mapping(manifest.get("execution_contract"), "execution_contract")["model"] = "other-model"
                    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

                self.assertEqual(evaluate_routing_release_gate.main(("evaluate", "--gate-root", str(root), "--stage", "base")), 2)

    def test_evaluate_when_calibration_artifact_selects_a_lower_complete_worker_rejects(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        calibration_shape = RunShape(RunPhase.CALIBRATION, specification.variants, (specification.prompts[0], specification.prompts[8]), 1, 4)
        base_shape = RunShape(RunPhase.FIXED_BASE, specification.variants, specification.prompts, 3, 4)
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            root = Path(temporary_directory)
            for workers in (1, 2, 4):
                write_evidence(root / f"calibration-w{workers}", make_manifest_template(make_plan(RunPhase.CALIBRATION)), RunShape(calibration_shape.phase, calibration_shape.variants, calibration_shape.prompts, calibration_shape.runs_per_query, workers))
            self.assertEqual(evaluate_routing_release_gate.main(("calibrate", "--gate-root", str(root))), 0)
            calibration_path = root / "worker-calibration.json"
            calibration = document(calibration_path)
            entries = calibration.get("entries")
            if not isinstance(entries, list) or not isinstance(entries[1], dict):
                self.fail("calibration entries must retain a worker-two record")
            calibration["selected"] = entries[1]
            calibration_path.write_text(json.dumps(calibration), encoding="utf-8")
            base = root / "base"
            write_evidence(base, make_manifest_template(make_plan(RunPhase.FIXED_BASE)), base_shape)
            base_manifest = document(base / "manifest.json")
            base_manifest["reference_manifest"] = make_reference_record(root / "calibration-w2" / "manifest.json", RunPhase.CALIBRATION)
            aggregate = base / "aggregate.json"
            aggregate.write_text("{}\n", encoding="utf-8")
            mapping(base_manifest.get("artifact_hashes"), "artifact_hashes")["aggregate.json"] = hash_file(aggregate)
            (base / "manifest.json").write_text(json.dumps(base_manifest), encoding="utf-8")

            self.assertEqual(evaluate_routing_release_gate.main(("evaluate", "--gate-root", str(root), "--stage", "base")), 2)


def _calibration_evidence(root: Path, shape: RunShape, *, complete: bool, environment_signature: str, execution_parity_signature: str, source_signature: str) -> ValidatedEvidence:
    return ValidatedEvidence(
        root,
        RunPhase.CALIBRATION,
        shape,
        (),
        environment_signature,
        "execution-with-workers",
        execution_parity_signature,
        source_signature,
        None,
        complete,
    )
