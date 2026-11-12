#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read the per-turn persistence counters of PhoneDSHLog (budgets.md §7).

``Sources/PhoneDSHLog`` counts every ``write()`` byte and every
``fsync``/``F_FULLFSYNC`` call of the stores it owns (WAL segments, journal,
materialized copy, blob store, overlay, manifest). A test drives one synthetic
turn over the real facade and prints the settled window as:

    PDSH_IO_FSYNC_CALLS=<count>
    PDSH_IO_BYTES_WRITTEN=<bytes>

This script runs that probe on the host and emits one JSON object with the two
budget rows, or parses an already captured log (``--log``) containing the same
lines. Host-build numbers are not a device baseline: the report must still name
the device, the commit and the fixture profile.

Usage:
    python3 scripts/perf/read_io_counters.py
    python3 scripts/perf/read_io_counters.py --pretty
    python3 scripts/perf/read_io_counters.py --output /tmp/io.json
    python3 scripts/perf/read_io_counters.py --log /tmp/swift-test.log --pretty
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Sequence

SCHEMA_VERSION = "pdsh-perf-io-counters/v1"
DEFAULT_FILTER = ("LogIOCountersTests/"
                  "testRealTurnSettlementCountsFsyncAndBytesAndResets")
FSYNC_RE = re.compile(r"^PDSH_IO_FSYNC_CALLS=(\d+)\s*$", re.MULTILINE)
BYTES_RE = re.compile(r"^PDSH_IO_BYTES_WRITTEN=(\d+)\s*$", re.MULTILINE)

# The metric names are exactly the budgets.md §7 rows; do not rename them in
# reports, or two measurements can silently use different definitions.
SCOPE = ("PhoneDSHLog host build, one synthetic turn through WorkspaceLog "
         "(WAL + materialized + journal + manifest). steps, the exec ledger "
         "and the response log live in other modules and are NOT counted.")


class ProbeError(RuntimeError):
    """The probe did not emit a usable pair of counter lines."""


def parse_counters(text: str) -> Dict[str, int]:
    """Return the last settled window printed in ``text``.

    A filtered run prints one pair. If a log contains several pairs (for
    example a full test-suite log), the last pair is the latest settlement.
    """
    fsync = FSYNC_RE.findall(text)
    written = BYTES_RE.findall(text)
    if not fsync or not written:
        raise ProbeError("no PDSH_IO_* counter lines found in the input")
    if len(fsync) != len(written):
        raise ProbeError("PDSH_IO_* counter lines are not paired")
    return {
        "fsync_calls_per_turn": int(fsync[-1]),
        "bytes_written_per_turn": int(written[-1]),
    }


def run_probe(swift: str, repo_root: Path, test_filter: str,
              timeout: Optional[float]) -> tuple[str, List[str]]:
    """Run the real-write-path probe test and return its captured output."""
    command = [swift, "test", "--disable-sandbox", "--filter", test_filter]
    try:
        completed = subprocess.run(
            command,
            cwd=str(repo_root),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
            text=True,
        )
    except FileNotFoundError as exc:
        raise ProbeError(f"swift executable not found: {swift}") from exc
    except subprocess.TimeoutExpired as exc:
        raise ProbeError(f"probe timed out after {timeout} s") from exc
    output = completed.stdout or ""
    if completed.returncode != 0:
        tail = "\n".join(output.splitlines()[-15:])
        raise ProbeError(f"swift test failed ({completed.returncode}):\n{tail}")
    return output, command


def report(counters: Dict[str, int], source: str,
           command: Optional[Sequence[str]] = None,
           log: Optional[Path] = None) -> dict:
    """Build the stable JSON report the W0/W4 report template can quote."""
    payload = {
        "schema": SCHEMA_VERSION,
        "fsync_calls_per_turn": counters["fsync_calls_per_turn"],
        "bytes_written_per_turn": counters["bytes_written_per_turn"],
        "scope": SCOPE,
        "source": source,
    }
    if command is not None:
        payload["command"] = list(command)
    if log is not None:
        payload["log"] = str(log)
    return payload


def _write(payload: dict, output: Optional[Path], pretty: bool) -> None:
    text = json.dumps(payload, indent=2 if pretty else None,
                      sort_keys=True) + "\n"
    if output is None:
        sys.stdout.write(text)
        return
    output.write_text(text, encoding="utf-8")
    print(f"wrote {output}", file=sys.stderr)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Read PhoneDSHLog's per-turn fsync/bytes counters.")
    parser.add_argument("--log", type=Path,
                        help="parse an existing swift-test/console log instead "
                             "of running the probe")
    parser.add_argument("--output", type=Path,
                        help="write the JSON report to this path")
    parser.add_argument("--pretty", action="store_true",
                        help="indent the JSON output")
    parser.add_argument("--swift", default="swift",
                        help="swift executable (default: swift)")
    parser.add_argument("--filter", default=DEFAULT_FILTER,
                        help="swift test filter of the probe test")
    parser.add_argument("--timeout", type=float, default=1800.0,
                        help="probe timeout in seconds (default: 1800)")
    args = parser.parse_args(argv)

    try:
        if args.log is not None:
            counters = parse_counters(
                Path(args.log).read_text(encoding="utf-8", errors="replace"))
            payload = report(counters, "captured log", log=args.log)
        else:
            swift = shutil.which(args.swift)
            if swift is None:
                raise ProbeError(f"swift executable not found: {args.swift}")
            repo_root = Path(__file__).resolve().parents[2]
            output, command = run_probe(swift, repo_root, args.filter,
                                        args.timeout)
            counters = parse_counters(output)
            payload = report(counters, "swift test probe",
                             command=command)
    except (OSError, ProbeError) as exc:
        print(f"read_io_counters: {exc}", file=sys.stderr)
        return 2

    _write(payload, args.output, args.pretty)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
