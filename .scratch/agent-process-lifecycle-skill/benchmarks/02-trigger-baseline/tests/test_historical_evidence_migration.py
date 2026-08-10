from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))

from trigger_benchmark.historical_evidence_migration import MigrationError, apply_migration, plan_migration


class HistoricalEvidenceMigrationTests(unittest.TestCase):
    def test_migration_when_legacy_evidence_is_valid_relocates_raw_bytes_and_rewrites_paths_and_hash_cascade(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            reference = benchmark_root / "results/reference"
            dependent = benchmark_root / "results/dependent"
            raw_before = _write_legacy_evidence(reference)
            dependent_before = _write_legacy_evidence(dependent, reference=reference)

            receipt = apply_migration(plan_migration(benchmark_root))

            self.assertEqual(receipt.raw_files, 12)
            self.assertEqual(receipt.raw_sha256_before, receipt.raw_sha256_after)
            self.assertEqual(sorted(raw_before.values()), sorted(_raw_hashes(reference).values()))
            self.assertEqual(sorted(dependent_before.values()), sorted(_raw_hashes(dependent).values()))
            self.assertTrue((reference / "logs/v.out").is_file())
            self.assertTrue((reference / "logs/p-current-1.out").is_file())
            self.assertTrue((reference / "logs/t-fixture-1.out").is_file())
            self.assertFalse((reference / "logs/environment-opencode-version.stdout.txt").exists())

            manifest = _document(dependent / "manifest.json")
            self.assertEqual(manifest["observed_environment"]["opencode"]["stdout_path"], "logs/v.out")
            self.assertEqual(manifest["preflight"][0]["stdout_path"], "logs/p-current-1.out")
            self.assertEqual(manifest["preflight"][0]["attempts"][0]["stdout_path"], "logs/p-current-1.out")
            self.assertEqual(manifest["reference_manifest"]["sha256"], _hash(reference / "manifest.json"))
            record = _records(dependent)[0]
            self.assertEqual(record["stdout_path"], "logs/t-fixture-1.out")
            self.assertIn("logs/t-fixture-1.out", manifest["artifact_hashes"])
            self.assertNotIn("logs/current__prompt__run-1__attempt-1.stdout.ndjson", manifest["artifact_hashes"])

    def test_migration_when_compact_evidence_is_replanned_is_a_noop(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            _write_legacy_evidence(benchmark_root / "results/evidence")

            apply_migration(plan_migration(benchmark_root))
            receipt = apply_migration(plan_migration(benchmark_root))

            self.assertEqual(receipt.raw_files, 0)
            self.assertEqual(receipt.documents, 0)

    def test_migration_when_structured_evidence_uses_crlf_preserves_it_and_uses_relative_receipt_keys(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            evidence = benchmark_root / "results/evidence"
            _write_legacy_evidence(evidence)
            for path in (evidence / "manifest.json", evidence / "trials.ndjson"):
                path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
            manifest = _document(evidence / "manifest.json")
            manifest["artifact_hashes"]["trials.ndjson"] = _hash(evidence / "trials.ndjson")
            (evidence / "manifest.json").write_bytes((json.dumps(manifest, indent=2) + "\n").replace("\n", "\r\n").encode("utf-8"))

            receipt = apply_migration(plan_migration(benchmark_root))

            _assert_crlf(self, (evidence / "manifest.json").read_bytes())
            _assert_crlf(self, (evidence / "trials.ndjson").read_bytes())
            self.assertEqual(receipt.raw_sha256_before, receipt.raw_sha256_after)
            self.assertTrue(all(not Path(path).is_absolute() for path in receipt.raw_sha256_after))

    def test_migration_when_trial_destinations_collide_rejects_before_mutating(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            evidence = benchmark_root / "results/evidence"
            raw_before = _write_legacy_evidence(evidence, duplicate_trial=True)

            with self.assertRaises(MigrationError):
                plan_migration(benchmark_root)

            self.assertEqual(raw_before, _raw_hashes(evidence))
            self.assertTrue((evidence / "logs/current__prompt__run-1__attempt-1.stdout.ndjson").is_file())


def _write_legacy_evidence(root: Path, *, reference: Path | None = None, duplicate_trial: bool = False) -> dict[str, str]:
    logs = root / "logs"
    logs.mkdir(parents=True)
    streams = {
        "logs/environment-opencode-version.stdout.txt": b"OpenCode 1.18.5\n",
        "logs/environment-opencode-version.stderr.txt": b"",
        "logs/preflight-current-fixture-preflight-attempt-1.stdout.txt": b"[]",
        "logs/preflight-current-fixture-preflight-attempt-1.stderr.txt": b"",
        "logs/current__prompt__run-1__attempt-1.stdout.ndjson": b'{"type":"step_finish","part":{"type":"step-finish"}}\n',
        "logs/current__prompt__run-1__attempt-1.stderr.txt": b"",
    }
    for relative, content in streams.items():
        (root / relative).write_bytes(content)
    records = [_record("fixture-1", streams)]
    if duplicate_trial:
        duplicate = _record("fixture-1", streams)
        duplicate["logical_run"] = 2
        duplicate["stdout_path"] = "logs/current__prompt__run-2__attempt-1.stdout.ndjson"
        duplicate["stderr_path"] = "logs/current__prompt__run-2__attempt-1.stderr.txt"
        (root / duplicate["stdout_path"]).write_bytes(streams["logs/current__prompt__run-1__attempt-1.stdout.ndjson"])
        (root / duplicate["stderr_path"]).write_bytes(b"")
        records.append(duplicate)
    trials = root / "trials.ndjson"
    trials.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8", newline="\n")
    manifest = {
        "observed_environment": {"opencode": {"stdout_path": "logs/environment-opencode-version.stdout.txt", "stderr_path": "logs/environment-opencode-version.stderr.txt", "stdout_sha256": _hash(root / "logs/environment-opencode-version.stdout.txt"), "stderr_sha256": _hash(root / "logs/environment-opencode-version.stderr.txt")}},
        "preflight": [{"variant_id": "current", "successful_attempt": 1, "stdout_path": "logs/preflight-current-fixture-preflight-attempt-1.stdout.txt", "stderr_path": "logs/preflight-current-fixture-preflight-attempt-1.stderr.txt", "stdout_sha256": _hash(root / "logs/preflight-current-fixture-preflight-attempt-1.stdout.txt"), "stderr_sha256": _hash(root / "logs/preflight-current-fixture-preflight-attempt-1.stderr.txt"), "attempts": [{"attempt": 1, "fixture_id": "fixture-preflight", "stdout_path": "logs/preflight-current-fixture-preflight-attempt-1.stdout.txt", "stderr_path": "logs/preflight-current-fixture-preflight-attempt-1.stderr.txt", "stdout_sha256": _hash(root / "logs/preflight-current-fixture-preflight-attempt-1.stdout.txt"), "stderr_sha256": _hash(root / "logs/preflight-current-fixture-preflight-attempt-1.stderr.txt")}]}],
        "reference_manifest": None if reference is None else {"path": (reference / "manifest.json").relative_to(root.parents[1]).as_posix(), "sha256": _hash(reference / "manifest.json"), "expected_phase": "calibration"},
        "source_hashes": {},
        "artifact_hashes": {},
    }
    manifest["artifact_hashes"] = {path.relative_to(root).as_posix(): _hash(path) for path in sorted(root.rglob("*")) if path.is_file()}
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    return _raw_hashes(root)


def _record(fixture_id: str, streams: dict[str, bytes]) -> dict[str, object]:
    stdout = "logs/current__prompt__run-1__attempt-1.stdout.ndjson"
    stderr = "logs/current__prompt__run-1__attempt-1.stderr.txt"
    return {"variant_id": "current", "prompt_id": "prompt", "label": "positive", "logical_run": 1, "attempt": 1, "fixture_id": fixture_id, "stdout_path": stdout, "stderr_path": stderr, "stdout_sha256": _sha256(streams[stdout]), "stderr_sha256": _sha256(streams[stderr])}


def _raw_hashes(root: Path) -> dict[str, str]:
    return {path.relative_to(root).as_posix(): _hash(path) for path in sorted((root / "logs").iterdir())}


def _records(root: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in (root / "trials.ndjson").read_text(encoding="utf-8").splitlines()]


def _document(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def _hash(path: Path) -> str:
    return _sha256(path.read_bytes())


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _assert_crlf(test_case: unittest.TestCase, content: bytes) -> None:
    test_case.assertEqual(content.count(b"\n"), content.count(b"\r\n"))
    test_case.assertNotIn(b"\r\r\n", content)
