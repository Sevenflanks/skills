from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))

from trigger_benchmark.aggregate import aggregate_trials
from trigger_benchmark.completeness import check_matrix_completeness
from trigger_benchmark.events import classify_ndjson
from trigger_benchmark.fixture import create_fixture, fixture_skill_files
from trigger_benchmark.models import AttemptStatus, Prompt, TrialRecord, Variant
from trigger_benchmark.spec import load_specification


class TriggerBenchmarkTests(unittest.TestCase):
    def test_controls_when_loaded_match_published_metadata_and_three_way_design(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        self.assertEqual([variant.id for variant in specification.variants], ["current", "generalized-current-name", "generalized-neutral-name"])
        self.assertEqual(specification.variants[0].skill_name, "playwright-server-lifecycle")
        self.assertEqual(specification.variants[2].skill_name, "agent-process-lifecycle")
        self.assertEqual(specification.variants[0].description, specification.current_metadata.description)
        self.assertEqual(specification.variants[1].description, specification.variants[2].description)
        self.assertEqual(specification.variants[1].description.encode(), specification.variants[2].description.encode())

    def test_fixture_when_created_contains_only_candidate_skill_and_deny_by_default_policy(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        variant = specification.variants[0]
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = create_fixture(Path(temporary_directory), variant)
            self.assertEqual(fixture_skill_files(fixture.project_directory), [fixture.skill_file])
            self.assertEqual(fixture.permission_policy, {"*": "deny", "skill": "allow"})

    def test_event_detection_when_completed_skill_selects_candidate_reports_trigger(self) -> None:
        stream = "\n".join(
            [
                '{"type":"tool_use","part":{"type":"tool","tool":"skill","state":{"status":"completed","input":{"name":"agent-process-lifecycle"}}}}',
                '{"type":"step_finish","part":{"type":"step-finish","reason":"stop"}}',
            ]
        )

        result = classify_ndjson(stream, "agent-process-lifecycle")
        self.assertTrue(result.stream_is_valid)
        self.assertTrue(result.triggered)

    def test_invalid_attempts_when_stream_or_process_is_incomplete_are_not_non_triggers(self) -> None:
        cases = [
            ('{"type":"step_finish"\n', 0, AttemptStatus.INVALID_MALFORMED_STREAM),
            ('{"type":"text","part":{"type":"text","text":"done"}}\n', 0, AttemptStatus.INVALID_MISSING_COMPLETION),
            ('{"type":"step_finish","part":{"type":"step-finish","reason":"stop"}}\n', 9, AttemptStatus.INVALID_PROCESS_FAILURE),
        ]
        for stdout, return_code, expected_status in cases:
            with self.subTest(expected_status=expected_status):
                result = TrialRecord.from_completed_process(
                    variant_id="current",
                    prompt_id="listener-local-server",
                    label="positive",
                    logical_run=1,
                    attempt=1,
                    command=("opencode", "run"),
                    stdout=stdout,
                    stderr="",
                    return_code=return_code,
                    duration_seconds=0.1,
                    candidate_name="playwright-server-lifecycle",
                )

                self.assertIs(result.status, expected_status)
                self.assertIsNone(result.triggered)

    def test_aggregation_when_trials_include_invalid_attempts_separates_rates(self) -> None:
        records = [
            TrialRecord.valid("current", "listener-local-server", "positive", 1, 1, True),
            TrialRecord.valid("current", "listener-local-server", "positive", 2, 1, False),
            TrialRecord.valid("current", "sync-long-command", "negative", 1, 1, True),
            TrialRecord.valid("current", "sync-long-command", "negative", 2, 1, False),
            TrialRecord.invalid("current", "sync-long-command", "negative", 3, 1, AttemptStatus.INVALID_TIMEOUT),
        ]
        specification = load_specification(BENCHMARK_ROOT)
        report = aggregate_trials(records, specification)
        current = report["variants"]["current"]
        self.assertEqual(current["positive"]["trigger_rate"], 0.5)
        self.assertEqual(current["negative"]["false_trigger_rate"], 0.5)
        self.assertEqual(current["negative"]["invalid_attempts"], 1)

    def test_completeness_when_specification_loads_has_required_scenarios(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        positive_ids = [prompt.id for prompt in specification.prompts if prompt.label == "positive"]
        negative_ids = [prompt.id for prompt in specification.prompts if prompt.label == "negative"]
        self.assertEqual(positive_ids, [
            "listener-local-server",
            "gui-local-app",
            "watcher-without-port",
            "finite-detached-job",
            "timeout-residual-process",
            "keep-running-handoff",
            "orphan-wrapper",
            "readiness-failure",
        ])
        self.assertEqual(negative_ids, [
            "sync-long-command",
            "observe-external-service",
            "framework-complete-ownership",
            "docker-runtime",
            "kubernetes-runtime",
            "windows-service-runtime",
            "remote-ci",
            "ide-owned-service",
        ])

    def test_prompt_controls_when_loaded_have_unique_ids_bodies_and_no_candidate_name(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        ids = [prompt.id for prompt in specification.prompts]
        bodies = [prompt.body for prompt in specification.prompts]
        candidate_names = {variant.skill_name for variant in specification.variants}
        self.assertEqual(len(ids), 16)
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(len(bodies), len(set(bodies)))
        self.assertFalse(any(name in body for name in candidate_names for body in bodies))

    def test_matrix_completeness_when_full_default_matrix_has_one_valid_trial_per_cell(self) -> None:
        variants = (Variant("one", "one-skill", "one"), Variant("two", "two-skill", "two"), Variant("three", "three-skill", "three"))
        prompts = tuple(Prompt(f"prompt-{index}", "positive", f"body-{index}") for index in range(16))
        records = [TrialRecord.valid(variant.id, prompt.id, prompt.label, logical_run, 1, True) for variant in variants for prompt in prompts for logical_run in range(1, 4)]
        result = check_matrix_completeness(records, variants, prompts, 3)
        self.assertTrue(result.is_complete)
        self.assertEqual(result.expected_cells, 144)

    def test_matrix_completeness_when_cell_has_no_valid_trial_blocks_finalization(self) -> None:
        variants = (Variant("one", "one-skill", "one"),)
        prompts = (Prompt("prompt", "positive", "body"),)
        records = [TrialRecord.invalid("one", "prompt", "positive", 1, 1, AttemptStatus.INVALID_TIMEOUT)]
        result = check_matrix_completeness(records, variants, prompts, 1)
        self.assertFalse(result.is_complete)
        self.assertEqual(result.missing_cells, ("one::prompt::run-1",))
