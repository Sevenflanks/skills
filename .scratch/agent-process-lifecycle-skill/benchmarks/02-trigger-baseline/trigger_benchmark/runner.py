from __future__ import annotations

import argparse
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path
from .execution import RunExecutionError, RunExecutionPlan, execute_run
from .models import Prompt, RunOptions, RunPhase, RunShape, Specification, Variant
from .phase import PhaseShapeError, validate_phase_shape
from .spec import SpecificationError, load_specification


BENCHMARK_ROOT = Path(__file__).resolve().parents[1]


def main(arguments: Sequence[str] | None = None) -> int:
    """Run only a phase shape that was validated before any model dispatch."""
    try:
        options = _parse_options(arguments)
        specification = load_specification(BENCHMARK_ROOT)
        variants = _select_variants(specification, options)
        prompts = _select_prompts(specification, options)
        validate_phase_shape(RunShape(options.phase, variants, prompts, options.runs_per_query, options.workers))
        _validate_reference_requirement(options)
        return execute_run(RunExecutionPlan(BENCHMARK_ROOT, options, specification, variants, prompts))
    except (PhaseShapeError, RunExecutionError, SpecificationError, ValueError) as error:
        print(error)
        return 2


def _parse_options(arguments: Sequence[str] | None) -> RunOptions:
    parser = argparse.ArgumentParser(description="Run the scratch-only deterministic OpenCode routing benchmark.")
    parser.add_argument("--phase", choices=tuple(phase.value for phase in RunPhase), default=RunPhase.EXPLORATORY.value)
    parser.add_argument("--runs-per-query", type=int)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--timeout-seconds", type=float, default=90.0)
    parser.add_argument("--retries", type=int, default=1)
    parser.add_argument("--seed", type=int, default=20260728)
    parser.add_argument("--output-dir", default=f"results/run-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}")
    parser.add_argument("--model", default="openai/gpt-5.6-sol")
    parser.add_argument("--variant", action="append", default=[])
    parser.add_argument("--prompt", action="append", default=[])
    parser.add_argument("--reference-manifest")
    parsed = parser.parse_args(arguments)
    phase = RunPhase(parsed.phase)
    runs = parsed.runs_per_query if parsed.runs_per_query is not None else _default_runs(phase)
    output_path = Path(parsed.output_dir)
    output_directory = output_path.resolve() if output_path.is_absolute() else (BENCHMARK_ROOT / output_path).resolve()
    if not output_directory.is_relative_to(BENCHMARK_ROOT) or runs < 1 or parsed.workers < 1 or parsed.timeout_seconds <= 0 or parsed.retries < 0:
        raise ValueError("output and numeric options are outside benchmark bounds")
    reference_path = Path(parsed.reference_manifest) if parsed.reference_manifest else None
    reference = reference_path.resolve() if reference_path and reference_path.is_absolute() else (BENCHMARK_ROOT / reference_path).resolve() if reference_path else None
    if reference is not None and not reference.is_relative_to(BENCHMARK_ROOT):
        raise ValueError("--reference-manifest must remain under the benchmark root")
    return RunOptions(phase, runs, parsed.workers, parsed.timeout_seconds, parsed.retries, parsed.seed, output_directory, parsed.model, tuple(parsed.variant), tuple(parsed.prompt), reference)


def _validate_reference_requirement(options: RunOptions) -> None:
    match options.phase:
        case RunPhase.FIXED_BASE | RunPhase.TARGETED:
            if options.reference_manifest is None:
                raise ValueError("this phase requires --reference-manifest")
        case RunPhase.CALIBRATION | RunPhase.EXPLORATORY:
            if options.reference_manifest is not None:
                raise ValueError("this phase must not accept --reference-manifest")


def _select_variants(specification: Specification, options: RunOptions) -> tuple[Variant, ...]:
    selected_ids = options.variant_ids or _default_variant_ids(options.phase)
    if len(set(selected_ids)) != len(selected_ids):
        raise ValueError("requested variants are duplicated")
    selected = tuple(variant for variant in specification.variants if variant.id in selected_ids)
    if len(selected) != len(selected_ids):
        raise ValueError("requested variants are missing")
    return selected


def _select_prompts(specification: Specification, options: RunOptions) -> tuple[Prompt, ...]:
    selected_ids = options.prompt_ids or _default_prompt_ids(options.phase, specification)
    if len(set(selected_ids)) != len(selected_ids):
        raise ValueError("requested prompts are duplicated")
    selected = tuple(prompt for prompt in specification.prompts if prompt.id in selected_ids)
    if len(selected) != len(selected_ids):
        raise ValueError("requested prompts are missing")
    return selected


def _default_runs(phase: RunPhase) -> int:
    match phase:
        case RunPhase.CALIBRATION:
            return 1
        case RunPhase.FIXED_BASE:
            return 3
        case RunPhase.TARGETED:
            return 7
        case RunPhase.EXPLORATORY:
            return 3


def _default_variant_ids(phase: RunPhase) -> tuple[str, ...]:
    match phase:
        case RunPhase.TARGETED:
            return ("candidate",)
        case RunPhase.CALIBRATION | RunPhase.FIXED_BASE | RunPhase.EXPLORATORY:
            return "current", "candidate"


def _default_prompt_ids(phase: RunPhase, specification: Specification) -> tuple[str, ...]:
    match phase:
        case RunPhase.CALIBRATION:
            return "listener-local-server", "sync-long-command"
        case RunPhase.TARGETED:
            raise ValueError("targeted phase requires exactly one --prompt")
        case RunPhase.FIXED_BASE | RunPhase.EXPLORATORY:
            return tuple(prompt.id for prompt in specification.prompts)
