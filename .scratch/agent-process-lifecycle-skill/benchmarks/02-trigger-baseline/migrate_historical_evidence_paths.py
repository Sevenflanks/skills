#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.0"
# dependencies = []
# ///

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from trigger_benchmark.historical_evidence_migration import MigrationReceipt, apply_migration, plan_migration


def main(arguments: tuple[str, ...] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Migrate legacy trigger benchmark raw evidence paths.")
    parser.add_argument("action", choices=("check", "apply"))
    parser.add_argument("--benchmark-root", type=Path, default=Path(__file__).resolve().parent)
    parsed = parser.parse_args(arguments)
    plan = plan_migration(parsed.benchmark_root)
    receipt = apply_migration(plan) if parsed.action == "apply" else plan.receipt
    print(json.dumps(_receipt_document(receipt), indent=2) + "\n", end="")
    return 0


def _receipt_document(receipt: MigrationReceipt) -> dict[str, int | str]:
    return {
        "raw_files": receipt.raw_files,
        "documents": receipt.documents,
        "evidence_roots": receipt.evidence_roots,
        "raw_sha256_before": _integrity_digest(receipt.raw_sha256_before),
        "raw_sha256_after": _integrity_digest(receipt.raw_sha256_after),
    }


def _integrity_digest(hashes: dict[str, str]) -> str:
    return hashlib.sha256(json.dumps(hashes, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


if __name__ == "__main__":
    raise SystemExit(main())
