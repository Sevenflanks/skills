from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from enum import StrEnum
from typing import TypedDict

from .models import Specification, TrialRecord


class GateOutcome(StrEnum):
    PASS = "pass"
    BLOCK = "block"
    TARGETED_REQUIRED = "targeted_required"


class CalibrationDocument(TypedDict):
    outcome: str
    exit_code: int
    selected_workers: int | None
    manifest_path: str | None


@dataclass(frozen=True, slots=True)
class CalibrationInput:
    workers: int
    is_complete: bool
    has_reference_parity: bool
    manifest_path: str


@dataclass(frozen=True, slots=True)
class CalibrationDecision:
    outcome: GateOutcome
    exit_code: int
    selected_workers: int | None
    manifest_path: str | None

    def to_document(self) -> CalibrationDocument:
        return {"outcome": self.outcome, "exit_code": self.exit_code, "selected_workers": self.selected_workers, "manifest_path": self.manifest_path}


@dataclass(frozen=True, slots=True)
class GateDecision:
    outcome: GateOutcome
    exit_code: int
    reasons: tuple[str, ...]
    targeted_prompt_ids: tuple[str, ...]
    candidate_positive_triggered: int
    candidate_positive_valid: int


@dataclass(frozen=True, slots=True)
class _TriggerRate:
    triggered: int
    valid: int


def select_calibration(inputs: tuple[CalibrationInput, ...]) -> CalibrationDecision:
    """Select only by complete evidence and reference parity, never outcomes."""
    if any(not entry.has_reference_parity for entry in inputs):
        return CalibrationDecision(GateOutcome.BLOCK, 2, None, None)
    selected = [entry for entry in inputs if entry.is_complete and entry.has_reference_parity]
    if not selected:
        return CalibrationDecision(GateOutcome.BLOCK, 1, None, None)
    best = max(selected, key=lambda entry: entry.workers)
    return CalibrationDecision(GateOutcome.PASS, 0, best.workers, best.manifest_path)


def evaluate_base(specification: Specification, records: tuple[TrialRecord, ...]) -> GateDecision:
    """Apply release thresholds to the immutable three-run base matrix."""
    candidate_positive = _counts(records, "candidate", "positive")
    candidate_negative = _counts(records, "candidate", "negative")
    current_negative = _counts(records, "current", "negative")
    safety_reasons = _non_skill_false_trigger_reasons(records)
    positive_total = sum(count[1] for count in candidate_positive.values())
    positive_triggered = sum(count[0] for count in candidate_positive.values())
    negative_total = sum(count[1] for count in candidate_negative.values())
    candidate_negative_triggered = sum(count[0] for count in candidate_negative.values())
    current_negative_triggered = sum(count[0] for count in current_negative.values())
    current_negative_total = sum(count[1] for count in current_negative.values())
    reasons = list(safety_reasons)
    reasons.extend(f"positive {prompt_id} has {triggered}/3 triggers" for prompt_id, (triggered, _) in candidate_positive.items() if triggered <= 1)
    reasons.extend(f"negative {prompt_id} has 3/3 false triggers" for prompt_id, (triggered, _) in candidate_negative.items() if triggered == 3)
    if not _at_least(positive_triggered, positive_total, 95):
        reasons.append("candidate positive aggregate is below 95%")
    if not _does_not_exceed(
        _TriggerRate(candidate_negative_triggered, negative_total),
        _TriggerRate(current_negative_triggered, current_negative_total),
    ):
        reasons.append("candidate negative aggregate exceeds current comparator")
    if reasons:
        return GateDecision(GateOutcome.BLOCK, 1, tuple(reasons), (), positive_triggered, positive_total)
    targeted = tuple(
        prompt.id
        for prompt in specification.prompts
        if (
            prompt.label == "positive"
            and candidate_positive[prompt.id][0] == 2
        )
        or (
            prompt.label == "negative"
            and candidate_negative[prompt.id][0] == 2
        )
    )
    outcome = GateOutcome.TARGETED_REQUIRED if targeted else GateOutcome.PASS
    exit_code = 3 if targeted else 0
    return GateDecision(outcome, exit_code, (), targeted, positive_triggered, positive_total)


def evaluate_final(specification: Specification, base_records: tuple[TrialRecord, ...], targeted_records: tuple[TrialRecord, ...]) -> GateDecision:
    """Resolve only base prompts that required their seven-run targeted extension."""
    base = evaluate_base(specification, base_records)
    if base.outcome != GateOutcome.TARGETED_REQUIRED:
        return base
    combined = base_records + targeted_records
    reasons = list(_non_skill_false_trigger_reasons(combined))
    missing_targeted = tuple(
        prompt_id
        for prompt_id in base.targeted_prompt_ids
        if _counts_for_prompt(combined, "candidate", prompt_id)[1] != 10
    )
    if missing_targeted:
        return GateDecision(
            GateOutcome.TARGETED_REQUIRED,
            3,
            (),
            missing_targeted,
            base.candidate_positive_triggered,
            base.candidate_positive_valid,
        )
    for prompt_id in base.targeted_prompt_ids:
        prompt = next(prompt for prompt in specification.prompts if prompt.id == prompt_id)
        triggered, total = _counts_for_prompt(combined, "candidate", prompt_id)
        if prompt.label == "positive" and not _at_least(triggered, total, 90):
            reasons.append(f"targeted positive {prompt_id} is below 9/10")
        if prompt.label == "negative" and not _does_not_exceed(_TriggerRate(triggered, total), _TriggerRate(3, 10)):
            reasons.append(f"targeted negative {prompt_id} exceeds 3/10")
    if reasons:
        return GateDecision(GateOutcome.BLOCK, 1, tuple(reasons), (), base.candidate_positive_triggered, base.candidate_positive_valid)
    return GateDecision(GateOutcome.PASS, 0, (), (), base.candidate_positive_triggered, base.candidate_positive_valid)


def _counts(records: tuple[TrialRecord, ...], variant_id: str, label: str) -> dict[str, tuple[int, int]]:
    grouped: dict[str, list[TrialRecord]] = defaultdict(list)
    for record in records:
        if record.variant_id == variant_id and record.label == label and record.is_valid:
            grouped[record.prompt_id].append(record)
    return {prompt_id: (sum(record.triggered is True for record in prompt_records), len(prompt_records)) for prompt_id, prompt_records in grouped.items()}


def _counts_for_prompt(records: tuple[TrialRecord, ...], variant_id: str, prompt_id: str) -> tuple[int, int]:
    selected = tuple(record for record in records if record.variant_id == variant_id and record.prompt_id == prompt_id and record.is_valid)
    return sum(record.triggered is True for record in selected), len(selected)


def _non_skill_false_trigger_reasons(records: tuple[TrialRecord, ...]) -> tuple[str, ...]:
    return tuple(f"candidate negative selection {record.prompt_id} used non-skill tools" for record in records if record.variant_id == "candidate" and record.label == "negative" and record.candidate_selected and record.non_skill_tool_uses)


def _at_least(numerator: int, denominator: int, percentage: int) -> bool:
    return denominator > 0 and numerator * 100 >= denominator * percentage


def _does_not_exceed(candidate: _TriggerRate, comparator: _TriggerRate) -> bool:
    return candidate.triggered * comparator.valid <= comparator.triggered * candidate.valid
