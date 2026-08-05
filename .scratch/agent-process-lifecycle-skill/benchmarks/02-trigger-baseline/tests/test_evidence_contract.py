from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_evidence import update_artifact_hash, write_exploratory_evidence
from trigger_benchmark.evidence import EvidenceValidationError, validate_evidence
from trigger_benchmark.spec import load_specification


class EvidenceContractTests(unittest.TestCase):
    def test_evidence_when_candidate_observation_or_fixture_location_disagrees_with_raw_contract_rejects(self) -> None:
        cases = ("candidate-selected", "missing-candidate-selected", "external-fixture")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                write_exploratory_evidence(root)
                trials = root / "trials.ndjson"
                record = json.loads(trials.read_text(encoding="utf-8"))
                if case == "candidate-selected":
                    record["candidate_selected"] = False
                elif case == "missing-candidate-selected":
                    record.pop("candidate_selected")
                else:
                    record["command"][10] = str(Path("C:/unrelated/fixtures") / record["fixture_id"])
                trials.write_text(json.dumps(record) + "\n", encoding="utf-8")
                update_artifact_hash(root, "trials.ndjson")

                with self.assertRaises(EvidenceValidationError):
                    validate_evidence(root, BENCHMARK_ROOT, load_specification(BENCHMARK_ROOT))

    def test_evidence_when_trial_fixture_id_and_directory_are_paired_to_escape_the_evidence_root_rejects(self) -> None:
        cases = ("..", "nested/name", "nested\\name", "C:relative", "{absolute}")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                write_exploratory_evidence(root)
                trials = root / "trials.ndjson"
                record = json.loads(trials.read_text(encoding="utf-8"))
                fixture_id = str(root / "outside") if case == "{absolute}" else case
                record["fixture_id"] = fixture_id
                record["command"][10] = str(root / "fixtures" / Path(fixture_id))
                trials.write_text(json.dumps(record) + "\n", encoding="utf-8")
                update_artifact_hash(root, "trials.ndjson")

                with self.assertRaises(EvidenceValidationError):
                    validate_evidence(root, BENCHMARK_ROOT, load_specification(BENCHMARK_ROOT))

    def test_evidence_when_preflight_fixture_id_and_candidate_location_are_paired_to_escape_the_evidence_root_rejects(self) -> None:
        cases = ("..", "nested/name", "nested\\name", "C:relative", "{absolute}")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                write_exploratory_evidence(root)
                manifest_path = root / "manifest.json"
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                entry = manifest["preflight"][0]
                fixture_id = str(root / "outside") if case == "{absolute}" else case
                candidate_location = (root / "fixtures" / Path(fixture_id) / ".opencode" / "skills" / entry["candidate_name"] / "SKILL.md").resolve()
                entry["fixture_id"] = fixture_id
                entry["candidate_location"] = str(candidate_location)
                stdout = root / entry["stdout_path"]
                stdout.write_text(json.dumps([{"name": entry["candidate_name"], "description": load_specification(BENCHMARK_ROOT).variants[1].description, "location": str(candidate_location)}]), encoding="utf-8")
                entry["stdout_sha256"] = hashlib.sha256(stdout.read_bytes()).hexdigest()
                manifest["artifact_hashes"][entry["stdout_path"]] = entry["stdout_sha256"]
                manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

                with self.assertRaises(EvidenceValidationError):
                    validate_evidence(root, BENCHMARK_ROOT, load_specification(BENCHMARK_ROOT))
