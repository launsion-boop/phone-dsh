#!/usr/bin/env python3
"""Validate the not-yet-dual-implemented memory evidence-length overlay."""
from __future__ import annotations
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import validate_vectors as vv

ROOT = Path(__file__).resolve().parents[4]
GOLDEN = ROOT / "spec" / "bot" / "v2" / "golden" / "memory-write.next.json"


def main() -> int:
    fixture = json.loads(GOLDEN.read_text())
    if fixture.get("status") != "next-unenabled":
        raise AssertionError("overlay must stay next-unenabled")
    cases = fixture["cases"]
    for index, case in enumerate(cases):
        vv.check(case["request"], "memory-write-request.schema.json",
                 f"next.cases[{index}].request")
        actual = vv.result_for_case(case)
        vv.check(actual, "memory-write-result.schema.json",
                 f"next.cases[{index}].result")
        for key, value in case["expect"].items():
            if actual.get(key) != value:
                raise AssertionError(
                    f"next.cases[{index}] {case['name']}.{key} "
                    f"{actual.get(key)!r} != {value!r}")
    # mutation: removing the evidence scalars must stop the guard firing
    import copy
    mutated = copy.deepcopy(cases[0])
    mutated.pop("evidenceScalars", None)
    if vv.result_for_case(mutated).get("code") == "memory-document-longer-than-evidence":
        raise AssertionError("mutation did not remove guard")
    print(f"memory evidence-length overlay: PASS (cases {len(cases)}, mutation 1)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, Exception) as error:
        print(f"memory evidence-length overlay: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
