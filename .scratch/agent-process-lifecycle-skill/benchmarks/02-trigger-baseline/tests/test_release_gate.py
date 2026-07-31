from __future__ import annotations

import sys
import unittest
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))

from trigger_benchmark.models import AttemptStatus, Specification, TrialRecord
from trigger_benchmark.release_gate import CalibrationInput, GateOutcome, evaluate_base, evaluate_final, select_calibration
from trigger_benchmark.spec import load_specification


class ReleaseGateTests(unittest.TestCase):
    def test_candidate_positive_aggregate_when_twenty_three_of_twenty_four_passes_and_twenty_two_blocks(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        cases = (
            ({"listener-local-server": 2}, GateOutcome.TARGETED_REQUIRED),
            ({"listener-local-server": 2, "gui-local-app": 2}, GateOutcome.BLOCK),
        )

        for counts, expected_outcome in cases:
            with self.subTest(candidate_positive_counts=counts):
                decision = evaluate_base(specification, _base_records(specification, _BaseCounts(candidate_positive=counts)))

                self.assertEqual(decision.outcome, expected_outcome)
        self.assertEqual(len(_base_records(specification)), 96)

    def test_positive_prompt_when_three_two_one_or_zero_triggers_applies_approved_base_rule(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        cases = (
            (3, GateOutcome.PASS),
            (2, GateOutcome.TARGETED_REQUIRED),
            (1, GateOutcome.BLOCK),
            (0, GateOutcome.BLOCK),
        )

        for prompt_id in (prompt.id for prompt in specification.prompts if prompt.label == "positive"):
            for triggered, expected_outcome in cases:
                with self.subTest(prompt_id=prompt_id, triggered=triggered):
                    decision = evaluate_base(specification, _base_records(specification, _BaseCounts(candidate_positive={prompt_id: triggered})))

                    self.assertEqual(decision.outcome, expected_outcome)
                    self.assertEqual(decision.targeted_prompt_ids, (prompt_id,) if triggered == 2 else ())

    def test_candidate_negative_aggregate_when_lower_or_equal_passes_and_higher_blocks_by_cross_multiplication(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        prompt_id = "sync-long-command"
        cases = (
            (1, 2, GateOutcome.PASS),
            (2, 2, GateOutcome.TARGETED_REQUIRED),
            (2, 1, GateOutcome.BLOCK),
        )

        for candidate_triggered, current_triggered, expected_outcome in cases:
            with self.subTest(candidate_triggered=candidate_triggered, current_triggered=current_triggered):
                decision = evaluate_base(
                    specification,
                    _base_records(
                        specification,
                        _BaseCounts(
                            candidate_negative={prompt_id: candidate_triggered},
                            current_negative={prompt_id: current_triggered},
                        ),
                    ),
                )

                self.assertEqual(decision.outcome, expected_outcome)

    def test_negative_prompt_when_three_two_one_or_zero_false_triggers_applies_approved_base_rule(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        cases = (
            (3, GateOutcome.BLOCK),
            (2, GateOutcome.TARGETED_REQUIRED),
            (1, GateOutcome.PASS),
            (0, GateOutcome.PASS),
        )

        for prompt_id in (prompt.id for prompt in specification.prompts if prompt.label == "negative"):
            for triggered, expected_outcome in cases:
                with self.subTest(prompt_id=prompt_id, triggered=triggered):
                    decision = evaluate_base(
                        specification,
                        _base_records(
                            specification,
                            _BaseCounts(
                                candidate_negative={prompt_id: triggered},
                                current_negative={prompt_id: triggered},
                            ),
                        ),
                    )

                    self.assertEqual(decision.outcome, expected_outcome)
                    self.assertEqual(decision.targeted_prompt_ids, (prompt_id,) if triggered == 2 else ())

    def test_targeted_positive_total_when_nine_of_ten_passes_and_eight_of_ten_blocks(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        prompt_id = "listener-local-server"
        base_records = _base_records(specification, _BaseCounts(candidate_positive={prompt_id: 2}))
        cases = ((7, GateOutcome.PASS), (6, GateOutcome.BLOCK))

        for targeted_triggered, expected_outcome in cases:
            with self.subTest(targeted_triggered=targeted_triggered):
                decision = evaluate_final(
                    specification,
                    base_records,
                    _targeted_records(prompt_id, "positive", targeted_triggered),
                )

                self.assertEqual(decision.outcome, expected_outcome)

    def test_targeted_negative_total_when_three_of_ten_passes_and_four_of_ten_blocks(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        prompt_id = "sync-long-command"
        base_records = _base_records(
            specification,
            _BaseCounts(
                candidate_negative={prompt_id: 2},
                current_negative={prompt_id: 2},
            ),
        )
        cases = ((1, GateOutcome.PASS), (2, GateOutcome.BLOCK))

        for targeted_triggered, expected_outcome in cases:
            with self.subTest(targeted_triggered=targeted_triggered):
                decision = evaluate_final(
                    specification,
                    base_records,
                    _targeted_records(prompt_id, "negative", targeted_triggered),
                )

                self.assertEqual(decision.outcome, expected_outcome)

    def test_targeted_evaluation_preserves_fixed_candidate_positive_aggregate(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        prompt_id = "listener-local-server"
        base_records = _base_records(specification, _BaseCounts(candidate_positive={prompt_id: 2}))
        base = evaluate_base(specification, base_records)

        decision = evaluate_final(specification, base_records, _targeted_records(prompt_id, "positive", 7))

        self.assertEqual(decision.outcome, GateOutcome.PASS)
        self.assertEqual(
            (decision.candidate_positive_triggered, decision.candidate_positive_valid),
            (base.candidate_positive_triggered, base.candidate_positive_valid),
        )

    def test_invalid_attempts_are_excluded_from_release_threshold_denominators(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        prompt_id = "listener-local-server"
        records = _base_records(specification, _BaseCounts(candidate_positive={prompt_id: 2})) + (
            TrialRecord.invalid("candidate", prompt_id, "positive", 3, 2, AttemptStatus.INVALID_TIMEOUT, candidate_selected=False),
        )

        decision = evaluate_base(specification, records)

        self.assertEqual(decision.outcome, GateOutcome.TARGETED_REQUIRED)
        self.assertEqual((decision.candidate_positive_triggered, decision.candidate_positive_valid), (23, 24))

    def test_targeted_prompt_ids_follow_specification_order(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        counts = {"sync-long-command": 2, "observe-external-service": 2}
        records = tuple(reversed(_base_records(specification, _BaseCounts(candidate_negative=counts, current_negative=counts))))

        decision = evaluate_base(specification, records)

        self.assertEqual(decision.outcome, GateOutcome.TARGETED_REQUIRED)
        self.assertEqual(decision.targeted_prompt_ids, ("sync-long-command", "observe-external-service"))

    def test_calibration_selects_highest_complete_parity_worker_and_serializes_only_calibration_data(self) -> None:
        decision = select_calibration(
            (
                CalibrationInput(workers=1, is_complete=True, has_reference_parity=True, manifest_path="one/manifest.json"),
                CalibrationInput(workers=2, is_complete=True, has_reference_parity=True, manifest_path="two/manifest.json"),
                CalibrationInput(workers=4, is_complete=False, has_reference_parity=True, manifest_path="four/manifest.json"),
            )
        )

        self.assertEqual(decision.outcome, GateOutcome.PASS)
        self.assertEqual(decision.selected_workers, 2)
        self.assertEqual(decision.manifest_path, "two/manifest.json")
        self.assertEqual(
            set(decision.to_document()),
            {"outcome", "exit_code", "selected_workers", "manifest_path"},
        )

    def test_calibration_when_no_complete_parity_worker_blocks_with_exit_one(self) -> None:
        decision = select_calibration(
            (CalibrationInput(workers=4, is_complete=False, has_reference_parity=True, manifest_path="four/manifest.json"),)
        )

        self.assertEqual((decision.outcome, decision.exit_code), (GateOutcome.BLOCK, 1))

    def test_calibration_when_an_incomplete_worker_has_parity_drift_returns_invalid_evidence(self) -> None:
        decision = select_calibration(
            (
                CalibrationInput(workers=1, is_complete=True, has_reference_parity=True, manifest_path="one/manifest.json"),
                CalibrationInput(workers=2, is_complete=True, has_reference_parity=True, manifest_path="two/manifest.json"),
                CalibrationInput(workers=4, is_complete=False, has_reference_parity=False, manifest_path="four/manifest.json"),
            )
        )

        self.assertEqual((decision.outcome, decision.exit_code), (GateOutcome.BLOCK, 2))

    def test_base_gate_when_candidate_negative_false_trigger_uses_non_skill_tool_blocks_safety(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        records = list(_base_records(specification))
        records[-1] = TrialRecord.valid(
            "candidate",
            "ide-owned-service",
            "negative",
            3,
            1,
            True,
            tool_uses=("skill", "bash"),
            non_skill_tool_uses=("bash",),
        )

        decision = evaluate_base(specification, tuple(records))

        self.assertEqual(decision.outcome, GateOutcome.BLOCK)
        self.assertEqual(decision.exit_code, 1)
        self.assertIn("non-skill", decision.reasons[0])


@dataclass(frozen=True, slots=True)
class _BaseCounts:
    candidate_positive: Mapping[str, int] | None = None
    candidate_negative: Mapping[str, int] | None = None
    current_negative: Mapping[str, int] | None = None


def _base_records(specification: Specification, counts: _BaseCounts = _BaseCounts()) -> tuple[TrialRecord, ...]:
    candidate_positive_counts: Mapping[str, int] = {} if counts.candidate_positive is None else counts.candidate_positive
    candidate_negative_counts: Mapping[str, int] = {} if counts.candidate_negative is None else counts.candidate_negative
    current_negative_counts: Mapping[str, int] = {} if counts.current_negative is None else counts.current_negative
    records: list[TrialRecord] = []
    for variant in specification.variants:
        for prompt in specification.prompts:
            triggered_count = 3 if prompt.label == "positive" else 0
            if variant.id == "candidate":
                triggered_counts = candidate_positive_counts if prompt.label == "positive" else candidate_negative_counts
                triggered_count = triggered_counts.get(prompt.id, triggered_count)
            elif prompt.label == "negative":
                triggered_count = current_negative_counts.get(prompt.id, 0)
            for logical_run in range(1, 4):
                records.append(TrialRecord.valid(variant.id, prompt.id, prompt.label, logical_run, 1, logical_run <= triggered_count))
    return tuple(records)


def _targeted_records(prompt_id: str, label: str, triggered_count: int) -> tuple[TrialRecord, ...]:
    return tuple(
        TrialRecord.valid("candidate", prompt_id, label, logical_run, 1, logical_run <= triggered_count)
        for logical_run in range(1, 8)
    )
