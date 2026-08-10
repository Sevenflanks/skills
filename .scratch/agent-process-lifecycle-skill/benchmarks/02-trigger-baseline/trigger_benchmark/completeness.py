from __future__ import annotations

from dataclasses import dataclass

from .models import Prompt, TrialRecord, Variant


@dataclass(frozen=True, slots=True)
class MatrixCompleteness:
    expected_cells: int
    missing_cells: tuple[str, ...]
    duplicate_valid_cells: tuple[str, ...]

    @property
    def is_complete(self) -> bool:
        return not self.missing_cells and not self.duplicate_valid_cells


def check_matrix_completeness(records: list[TrialRecord], variants: tuple[Variant, ...], prompts: tuple[Prompt, ...], runs_per_query: int) -> MatrixCompleteness:
    """Require exactly one valid trial for every requested matrix cell."""
    expected = [(variant.id, prompt.id, logical_run) for variant in variants for prompt in prompts for logical_run in range(1, runs_per_query + 1)]
    valid_counts = {
        cell: sum(record.is_valid and (record.variant_id, record.prompt_id, record.logical_run) == cell for record in records)
        for cell in expected
    }
    missing = tuple(_cell_name(cell) for cell, count in valid_counts.items() if count == 0)
    duplicates = tuple(_cell_name(cell) for cell, count in valid_counts.items() if count > 1)
    return MatrixCompleteness(len(expected), missing, duplicates)


def _cell_name(cell: tuple[str, str, int]) -> str:
    return f"{cell[0]}::{cell[1]}::run-{cell[2]}"
