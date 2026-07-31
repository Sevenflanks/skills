from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))

from trigger_benchmark.models import AttemptStatus, RunOptions, RunPhase
from trigger_benchmark.spec import load_specification
from trigger_benchmark.trials import TrialPlan, run_trials


class TrialObservationTests(unittest.TestCase):
    def test_run_trials_when_streams_contain_lf_persists_exact_utf8_bytes(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        candidate = specification.variants[1]
        prompt = next(item for item in specification.prompts if item.id == "ide-owned-service")
        stdout = '{"type":"step_finish","part":{"type":"step-finish"}}\n'
        stderr = "trial stderr\n"

        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "evidence"
            (output / "logs").mkdir(parents=True)
            (output / "fixtures").mkdir()
            options = RunOptions(RunPhase.EXPLORATORY, 1, 1, 1.0, 0, 1, output, "test-model", (), (), None)
            plan = TrialPlan(options, (candidate,), (prompt,), "opencode")
            with patch("trigger_benchmark.trials.subprocess.run", return_value=subprocess.CompletedProcess(("opencode", "run"), 0, stdout, stderr)):
                record, = run_trials(plan)

            with self.subTest("stdout bytes"):
                self.assertEqual((output / record.stdout_path).read_bytes(), stdout.encode("utf-8"))
            with self.subTest("stderr bytes"):
                self.assertEqual((output / record.stderr_path).read_bytes(), stderr.encode("utf-8"))

    def test_timeout_when_candidate_and_non_skill_tool_appear_in_raw_stdout_preserves_observation(self) -> None:
        specification = load_specification(BENCHMARK_ROOT)
        candidate = specification.variants[1]
        prompt = next(item for item in specification.prompts if item.id == "ide-owned-service")
        stdout = "\n".join((
            json.dumps({"type": "tool_use", "part": {"type": "tool", "tool": "skill", "state": {"status": "completed", "input": {"name": candidate.skill_name}}}}),
            json.dumps({"type": "tool_use", "part": {"type": "tool", "tool": "bash"}}),
        ))
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "evidence"
            (output / "logs").mkdir(parents=True)
            (output / "fixtures").mkdir()
            options = RunOptions(RunPhase.EXPLORATORY, 1, 1, 1.0, 0, 1, output, "test-model", (), (), None)
            plan = TrialPlan(options, (candidate,), (prompt,), "opencode")
            error = subprocess.TimeoutExpired(("opencode", "run"), 1.0, output=stdout, stderr="")
            with patch("trigger_benchmark.trials.subprocess.run", side_effect=error):
                record, = run_trials(plan)

        self.assertEqual(record.status, AttemptStatus.INVALID_TIMEOUT)
        self.assertIsNone(record.triggered)
        self.assertTrue(record.candidate_selected)
        self.assertEqual(record.non_skill_tool_uses, ("bash",))
