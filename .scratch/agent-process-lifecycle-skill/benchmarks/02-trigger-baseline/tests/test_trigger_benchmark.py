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
from trigger_benchmark.models import AttemptStatus, Prompt, RunPhase, RunShape, TrialRecord, Variant
from trigger_benchmark.runner import PhaseShapeError, validate_phase_shape
from trigger_benchmark.spec import load_specification


class TriggerBenchmarkTests(unittest.TestCase):
    def test_controls_when_loaded_match_source_frontmatters_and_two_variant_design(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        self.assertEqual([variant.id for variant in specification.variants], ["current", "candidate"])
        self.assertEqual(specification.variants[0].skill_name, "playwright-server-lifecycle")
        self.assertEqual(specification.variants[1].skill_name, "agent-process-lifecycle")
        self.assertEqual(specification.variants[0].skill_path, "../../../../skills/playwright-server-lifecycle/SKILL.md")
        self.assertEqual(specification.variants[1].skill_path, "../../candidate/agent-process-lifecycle/SKILL.md")
        self.assertEqual(
            specification.variants[1].description,
            "Use when lifecycle-decision routing is needed for an Agent-caused local OS process: a foreground local command may hang or outlive the initiating tool call, a lingering, zombie, or unclear-owner local process needs cleanup or reconciliation, or the task explicitly requests a lifecycle decision for an Agent-started or managed current-run binding. On Windows, select the first viable execution tier and handle readiness, Stop, Preserve, handoff, or reconciliation. On non-Windows, classify an Agent-caused local process only to hand off or block before launch; do not perform lifecycle execution. Do not use for a command that remains synchronous until normal exit, regardless of duration. Do not load this skill merely to classify, Preserve, observe, check status, or use a resource when the prompt already identifies a framework, IDE, Kubernetes, Docker, Windows Service, CI, or other external or runtime owner and states its complete lifecycle contract; follow that owner's contract directly.",
        )

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
        self.assertTrue(result.candidate_selected)

    def test_event_detection_when_tool_stream_contains_non_skill_tool_records_every_tool_use(self) -> None:
        stream = "\n".join(
            [
                '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{}}}}',
                '{"type":"tool_use","part":{"type":"tool","tool":"skill","state":{"status":"running","input":{"name":"agent-process-lifecycle"}}}}',
                '{"type":"tool_use","part":{"type":"tool","tool":"skill","state":{"status":"completed","input":{"name":"agent-process-lifecycle"}}}}',
                '{"type":"step_finish","part":{"type":"step-finish","reason":"stop"}}',
            ]
        )

        result = classify_ndjson(stream, "agent-process-lifecycle")

        self.assertTrue(result.candidate_selected)
        self.assertEqual(result.tool_uses, ("bash", "skill", "skill"))
        self.assertEqual(result.non_skill_tool_uses, ("bash",))

    def test_invalid_attempts_when_stream_or_process_is_incomplete_are_not_non_triggers(self) -> None:
        candidate_selection = '{"type":"tool_use","part":{"type":"tool","tool":"skill","state":{"status":"completed","input":{"name":"playwright-server-lifecycle"}}}}\n'
        cases = [
            (candidate_selection + '{"type":"step_finish"\n', 0, AttemptStatus.INVALID_MALFORMED_STREAM),
            (candidate_selection, 0, AttemptStatus.INVALID_MISSING_COMPLETION),
            (candidate_selection + '{"type":"step_finish","part":{"type":"step-finish","reason":"stop"}}\n', 9, AttemptStatus.INVALID_PROCESS_FAILURE),
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
                self.assertTrue(result.candidate_selected)

    def test_aggregation_when_trials_include_invalid_attempts_separates_rates(self) -> None:
        records = [
            TrialRecord.valid("current", "listener-local-server", "positive", 1, 1, True),
            TrialRecord.valid("current", "listener-local-server", "positive", 2, 1, False),
            TrialRecord.valid("current", "sync-long-command", "negative", 1, 1, True),
            TrialRecord.valid("current", "sync-long-command", "negative", 2, 1, False),
            TrialRecord.invalid("current", "sync-long-command", "negative", 3, 1, AttemptStatus.INVALID_TIMEOUT, candidate_selected=False),
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
        variants = (Variant("one", "one-skill", "one", "one/SKILL.md"), Variant("two", "two-skill", "two", "two/SKILL.md"))
        prompts = tuple(Prompt(f"prompt-{index}", "positive", f"body-{index}") for index in range(16))
        records = [TrialRecord.valid(variant.id, prompt.id, prompt.label, logical_run, 1, True) for variant in variants for prompt in prompts for logical_run in range(1, 4)]
        result = check_matrix_completeness(records, variants, prompts, 3)
        self.assertTrue(result.is_complete)
        self.assertEqual(result.expected_cells, 96)

    def test_matrix_completeness_when_cell_has_no_valid_trial_blocks_finalization(self) -> None:
        variants = (Variant("one", "one-skill", "one", "one/SKILL.md"),)
        prompts = (Prompt("prompt", "positive", "body"),)
        records = [TrialRecord.invalid("one", "prompt", "positive", 1, 1, AttemptStatus.INVALID_TIMEOUT, candidate_selected=False)]
        result = check_matrix_completeness(records, variants, prompts, 1)
        self.assertFalse(result.is_complete)
        self.assertEqual(result.missing_cells, ("one::prompt::run-1",))

    def test_phase_shape_when_calibration_has_the_two_controls_and_two_probe_prompts_is_valid(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        prompts = tuple(prompt for prompt in specification.prompts if prompt.id in {"listener-local-server", "sync-long-command"})

        validate_phase_shape(RunShape(RunPhase.CALIBRATION, specification.variants, prompts, 1, 4))

    def test_phase_shape_when_fixed_base_or_targeted_selection_drifts_is_rejected_before_dispatch(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        candidate = tuple(variant for variant in specification.variants if variant.id == "candidate")
        one_prompt = (specification.prompts[0],)

        with self.assertRaises(PhaseShapeError):
            validate_phase_shape(RunShape(RunPhase.CALIBRATION, specification.variants, one_prompt, 1, 3))
        with self.assertRaises(PhaseShapeError):
            validate_phase_shape(RunShape(RunPhase.FIXED_BASE, candidate, specification.prompts, 3, 1))
        with self.assertRaises(PhaseShapeError):
            validate_phase_shape(RunShape(RunPhase.TARGETED, candidate, one_prompt, 3, 1))
