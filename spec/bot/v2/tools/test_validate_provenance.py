#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation and determinism checks for the G-1 provenance reference resolver.

`validate_provenance.py` already runs per-case mutations. This test makes the
checker itself accountable: a wrong expectation must fail, the inline schema
copies must stay equal, the resolver must be deterministic and the semantic
rules must reject the cases that no JSON Schema keyword can express.
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
PATH = ROOT / "spec" / "bot" / "v2" / "tools" / "validate_provenance.py"
spec = importlib.util.spec_from_file_location("validate_provenance", PATH)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def main() -> int:
    golden = json.loads(module.GOLDEN.read_text())
    module.check_inline_copies()
    module.check_gate()
    cases = golden.get("cases", [])
    assert len(cases) >= 17, "expected at least 17 frozen cases"
    first = module.resolve_case(cases[0])
    second = module.resolve_case(cases[0])
    assert first == second, "resolver is not deterministic"
    mutations = module.mutation_count(golden)
    assert mutations >= len(cases), f"expected >= {len(cases)} mutations, got {mutations}"
    # A wrong expectation must be detected, not silently accepted.
    case = cases[0]
    mutated = json.loads(json.dumps(case))
    mutated["expected"]["state"] = "erased" if case["expected"]["state"] != "erased" else "current"
    try:
        module.assert_equal(module.resolve_case(case)["state"], mutated["expected"]["state"],
                            "test mutation")
    except AssertionError:
        pass
    else:
        raise AssertionError("wrong expectation was accepted")
    # Semantic rules that JSON Schema cannot express.
    bad = {
        "ref": "record://event/1", "roles": ["evidence"], "resolved": True, "erased": False,
        "state": "current", "reasons": ["source-changed"], "observed_at_ms": 1,
        "record_type": "tool/result", "trust": "observation",
    }
    for candidate in (bad, {**bad, "state": "changed", "reasons": []},
                      {**bad, "state": "erased", "reasons": ["source-changed"]}):
        try:
            module.check_semantics(candidate, "test")
        except AssertionError:
            continue
        raise AssertionError(f"semantic rule accepted {candidate['state']}")
    for revision in ({"basis": "etag"}, {"reason": None},
                     {"basis": "etag", "value": "e1"},
                     {"basis": "content-sha256", "value": "sha256:ABC"}):
        try:
            module.check_revision(revision, "test")
        except AssertionError:
            continue
        raise AssertionError(f"revision rule accepted {revision}")
    # Every golden schema itself must load and every invalid example must be
    # rejected by the real schema path.
    module.check_vectors(golden)
    print(f"provenance checker mutation test: PASS "
          f"(cases {len(cases)}, mutations {mutations}, deterministic, "
          f"semantic rules 3+4)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AssertionError as error:
        print(f"provenance checker mutation test: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
