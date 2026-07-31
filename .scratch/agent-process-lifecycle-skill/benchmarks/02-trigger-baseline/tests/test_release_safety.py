from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))

from evidence_fixtures import make_valid_records
from trigger_benchmark.aggregate import aggregate_trials
from trigger_benchmark.models import AttemptStatus, RunPhase, RunShape, TrialRecord
from trigger_benchmark.release_gate import GateOutcome, evaluate_base
from trigger_benchmark.spec import load_specification


class ReleaseSafetyTests(unittest.TestCase):
    def test_invalid_candidate_negative_selection_with_non_skill_tools_blocks_without_changing_denominator(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        shape = RunShape(RunPhase.FIXED_BASE, specification.variants, specification.prompts, 3, 1)
        base_records = make_valid_records(shape)
        for status in (AttemptStatus.INVALID_TIMEOUT, AttemptStatus.INVALID_PROCESS_FAILURE):
            with self.subTest(status=status):
                record = TrialRecord.invalid(
                    "candidate",
                    "ide-owned-service",
                    "negative",
                    3,
                    2,
                    status,
                    candidate_selected=True,
                    tool_uses=("skill", "bash"),
                    non_skill_tool_uses=("bash",),
                )
                report = aggregate_trials([*base_records, record], specification)
                metric = report["variants"]["candidate"]["negative"]
                decision = evaluate_base(specification, (*base_records, record))

                self.assertEqual((metric["valid_trials"], metric["invalid_attempts"]), (24, 1))
                self.assertEqual(decision.outcome, GateOutcome.BLOCK)
                self.assertTrue(any("non-skill" in reason for reason in decision.reasons))
