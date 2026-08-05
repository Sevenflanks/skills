#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.0"
# dependencies = []
# ///

from __future__ import annotations

from trigger_benchmark.runner import main


if __name__ == "__main__":
    raise SystemExit(main())
