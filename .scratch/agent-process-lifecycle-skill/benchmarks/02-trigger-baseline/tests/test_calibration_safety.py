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
from trigger_benchmark.evidence import ValidatedEvidence
from trigger_benchmark.evidence_format import document
from trigger_benchmark.models import AttemptStatus, RunPhase, RunShape, TrialRecord
from trigger_benchmark.spec import load_specification


class CalibrationSafetyTests(unittest.TestCase):
    def test_calibration_when_candidate_negative_selection_uses_non_skill_tools_rejects_valid_and_invalid_attempts(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        prompts = (specification.prompts[0], specification.prompts[8])
        cases = (
            ("valid", TrialRecord.valid("candidate", "sync-long-command", "negative", 1, 1, True, tool_uses=("skill", "bash"), non_skill_tool_uses=("bash",))),
            ("invalid", TrialRecord.invalid("candidate", "sync-long-command", "negative", 1, 1, AttemptStatus.INVALID_TIMEOUT, candidate_selected=True, tool_uses=("skill", "bash"), non_skill_tool_uses=("bash",))),
        )
        for case, unsafe_record in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
                root = Path(temporary_directory)
                for workers in (1, 2, 4):
                    directory = root / f"calibration-w{workers}"
                    directory.mkdir()
                    (directory / "manifest.json").write_text("{}", encoding="utf-8")
                evidence = tuple(
                    _calibration_evidence(
                        root / f"calibration-w{workers}",
                        RunShape(RunPhase.CALIBRATION, specification.variants, prompts, 1, workers),
                        (unsafe_record,) if workers == 4 else (),
                    )
                    for workers in (1, 2, 4)
                )

                with patch("trigger_benchmark.calibration.validate_calibration_evidence", side_effect=evidence):
                    self.assertEqual(evaluate_routing_release_gate.main(("calibrate", "--gate-root", str(root))), 2)

                calibration = document(root / "worker-calibration.json")
                self.assertEqual(calibration.get("reasons"), ["calibration evidence is invalid"])
                self.assertNotIn("triggered", json.dumps(calibration))


def _calibration_evidence(root: Path, shape: RunShape, records: tuple[TrialRecord, ...]) -> ValidatedEvidence:
    return ValidatedEvidence(root, RunPhase.CALIBRATION, shape, records, "environment", "execution-with-workers", "execution", "source", None, True)
