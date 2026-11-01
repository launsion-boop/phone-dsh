#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the normative scenario catalog and its assertion vocabulary.

This tool is the format referee for ``scripts/ci/scenarios/catalog.json``.
It reuses the small JSON Schema validator in ``spec/v1/tools/spec_golden.py``
(no third-party dependency), applies the two schemas added under
``spec/v1/schema/`` to the real documents, and then checks the invariants a
JSON Schema cannot express:

* scenario ids are unique and match the runner's id grammar;
* every catalog assertion type is one of the eight types in the assertion
  schema, and every one of those types has a dispatch case in the runner;
* workspace file keys and assertion paths stay relative (no absolute path and
  no ``..`` segment);
* every scenario keeps at least one turn and one assertion;
* the catalog's ``run_plan`` counts, lane coverage and budget sums agree with
  the scenarios array.

``scenario_batch.py`` is the batch orchestrator, not the assertion evaluator:
it names no assertion types today. The handler cross-check therefore uses the
batch file as the first textual source and falls back to the actual runner
dispatch table in ``ScenarioAssertionGate.swift`` when the batch file contains
no assertion names at all. A partial match in the batch file still fails, so a
batch layer that starts naming handlers cannot drift silently.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

CATALOG_REL = Path("scripts/ci/scenarios/catalog.json")
SELFTEST_REL = Path("scripts/ci/scenarios/selftest.json")
CATALOG_SCHEMA_REL = Path("spec/v1/schema/scenario-catalog.schema.json")
ASSERTION_SCHEMA_REL = Path("spec/v1/schema/scenario-assertion.schema.json")
BATCH_REL = Path("scripts/ci/scenario_batch.py")
GATE_REL = Path("Sources/PhoneDSHScenario/ScenarioAssertionGate.swift")

SCENARIO_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
LONG_RUN_CATEGORY = "long-run"
FORBIDDEN_SCHEMA_KEYWORDS = ("$ref", "$defs", "anyOf", "allOf")

_SPEC_MODULES = {}


class CatalogCheckError(Exception):
    """A malformed input or schema contract the checker cannot evaluate."""


def spec_module(root: Path):
    """Import ``spec_golden`` from *root*, exactly once per tools directory."""

    tools = (root / "spec/v1/tools").resolve()
    key = str(tools)
    if key in _SPEC_MODULES:
        return _SPEC_MODULES[key]
    if not (tools / "spec_golden.py").is_file():
        raise CatalogCheckError(
            "{}: spec_golden.py not found".format(tools / "spec_golden.py")
        )
    sys.path.insert(0, key)
    import spec_golden  # noqa: E402 - deliberate path-based stdlib-only import

    _SPEC_MODULES[key] = spec_golden
    return spec_golden


def assertion_variants(schema):
    """Return ``{type: variant}`` for the assertion schema's eight oneOf arms.

    The checker validates one assertion against its own arm rather than the
    whole ``oneOf`` so the diagnostic names the real defect (for example
    ``max is below 0``) instead of only reporting that no arm matched.
    """

    variants = schema.get("oneOf")
    if not isinstance(variants, list) or not variants:
        raise CatalogCheckError(
            "{}: oneOf must be a non-empty array".format(ASSERTION_SCHEMA_REL)
        )
    result = {}
    for index, variant in enumerate(variants):
        where = "{} oneOf[{}]".format(ASSERTION_SCHEMA_REL, index)
        if not isinstance(variant, dict):
            raise CatalogCheckError("{}: variant is not an object".format(where))
        if variant.get("additionalProperties") is not False:
            raise CatalogCheckError(
                "{}: assertion objects must be closed "
                "(additionalProperties: false)".format(where)
            )
        required = variant.get("required")
        if not isinstance(required, list) or "type" not in required:
            raise CatalogCheckError(
                "{}: required must list 'type'".format(where)
            )
        properties = variant.get("properties")
        if not isinstance(properties, dict) or not isinstance(
            properties.get("type"), dict
        ):
            raise CatalogCheckError(
                "{}: properties.type must be an object".format(where)
            )
        label = properties["type"].get("const")
        if not isinstance(label, str) or not label:
            raise CatalogCheckError(
                "{}: properties.type.const must be a non-empty string".format(where)
            )
        if label in result:
            raise CatalogCheckError(
                "{}: duplicate assertion type {!r}".format(where, label)
            )
        result[label] = variant
    return result


def assertion_types(schema):
    """Return the assertion type labels in schema declaration order."""

    return tuple(assertion_variants(schema))


def schema_keyword_findings(node, where="schema"):
    """Find schema keywords outside the stdlib validator's supported subset."""

    findings = []
    if isinstance(node, dict):
        for keyword in FORBIDDEN_SCHEMA_KEYWORDS:
            if keyword in node:
                findings.append(
                    "{}: schema keyword {!r} is forbidden; inline every "
                    "definition".format(where, keyword)
                )
        for key, value in node.items():
            findings.extend(schema_keyword_findings(value, "{}.{}".format(where, key)))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            findings.extend(
                schema_keyword_findings(value, "{}[{}]".format(where, index))
            )
    return findings


def _validate(instance, schema, where, spec_golden, path="$"):
    try:
        spec_golden.validate_json(instance, schema, where, path)
    except spec_golden.SpecError as exc:
        return [str(exc)]
    return []


def _path_findings(path, where):
    if not isinstance(path, str):
        return ["{}: path must be a string".format(where)]
    if not path:
        return ["{}: path must not be empty".format(where)]
    findings = []
    if path.startswith("/"):
        findings.append(
            "{}: absolute path {!r} is not allowed".format(where, path)
        )
    elif re.match(r"^[A-Za-z]:[\\/]", path):
        findings.append(
            "{}: absolute path {!r} is not allowed".format(where, path)
        )
    elif path == "~" or path.startswith("~/"):
        findings.append(
            "{}: home-relative path {!r} is not allowed".format(where, path)
        )
    if ".." in path.split("/"):
        findings.append(
            "{}: path {!r} must not contain '..'".format(where, path)
        )
    return findings


def _scenario_id_findings(scenarios, where):
    findings = []
    seen = {}
    for index, scenario in enumerate(scenarios):
        if not isinstance(scenario, dict):
            continue
        scenario_id = scenario.get("id")
        if not isinstance(scenario_id, str):
            continue
        if scenario_id in seen:
            findings.append(
                "{}: duplicate scenario id {!r} (scenarios {} and {})".format(
                    where, scenario_id, seen[scenario_id], index
                )
            )
        else:
            seen[scenario_id] = index
        if SCENARIO_ID_RE.fullmatch(scenario_id) is None:
            findings.append(
                "{}: scenario id {!r} does not match "
                "^[A-Za-z0-9._-]{{1,64}}$".format(where, scenario_id)
            )
    return findings


def _workspace_path_findings(scenarios, where):
    findings = []
    for index, scenario in enumerate(scenarios):
        if not isinstance(scenario, dict):
            continue
        scenario_id = scenario.get("id", "#{}".format(index))
        workspace = scenario.get("workspace")
        if isinstance(workspace, dict):
            files = workspace.get("files")
            if isinstance(files, dict):
                for name in files:
                    findings.extend(
                        _path_findings(
                            name,
                            "{}: scenario {!r} workspace.files".format(
                                where, scenario_id
                            ),
                        )
                    )
        assertions = scenario.get("assertions")
        if isinstance(assertions, list):
            for assertion_index, assertion in enumerate(assertions):
                if isinstance(assertion, dict) and "path" in assertion:
                    findings.extend(
                        _path_findings(
                            assertion["path"],
                            "{}: scenario {!r} assertion[{}].path".format(
                                where, scenario_id, assertion_index
                            ),
                        )
                    )
    return findings


def _fixture_findings(document, where):
    findings = []
    fixtures = document.get("fixtures")
    if not isinstance(fixtures, list):
        return findings
    names = []
    for fixture in fixtures:
        if not isinstance(fixture, dict):
            continue
        name = fixture.get("name")
        if not isinstance(name, str):
            continue
        if name in names:
            findings.append("{}: duplicate fixture name {!r}".format(where, name))
        names.append(name)
    known = set(names)
    scenarios = document.get("scenarios")
    if not isinstance(scenarios, list):
        return findings
    for scenario in scenarios:
        if not isinstance(scenario, dict):
            continue
        workspace = scenario.get("workspace")
        if not isinstance(workspace, dict):
            continue
        reference = workspace.get("fixture")
        if isinstance(reference, str) and reference not in known:
            findings.append(
                "{}: scenario {!r} references unknown fixture {!r}".format(
                    where, scenario.get("id"), reference
                )
            )
    return findings


def _run_plan_findings(document):
    where = str(CATALOG_REL)
    plan = document.get("run_plan")
    if not isinstance(plan, dict):
        return ["{}: run_plan is required for catalog.json".format(where)]

    scenarios = document["scenarios"]
    fixtures = document["fixtures"]
    findings = []
    scenario_ids = [scenario["id"] for scenario in scenarios]
    scenario_id_set = set(scenario_ids)

    inventory = plan["inventory"]
    if inventory["scenarios"] != len(scenarios):
        findings.append(
            "{}: run_plan.inventory.scenarios is {}, expected {}".format(
                where, inventory["scenarios"], len(scenarios)
            )
        )
    if inventory["fixtures"] != len(fixtures):
        findings.append(
            "{}: run_plan.inventory.fixtures is {}, expected {}".format(
                where, inventory["fixtures"], len(fixtures)
            )
        )
    split = inventory["normal_scenarios"] + inventory["long_run_scenarios"]
    if split != len(scenarios):
        findings.append(
            "{}: run_plan.inventory normal + long-run is {}, expected {}".format(
                where, split, len(scenarios)
            )
        )
    by_part = sum(inventory["by_part"].values())
    if by_part != len(scenarios):
        findings.append(
            "{}: run_plan.inventory.by_part sums to {}, expected {}".format(
                where, by_part, len(scenarios)
            )
        )

    lanes = plan["lane_plan"]
    lane_ids = set()
    assigned = {}
    for lane in lanes:
        lane_id = lane["id"]
        if lane_id in lane_ids:
            findings.append(
                "{}: run_plan.lane_plan repeats lane id {!r}".format(where, lane_id)
            )
        lane_ids.add(lane_id)
        for scenario_id in lane["scenario_ids"]:
            if scenario_id in assigned:
                findings.append(
                    "{}: run_plan.lane_plan duplicates scenario id {!r}".format(
                        where, scenario_id
                    )
                )
            assigned[scenario_id] = lane_id
            if scenario_id not in scenario_id_set:
                findings.append(
                    "{}: run_plan.lane_plan references unknown scenario id "
                    "{!r}".format(where, scenario_id)
                )
    for scenario_id in scenario_ids:
        if scenario_id not in assigned:
            findings.append(
                "{}: run_plan.lane_plan omits scenario id {!r}".format(
                    where, scenario_id
                )
            )

    budget = plan["budget"]
    total_minutes = sum(item["budget"]["max_minutes"] for item in scenarios)
    total_requests = sum(
        item["budget"]["max_model_requests"] for item in scenarios
    )
    normal = [
        item for item in scenarios if item["category"] != LONG_RUN_CATEGORY
    ]
    long_run = [
        item for item in scenarios if item["category"] == LONG_RUN_CATEGORY
    ]
    normal_minutes = sum(item["budget"]["max_minutes"] for item in normal)
    long_run_minutes = sum(item["budget"]["max_minutes"] for item in long_run)
    normal_requests = sum(
        item["budget"]["max_model_requests"] for item in normal
    )
    long_run_requests = sum(
        item["budget"]["max_model_requests"] for item in long_run
    )

    expected = (
        ("serial_max_minutes", total_minutes),
        ("serial_max_model_requests", total_requests),
        ("normal_50_max_minutes", normal_minutes),
        ("normal_50_max_model_requests", normal_requests),
        ("long_run_6_max_minutes", long_run_minutes),
        ("long_run_6_max_model_requests", long_run_requests),
    )
    for name, value in expected:
        if budget[name] != value:
            findings.append(
                "{}: run_plan.budget.{} is {}, expected {}".format(
                    where, name, budget[name], value
                )
            )

    largest = max(
        scenarios,
        key=lambda item: (
            item["budget"]["max_minutes"],
            item["budget"]["max_model_requests"],
        ),
    )
    declared_largest = budget["largest_scenario"]
    for name in ("id", "max_minutes", "max_model_requests"):
        expected_value = (
            largest["id"] if name == "id" else largest["budget"][name]
        )
        if declared_largest[name] != expected_value:
            findings.append(
                "{}: run_plan.budget.largest_scenario.{} is {!r}, expected "
                "{!r}".format(where, name, declared_largest[name], expected_value)
            )

    category_minutes = {}
    for item in scenarios:
        category = item["category"]
        category_minutes[category] = (
            category_minutes.get(category, 0) + item["budget"]["max_minutes"]
        )
    declared_minutes = plan["time_budget_by_category_minutes"]
    for category, minutes in category_minutes.items():
        if declared_minutes.get(category) != minutes:
            findings.append(
                "{}: run_plan.time_budget_by_category_minutes[{!r}] is {!r}, "
                "expected {}".format(
                    where, category, declared_minutes.get(category), minutes
                )
            )
    total_keys = [
        key for key in declared_minutes if key not in category_minutes
    ]
    if len(total_keys) != 1:
        findings.append(
            "{}: run_plan.time_budget_by_category_minutes must contain exactly "
            "one total key besides the categories, found {!r}".format(
                where, total_keys
            )
        )
    elif declared_minutes[total_keys[0]] != budget["serial_max_minutes"]:
        findings.append(
            "{}: run_plan.time_budget_by_category_minutes total is {}, "
            "expected run_plan.budget.serial_max_minutes {}".format(
                where,
                declared_minutes[total_keys[0]],
                budget["serial_max_minutes"],
            )
        )

    model_budget = plan["model_request_budget"]
    model_expected = (
        ("normal_50", normal_requests),
        ("long_run_6", long_run_requests),
        ("catalog_total", total_requests),
    )
    for name, value in model_expected:
        if model_budget[name] != value:
            findings.append(
                "{}: run_plan.model_request_budget.{} is {}, expected {}".format(
                    where, name, model_budget[name], value
                )
            )
    if model_budget["rerun_reserve_20pct"] < total_requests:
        findings.append(
            "{}: run_plan.model_request_budget.rerun_reserve_20pct is smaller "
            "than catalog_total".format(where)
        )
    if model_budget["requested_quota"] < model_budget["rerun_reserve_20pct"]:
        findings.append(
            "{}: run_plan.model_request_budget.requested_quota is smaller than "
            "rerun_reserve_20pct".format(where)
        )

    macos = plan["macos_pass"]
    for lane in lanes:
        lane_id = lane["id"]
        if lane_id not in macos["lanes"]:
            findings.append(
                "{}: run_plan.macos_pass.lanes is missing lane {!r}".format(
                    where, lane_id
                )
            )
        lane_scenarios = [
            item for item in scenarios if item["id"] in lane["scenario_ids"]
        ]
        declared_lane = macos["lane_budget"].get(lane_id)
        if not isinstance(declared_lane, dict):
            findings.append(
                "{}: run_plan.macos_pass.lane_budget is missing lane {!r}".format(
                    where, lane_id
                )
            )
            continue
        expected_minutes = sum(
            item["budget"]["max_minutes"] for item in lane_scenarios
        )
        expected_requests = sum(
            item["budget"]["max_model_requests"] for item in lane_scenarios
        )
        if declared_lane["max_minutes"] != expected_minutes:
            findings.append(
                "{}: run_plan.macos_pass.lane_budget[{!r}].max_minutes is {}, "
                "expected {}".format(
                    where,
                    lane_id,
                    declared_lane["max_minutes"],
                    expected_minutes,
                )
            )
        if declared_lane["max_model_requests"] != expected_requests:
            findings.append(
                "{}: run_plan.macos_pass.lane_budget[{!r}].max_model_requests "
                "is {}, expected {}".format(
                    where,
                    lane_id,
                    declared_lane["max_model_requests"],
                    expected_requests,
                )
            )
    return findings


def _catalog_invariants(document):
    where = str(CATALOG_REL)
    scenarios = document["scenarios"]
    findings = _scenario_id_findings(scenarios, where)
    findings.extend(_workspace_path_findings(scenarios, where))
    findings.extend(_fixture_findings(document, where))
    findings.extend(_run_plan_findings(document))
    return findings


def _selftest_invariants(document):
    where = str(SELFTEST_REL)
    scenarios = document["scenarios"]
    findings = _scenario_id_findings(scenarios, where)
    findings.extend(_workspace_path_findings(scenarios, where))
    findings.extend(_fixture_findings(document, where))
    return findings


def _assertion_findings(document, variants, spec_golden):
    findings = []
    allowed = ", ".join(variants)
    for scenario_index, scenario in enumerate(document["scenarios"]):
        scenario_id = scenario["id"]
        for assertion_index, assertion in enumerate(scenario["assertions"]):
            where = "{}: scenario {!r} assertion[{}]".format(
                CATALOG_REL, scenario_id, assertion_index
            )
            assertion_type = assertion.get("type")
            variant = variants.get(assertion_type)
            if variant is None:
                findings.append(
                    "{}: unknown assertion type {!r}; allowed: {}".format(
                        where, assertion_type, allowed
                    )
                )
                continue
            findings.extend(
                _validate(
                    assertion,
                    variant,
                    where,
                    spec_golden,
                    "$.scenarios[{}].assertions[{}]".format(
                        scenario_index, assertion_index
                    ),
                )
            )
    return findings


def check_catalog(document, catalog_schema, assertion_schema, spec_golden):
    """Return every finding for one catalog document (empty means valid)."""

    findings = _validate(document, catalog_schema, str(CATALOG_REL), spec_golden)
    if findings:
        return findings
    variants = assertion_variants(assertion_schema)
    findings = _catalog_invariants(document)
    findings.extend(_assertion_findings(document, variants, spec_golden))
    return findings


def check_selftest(document, catalog_schema, spec_golden,
                   assertion_schema=None, runner_types=None):
    """Return findings for selftest.json (the runner self-test document).

    selftest.json intentionally exercises runner-only assertion types
    (model_requests_lte, worker_command, session_error), so the eight-type
    catalog vocabulary is not required of every self-test assertion. When
    supplied, ``runner_types`` must still dispatch every self-test type (a
    typo is rejected) and ``assertion_schema`` validates the assertions that
    do use the catalog vocabulary.
    """

    findings = _validate(document, catalog_schema, str(SELFTEST_REL), spec_golden)
    if findings:
        return findings
    findings = _selftest_invariants(document)

    scenarios = document["scenarios"]
    variants = assertion_variants(assertion_schema) if assertion_schema else {}
    for scenario_index, scenario in enumerate(scenarios):
        scenario_id = scenario["id"]
        for assertion_index, assertion in enumerate(scenario["assertions"]):
            assertion_type = assertion.get("type")
            where = "{}: scenario {!r} assertion[{}]".format(
                SELFTEST_REL, scenario_id, assertion_index
            )
            if runner_types is not None and assertion_type not in runner_types:
                findings.append(
                    "{}: unknown runner assertion type {!r}".format(
                        where, assertion_type
                    )
                )
                continue
            variant = variants.get(assertion_type)
            if variant is not None:
                findings.extend(
                    _validate(
                        assertion,
                        variant,
                        where,
                        spec_golden,
                        "$.scenarios[{}].assertions[{}]".format(
                            scenario_index, assertion_index
                        ),
                    )
                )
    return findings


def runner_dispatch_types(root):
    """Return the assertion type names the runner dispatches, plus findings."""

    gate_path = root / GATE_REL
    try:
        gate_text = gate_path.read_text(encoding="utf-8")
    except OSError as exc:
        return set(), ["{}: cannot read: {}".format(GATE_REL, exc)]
    names = set(re.findall(r'case\s+"([A-Za-z0-9_]+)"\s*:', gate_text))
    return names, []


def check_handlers(root, types, gate_types=None):
    """Cross-check the schema vocabulary against the runner-side handler names.

    Returns ``(findings, detail)``. The batch orchestrator is the first textual
    source; when it names no assertion type at all (its current state), the
    actual runner dispatch table is the fallback. A partial batch match is a
    finding so a future batch-level table cannot drift.
    """

    types = set(types)
    findings = []
    batch_path = root / BATCH_REL
    try:
        batch_text = batch_path.read_text(encoding="utf-8")
    except OSError as exc:
        return (
            ["{}: cannot read: {}".format(BATCH_REL, exc)],
            "{} unreadable".format(BATCH_REL),
        )
    if gate_types is None:
        gate_types, gate_findings = runner_dispatch_types(root)
        findings.extend(gate_findings)
    else:
        gate_types = set(gate_types)

    batch_hits = {name for name in types if name in batch_text}
    gate_hits = types & gate_types
    gate_missing = types - gate_hits
    if gate_missing:
        findings.append(
            "{}: no dispatch case for {}".format(
                GATE_REL, ", ".join(sorted(gate_missing))
            )
        )
    if not batch_hits:
        detail = (
            "{} 0/{} (batch layer); {} {}/{}".format(
                BATCH_REL, len(types), GATE_REL, len(gate_hits), len(types)
            )
        )
    elif batch_hits == types:
        detail = "{} {}/{}; {} {}/{}".format(
            BATCH_REL, len(batch_hits), len(types),
            GATE_REL, len(gate_hits), len(types),
        )
    else:
        missing = types - batch_hits
        findings.append(
            "{}: missing assertion handler name(s) for {}".format(
                BATCH_REL, ", ".join(sorted(missing))
            )
        )
        detail = "{} {}/{}; {} {}/{}".format(
            BATCH_REL, len(batch_hits), len(types),
            GATE_REL, len(gate_hits), len(types),
        )
    return findings, detail


def _assertion_counts(document):
    counts = {}
    for scenario in document.get("scenarios", []):
        assertions = scenario.get("assertions", []) if isinstance(scenario, dict) else []
        for assertion in assertions:
            if not isinstance(assertion, dict):
                continue
            assertion_type = assertion.get("type")
            if isinstance(assertion_type, str):
                counts[assertion_type] = counts.get(assertion_type, 0) + 1
    return counts


def _counts_summary(document, order):
    counts = _assertion_counts(document)
    parts = ["{}={}".format(name, counts.get(name, 0)) for name in order]
    extras = sorted(set(counts) - set(order))
    parts.extend("{}={}".format(name, counts[name]) for name in extras)
    return " ".join(parts), sum(counts.values())


def _report_findings(label, findings):
    print("FAIL {}".format(label))
    for finding in findings:
        print("     - {}".format(finding))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Validate the normative phone-dsh scenario catalog."
    )
    parser.add_argument(
        "--root",
        default=".",
        help="repository root (default: current directory)",
    )
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()

    try:
        spec_golden = spec_module(root)
    except (CatalogCheckError, OSError, ImportError) as exc:
        print("FAIL {}".format(exc))
        return 1

    try:
        catalog_schema = spec_golden.load_json(root / CATALOG_SCHEMA_REL)
        assertion_schema = spec_golden.load_json(root / ASSERTION_SCHEMA_REL)
    except spec_golden.SpecError as exc:
        print("FAIL schema: {}".format(exc))
        return 1

    schema_findings = schema_keyword_findings(
        catalog_schema, str(CATALOG_SCHEMA_REL)
    ) + schema_keyword_findings(assertion_schema, str(ASSERTION_SCHEMA_REL))
    if schema_findings:
        for finding in schema_findings:
            print("FAIL {}".format(finding))
        print("catalog_check: FAIL ({} schema finding(s))".format(
            len(schema_findings)
        ))
        return 1

    try:
        variants = assertion_variants(assertion_schema)
    except CatalogCheckError as exc:
        print("FAIL {}".format(exc))
        return 1
    types = tuple(variants)

    failures = 0
    catalog_document = None
    runner_types, runner_findings = runner_dispatch_types(root)
    for finding in runner_findings:
        print("FAIL {}".format(finding))
        failures += 1

    try:
        catalog_document = spec_golden.load_json(root / CATALOG_REL)
    except spec_golden.SpecError as exc:
        print("FAIL {}: {}".format(CATALOG_REL, exc))
        failures += 1
    else:
        findings = check_catalog(
            catalog_document, catalog_schema, assertion_schema, spec_golden
        )
        scenario_count = len(catalog_document.get("scenarios", []))
        fixture_count = len(catalog_document.get("fixtures", []))
        _, assertion_count = _counts_summary(catalog_document, types)
        if findings:
            _report_findings(
                "{} (scenarios={} assertions={} fixtures={})".format(
                    CATALOG_REL, scenario_count, assertion_count, fixture_count
                ),
                findings,
            )
            failures += 1
        else:
            print(
                "ok   {}  scenarios={} assertions={} fixtures={}".format(
                    CATALOG_REL, scenario_count, assertion_count, fixture_count
                )
            )

    try:
        selftest_document = spec_golden.load_json(root / SELFTEST_REL)
    except spec_golden.SpecError as exc:
        print("FAIL {}: {}".format(SELFTEST_REL, exc))
        failures += 1
    else:
        findings = check_selftest(
            selftest_document,
            catalog_schema,
            spec_golden,
            assertion_schema,
            runner_types,
        )
        scenario_count = len(selftest_document.get("scenarios", []))
        fixture_count = len(selftest_document.get("fixtures", []))
        _, assertion_count = _counts_summary(selftest_document, types)
        if findings:
            _report_findings(
                "{} (scenarios={} assertions={} fixtures={})".format(
                    SELFTEST_REL, scenario_count, assertion_count, fixture_count
                ),
                findings,
            )
            failures += 1
        else:
            print(
                "ok   {}  scenarios={} assertions={} fixtures={}".format(
                    SELFTEST_REL, scenario_count, assertion_count, fixture_count
                )
            )

    handler_findings, handler_detail = check_handlers(
        root, types, gate_types=runner_types
    )
    if handler_findings:
        _report_findings("handler cross-check ({})".format(handler_detail), handler_findings)
        failures += 1
    else:
        print("ok   handler cross-check: {}".format(handler_detail))

    if catalog_document is not None and isinstance(catalog_document, dict):
        summary, total = _counts_summary(catalog_document, types)
        print("assertions (catalog): {} total={}".format(summary, total))
    else:
        print("assertions (catalog): unavailable")

    if failures:
        print("catalog_check: FAIL ({} finding(s))".format(failures))
        return 1
    print("catalog_check: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
