from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))

from trigger_benchmark.artifact_paths import preflight_paths, trial_paths, version_paths
from trigger_benchmark.historical_evidence_migration import MigrationError, MigrationPlan, MigrationReceipt, _Write, apply_migration, plan_migration


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

    def test_migration_when_gate_documents_reference_legacy_manifests_rehashes_every_cascade_and_preserves_contracts(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            results = benchmark_root / "results"
            calibration = results / "calibration"
            base = results / "base"
            _write_legacy_evidence(calibration)
            _write_legacy_evidence(base, reference=calibration)
            calibration_raw = _raw_bytes(calibration)
            base_raw = _raw_bytes(base)
            base_trials = base / "trials.ndjson"
            base_trials.write_bytes(base_trials.read_bytes().replace(b"\n", b"\r\n"))
            base_manifest = _document(base / "manifest.json")
            base_manifest["artifact_hashes"]["trials.ndjson"] = _hash(base_trials)
            _write_document(base / "manifest.json", base_manifest, b"\r\n")
            original_calibration_hash = _hash(calibration / "manifest.json")
            original_base_hash = _hash(base / "manifest.json")
            worker_calibration = results / "worker-calibration.json"
            calibration_entry = {"workers": 1, "complete": True, "parity": "match", "run_path": "calibration", "manifest_sha256": original_calibration_hash, "reason_codes": []}
            _write_document(worker_calibration, {"schema_version": 1, "stage": "calibration", "status": "passed", "outcome": "pass", "exit_code": 0, "selection_rule": "highest_complete_parity_workers", "entries": [calibration_entry], "selected": calibration_entry, "reason_codes": []}, b"\r\n")
            decision_path = results / "base-decision" / "decision.json"
            decision_path.parent.mkdir()
            _write_document(decision_path, {"schema_version": 1, "stage": "base", "status": "passed", "outcome": "pass", "exit_code": 0, "artifact_hashes": {"base/manifest.json": original_base_hash}}, b"\r\n")
            report_path = decision_path.with_name("report.md")
            report_path.write_bytes(b"# stale report\r\n")

            receipt = apply_migration(plan_migration(benchmark_root))

            expected_calibration_hash = _hash(calibration / "manifest.json")
            expected_base_hash = _hash(base / "manifest.json")
            self.assertNotEqual(original_calibration_hash, expected_calibration_hash)
            self.assertNotEqual(original_base_hash, expected_base_hash)
            self.assertEqual(_raw_bytes(calibration), _compact_raw_bytes(calibration_raw))
            self.assertEqual(_raw_bytes(base), _compact_raw_bytes(base_raw))
            expected_raw_hashes = {
                f"{root.relative_to(benchmark_root).as_posix()}/{relative}": _sha256(content)
                for root, raw in ((calibration, calibration_raw), (base, base_raw))
                for relative, content in _compact_raw_bytes(raw).items()
            }
            self.assertEqual(receipt.raw_sha256_before, expected_raw_hashes)
            self.assertEqual(receipt.raw_sha256_after, expected_raw_hashes)
            self.assertEqual(_document(base / "manifest.json")["reference_manifest"]["sha256"], expected_calibration_hash)
            migrated_calibration = _document(worker_calibration)
            self.assertEqual(migrated_calibration["entries"][0]["manifest_sha256"], expected_calibration_hash)
            self.assertEqual(migrated_calibration["selected"]["manifest_sha256"], expected_calibration_hash)
            decision = _document(decision_path)
            self.assertEqual(decision["artifact_hashes"]["base/manifest.json"], expected_base_hash)
            expected_report = "\r\n".join(["# Routing Release Gate", "", *[f"- {key}: `{json.dumps(value, sort_keys=True)}`" for key, value in decision.items()]]) + "\r\n"
            self.assertEqual(report_path.read_bytes(), expected_report.encode("utf-8"))
            self.assertNotIn(b"\r\n", (calibration / "manifest.json").read_bytes())
            _assert_crlf(self, (base / "manifest.json").read_bytes())
            _assert_crlf(self, base_trials.read_bytes())
            _assert_crlf(self, worker_calibration.read_bytes())
            _assert_crlf(self, decision_path.read_bytes())
            _assert_crlf(self, report_path.read_bytes())

            replanned = plan_migration(benchmark_root)

            self.assertEqual(replanned.moves, ())
            self.assertEqual(replanned.writes, ())
            self.assertEqual(apply_migration(replanned).documents, 0)

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

    def test_migration_when_planned_move_source_is_stale_rejects_without_mutating(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            evidence = benchmark_root / "results/evidence"
            _write_legacy_evidence(evidence)
            plan = plan_migration(benchmark_root)
            (evidence / "logs/environment-opencode-version.stdout.txt").write_bytes(b"stale raw stream\n")
            evidence_before = _evidence_bytes(evidence)

            with self.assertRaises(MigrationError):
                apply_migration(plan)

            self.assertEqual(evidence_before, _evidence_bytes(evidence))

    def test_migration_when_planned_move_destination_collides_rejects_without_mutating(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            evidence = benchmark_root / "results/evidence"
            _write_legacy_evidence(evidence)
            plan = plan_migration(benchmark_root)
            (evidence / version_paths().stdout).write_bytes(b"unplanned destination\n")
            evidence_before = _evidence_bytes(evidence)

            with self.assertRaises(MigrationError):
                apply_migration(plan)

            self.assertEqual(evidence_before, _evidence_bytes(evidence))

    def test_migration_when_planned_write_target_is_stale_rejects_without_mutating(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            evidence = benchmark_root / "results/evidence"
            _write_legacy_evidence(evidence)
            plan = plan_migration(benchmark_root)
            (evidence / "manifest.json").write_bytes(b'{"stale": "write"}\n')
            evidence_before = _evidence_bytes(evidence)

            with self.assertRaises(MigrationError):
                apply_migration(plan)

            self.assertEqual(evidence_before, _evidence_bytes(evidence))

    def test_migration_when_declared_stream_traverses_outside_logs_rejects_before_mutating(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            evidence = benchmark_root / "results/evidence"
            _write_legacy_evidence(evidence)
            outside_file = evidence.parent / "outside-file"
            outside_file.write_bytes(b"outside evidence")
            manifest = _document(evidence / "manifest.json")
            environment = manifest["observed_environment"]["opencode"]
            environment["stdout_path"] = "logs/../../outside-file"
            environment["stdout_sha256"] = _hash(outside_file)
            _write_document(evidence / "manifest.json", manifest, b"\n")
            evidence_before = _evidence_bytes(evidence)
            outside_before = outside_file.read_bytes()

            with self.assertRaises(MigrationError):
                plan_migration(benchmark_root)

            self.assertEqual(evidence_before, _evidence_bytes(evidence))
            self.assertEqual(outside_before, outside_file.read_bytes())

    def test_migration_when_declared_stream_path_is_not_canonical_posix_rejects_before_mutating(self) -> None:
        canonical_stream = "logs/environment-opencode-version.stdout.txt"
        aliases = (
            "logs/./environment-opencode-version.stdout.txt",
            "logs//environment-opencode-version.stdout.txt",
            "logs/../logs/environment-opencode-version.stdout.txt",
            "/logs/environment-opencode-version.stdout.txt",
            r"logs\environment-opencode-version.stdout.txt",
        )
        for source in aliases:
            with self.subTest(source=source):
                with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
                    benchmark_root = Path(temporary_directory)
                    evidence = benchmark_root / "results/evidence"
                    _write_legacy_evidence(evidence)
                    manifest = _document(evidence / "manifest.json")
                    environment = manifest["observed_environment"]["opencode"]
                    environment["stdout_path"] = source
                    environment["stdout_sha256"] = _hash(evidence / canonical_stream)
                    _write_document(evidence / "manifest.json", manifest, b"\n")
                    evidence_before = _evidence_bytes(evidence)

                    with self.assertRaises(MigrationError):
                        plan_migration(benchmark_root)

                    self.assertEqual(evidence_before, _evidence_bytes(evidence))

    def test_migration_when_declared_stream_is_symlink_rejects_before_mutating(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            evidence = benchmark_root / "results/evidence"
            _write_legacy_evidence(evidence)
            declared_stdout = evidence / "logs/environment-opencode-version.stdout.txt"
            evidence_before = _evidence_bytes(evidence)
            original_is_symlink = Path.is_symlink

            with patch.object(Path, "is_symlink", autospec=True, side_effect=lambda path: path == declared_stdout or original_is_symlink(path)):
                with self.assertRaises(MigrationError):
                    plan_migration(benchmark_root)

            self.assertEqual(evidence_before, _evidence_bytes(evidence))

    def test_migration_when_declared_stream_ancestor_is_symlink_rejects_before_mutating(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            evidence = benchmark_root / "results/evidence"
            _write_legacy_evidence(evidence)
            declared_ancestor = evidence / "logs"
            evidence_before = _evidence_bytes(evidence)
            original_is_symlink = Path.is_symlink

            with patch.object(Path, "is_symlink", autospec=True, side_effect=lambda path: path == declared_ancestor or original_is_symlink(path)):
                with self.assertRaises(MigrationError):
                    plan_migration(benchmark_root)

            self.assertEqual(evidence_before, _evidence_bytes(evidence))

    def test_migration_when_planned_move_destination_is_dangling_symlink_rejects_without_mutating(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            evidence = benchmark_root / "results/evidence"
            _write_legacy_evidence(evidence)
            plan = plan_migration(benchmark_root)
            dangling_destination = evidence / version_paths().stdout
            evidence_before = _evidence_bytes(evidence)
            original_is_symlink = Path.is_symlink

            with patch.object(Path, "is_symlink", autospec=True, side_effect=lambda path: path == dangling_destination or original_is_symlink(path)):
                with self.assertRaises(MigrationError):
                    apply_migration(plan)

            self.assertEqual(evidence_before, _evidence_bytes(evidence))

    def test_migration_when_expected_absent_write_target_is_dangling_symlink_rejects_without_mutating(self) -> None:
        with tempfile.TemporaryDirectory(dir=BENCHMARK_ROOT) as temporary_directory:
            benchmark_root = Path(temporary_directory)
            evidence = benchmark_root / "results/evidence"
            evidence.mkdir(parents=True)
            (evidence / "sentinel").write_bytes(b"unchanged")
            dangling_target = evidence / "planned-write"
            plan = MigrationPlan(
                benchmark_root,
                (),
                (_Write(dangling_target, b"planned write", None),),
                MigrationReceipt(0, 1, 0, {}, {}),
            )
            evidence_before = _evidence_bytes(evidence)
            original_is_symlink = Path.is_symlink

            with patch.object(Path, "is_symlink", autospec=True, side_effect=lambda path: path == dangling_target or original_is_symlink(path)):
                with self.assertRaises(MigrationError):
                    apply_migration(plan)

            self.assertEqual(evidence_before, _evidence_bytes(evidence))


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
    return {relative: _sha256(content) for relative, content in _raw_bytes(root).items()}


def _raw_bytes(root: Path) -> dict[str, bytes]:
    return {path.relative_to(root).as_posix(): path.read_bytes() for path in sorted((root / "logs").iterdir())}


def _evidence_bytes(root: Path) -> dict[str, bytes]:
    return {path.relative_to(root).as_posix(): path.read_bytes() for path in sorted(root.rglob("*")) if path.is_file()}


def _compact_raw_bytes(legacy: dict[str, bytes]) -> dict[str, bytes]:
    version = version_paths()
    preflight = preflight_paths("current", 1)
    trial = trial_paths("fixture-1")
    return {
        version.stdout: legacy["logs/environment-opencode-version.stdout.txt"],
        version.stderr: legacy["logs/environment-opencode-version.stderr.txt"],
        preflight.stdout: legacy["logs/preflight-current-fixture-preflight-attempt-1.stdout.txt"],
        preflight.stderr: legacy["logs/preflight-current-fixture-preflight-attempt-1.stderr.txt"],
        trial.stdout: legacy["logs/current__prompt__run-1__attempt-1.stdout.ndjson"],
        trial.stderr: legacy["logs/current__prompt__run-1__attempt-1.stderr.txt"],
    }


def _write_document(path: Path, document: dict[str, object], newline: bytes) -> None:
    path.write_bytes((json.dumps(document, indent=2) + "\n").replace("\n", newline.decode("utf-8")).encode("utf-8"))


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
