from __future__ import annotations

from collections import defaultdict
from itertools import combinations
from typing import TypedDict

from .models import Specification, TrialRecord


class Metric(TypedDict):
    requested_logical_runs: int
    valid_trials: int
    triggered_trials: int
    invalid_attempts: int
    trigger_rate: float | None
    false_trigger_rate: float | None


class VariantRates(TypedDict):
    positive: Metric
    negative: Metric


class RateDelta(TypedDict):
    positive_trigger_rate_delta: float | None
    negative_false_trigger_rate_delta: float | None


class AggregateReport(TypedDict):
    variants: dict[str, VariantRates]
    prompts: dict[str, dict[str, Metric]]
    pairwise_rate_deltas: dict[str, RateDelta]


def aggregate_trials(records: list[TrialRecord], specification: Specification) -> AggregateReport:
    """Aggregate valid denominators separately for lifecycle and near-miss prompts."""
    grouped: dict[tuple[str, str, str], list[TrialRecord]] = defaultdict(list)
    for record in records:
        grouped[(record.variant_id, record.prompt_id, record.label)].append(record)
    variants: dict[str, VariantRates] = {}
    prompts: dict[str, dict[str, Metric]] = {}
    for variant in specification.variants:
        variant_records = [record for record in records if record.variant_id == variant.id]
        variants[variant.id] = {
            "positive": _metrics([record for record in variant_records if record.label == "positive"], "trigger_rate"),
            "negative": _metrics([record for record in variant_records if record.label == "negative"], "false_trigger_rate"),
        }
        prompts[variant.id] = {
            prompt.id: _metrics(grouped[(variant.id, prompt.id, prompt.label)], _rate_key(prompt.label))
            for prompt in specification.prompts
        }
    comparisons = {
        f"{left.id}__to__{right.id}": _comparison(variants[left.id], variants[right.id])
        for left, right in combinations(specification.variants, 2)
    }
    return {"variants": variants, "prompts": prompts, "pairwise_rate_deltas": comparisons}


def _metrics(records: list[TrialRecord], rate_key: str) -> Metric:
    valid = [record for record in records if record.is_valid]
    triggered = sum(record.triggered is True for record in valid)
    rate = triggered / len(valid) if valid else None
    metric: Metric = {
        "requested_logical_runs": len({(record.logical_run, record.prompt_id) for record in records}),
        "valid_trials": len(valid),
        "triggered_trials": triggered,
        "invalid_attempts": len(records) - len(valid),
        "trigger_rate": rate if rate_key == "trigger_rate" else None,
        "false_trigger_rate": rate if rate_key == "false_trigger_rate" else None,
    }
    return metric


def _rate_key(label: str) -> str:
    return "trigger_rate" if label == "positive" else "false_trigger_rate"


def _comparison(left: VariantRates, right: VariantRates) -> RateDelta:
    return {
        "positive_trigger_rate_delta": _delta(left["positive"]["trigger_rate"], right["positive"]["trigger_rate"]),
        "negative_false_trigger_rate_delta": _delta(left["negative"]["false_trigger_rate"], right["negative"]["false_trigger_rate"]),
    }


def _delta(left: float | int | None, right: float | int | None) -> float | None:
    if isinstance(left, float) and isinstance(right, float):
        return right - left
    return None


def markdown_report(report: AggregateReport) -> str:
    """Render a compact human-auditable companion to aggregate.json."""
    lines = ["# OpenCode Trigger Baseline", "", "## Variant Rates", "", "| Variant | Positive trigger rate | Negative false-trigger rate |", "| --- | ---: | ---: |"]
    for variant_id, rates in report["variants"].items():
        lines.append(f"| {variant_id} | {_format_rate(rates['positive']['trigger_rate'])} | {_format_rate(rates['negative']['false_trigger_rate'])} |")
    lines.extend(["", "## Pairwise Rate Deltas", "", "Positive and negative deltas are right minus left.", "", "| Comparison | Positive delta | Negative delta |", "| --- | ---: | ---: |"])
    for comparison, values in report["pairwise_rate_deltas"].items():
        lines.append(f"| {comparison} | {_format_rate(values['positive_trigger_rate_delta'])} | {_format_rate(values['negative_false_trigger_rate_delta'])} |")
    return "\n".join(lines) + "\n"


def _format_rate(value: float | int | None) -> str:
    return "n/a" if value is None else f"{float(value):.3f}"
