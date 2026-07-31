from __future__ import annotations

from .models import RunPhase, RunShape


class PhaseShapeError(Exception):
    """Raised before an executable phase can dispatch a model call."""


def validate_phase_shape(shape: RunShape) -> None:
    """Require the release protocol's fixed matrix shape for each gated phase."""
    variant_ids = tuple(variant.id for variant in shape.variants)
    prompt_ids = tuple(prompt.id for prompt in shape.prompts)
    match shape.phase:
        case RunPhase.CALIBRATION:
            if variant_ids != ("current", "candidate") or prompt_ids != ("listener-local-server", "sync-long-command") or shape.runs_per_query != 1 or shape.workers not in {1, 2, 4}:
                raise PhaseShapeError("calibration requires both variants, two probe prompts, one run, and workers 1, 2, or 4")
        case RunPhase.FIXED_BASE:
            if variant_ids != ("current", "candidate") or len(prompt_ids) != 16 or shape.runs_per_query != 3:
                raise PhaseShapeError("fixed-base requires both variants, all prompts, and exactly three runs")
        case RunPhase.TARGETED:
            if variant_ids != ("candidate",) or len(prompt_ids) != 1 or shape.runs_per_query != 7:
                raise PhaseShapeError("targeted requires candidate, one prompt, and exactly seven runs")
        case RunPhase.EXPLORATORY:
            return
