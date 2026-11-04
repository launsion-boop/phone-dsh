#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the PR22 -> Android provenance map.

The map (`docs/design/android-pr22-source-map.json`) is the machine-readable
answer to "where does every PR22 surface live on Android?". This gate keeps it
honest:

  * the schema tag, the four checked refs and the status enum are fixed;
  * every entry has at least one existing path + anchor, and every anchor string
    really occurs in the file it names;
  * all 27 PR22 ``*Page.swift`` files, ``HomeDrawer.swift``, ``HomeSpec.swift``
    and the eight design-spec sections are covered;
  * the six signature surfaces, the settings subpages, the schedule surfaces,
    the device/files/workbench surfaces and the host/runtime seams are present;
  * no absolute machine path (workspace, home, SDK or Windows drive) leaks into
    the data file;
  * the Fleet baseline JSON points at this map and at the two audit receipts and
    still says UNACCEPTED.

It validates source provenance only. A PASS does not accept the candidate, a
surface, or a screenshot: the receipt still has to record what was run.
"""

from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAP_PATH = ROOT / "docs" / "design" / "android-pr22-source-map.json"
BASELINE_PATH = ROOT / "docs" / "design" / "android-pr22-fleet-baseline.json"
STATUS_ENUM = {
    "implemented-on-candidate",
    "partial",
    "missing",
    "unverifiable",
}
REQUIRED_REFS = {
    "android_candidate",
    "android_pr14",
    "ios_pr22",
    "shared_main",
}
SIGNATURE_IDS = {
    "signature-bubble",
    "signature-tool-row",
    "signature-thinking-pill",
    "signature-approval-card",
    "signature-composer",
    "signature-fail-loud-banner",
}
DESIGN_SECTIONS = ("intro", "grid", "color", "type", "space", "shape", "components", "diff")
MIN_KIND_COUNTS = {
    "drawer": 1,
    "chrome": 2,
    "settings-subpage": 6,
    "schedule-surface": 5,
    "device-surface": 2,
    "files-surface": 1,
    "workbench-surface": 1,
    "host-runtime": 8,
}
# `docs/design/android-pr22-fleet-baseline.json` is extended by the same audit;
# the map and the receipts must stay linked from it.
BASELINE_FIELDS = (
    "source_map",
    "baseline_audit_receipt",
    "known_limitations_receipt",
)
_ABS_PREFIXES = ("work", "Users", "home", "opt", "tmp", "var", "private")
ABS_MACHINE_RE = re.compile(
    r"(?:"
    + "|".join(r"/" + re.escape(name) + r"/" for name in _ABS_PREFIXES)
    + r"|[A-Za-z]:[\\/])"
)


class GateError(Exception):
    """A failed provenance rule."""


def fail(message: str) -> None:
    raise GateError(message)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        fail("cannot read {}: {}".format(path.relative_to(ROOT), exc))


def load_json(path: Path):
    try:
        return json.loads(read_text(path))
    except json.JSONDecodeError as exc:
        fail("{} is not valid JSON: {}".format(path.relative_to(ROOT), exc))


def check_ref(entry_id: str, side: str, ref) -> int:
    if not isinstance(ref, dict):
        fail("{} {} ref is not an object".format(entry_id, side))
    path_value = ref.get("path")
    anchors = ref.get("anchors")
    if not isinstance(path_value, str) or not path_value.strip():
        fail("{} {} ref has no path".format(entry_id, side))
    if Path(path_value).is_absolute() or path_value.startswith("~"):
        fail("{} {} path must be repo-relative: {!r}".format(entry_id, side, path_value))
    if not isinstance(anchors, list) or not anchors:
        fail("{} {} ref {} has no anchors".format(entry_id, side, path_value))
    path = ROOT / path_value
    if not path.is_file():
        fail("{} {} path does not exist: {}".format(entry_id, side, path_value))
    text = read_text(path)
    for anchor in anchors:
        if not isinstance(anchor, str) or not anchor.strip():
            fail("{} {} anchor is empty".format(entry_id, side))
        if anchor not in text:
            fail(
                "{} {} anchor not found in {}: {!r}".format(
                    entry_id, side, path_value, anchor
                )
            )
    return len(anchors)


def check_no_absolute_paths(value, trail: str = "$") -> None:
    if isinstance(value, dict):
        for key, sub in value.items():
            check_no_absolute_paths(sub, "{}.{}".format(trail, key))
    elif isinstance(value, list):
        for index, sub in enumerate(value):
            check_no_absolute_paths(sub, "{}[{}]".format(trail, index))
    elif isinstance(value, str):
        if ABS_MACHINE_RE.search(value):
            fail("absolute machine path at {}: {!r}".format(trail, value))


def main() -> int:
    checks = []
    if not MAP_PATH.is_file():
        print("FAIL source map missing: docs/design/android-pr22-source-map.json")
        return 1
    document = load_json(MAP_PATH)

    # 1. Schema and status.
    if document.get("schema") != "pdsh.android-pr22-source-map/1":
        fail("schema must be 'pdsh.android-pr22-source-map/1'")
    if document.get("status") != "UNACCEPTED_AUDIT":
        fail("status must be 'UNACCEPTED_AUDIT' (this map never accepts the candidate)")
    refs = document.get("generated_from")
    if not isinstance(refs, dict) or not REQUIRED_REFS.issubset(refs):
        fail("generated_from misses one of {}".format(sorted(REQUIRED_REFS)))
    if len(str(refs.get("android_pr14"))) != 40 or len(str(refs.get("ios_pr22"))) != 40:
        fail("PR14/PR22 refs must be full 40-hex commit ids")
    for key in ("android_pr14", "ios_pr22", "shared_main"):
        if not re.fullmatch(r"[0-9a-f]{40}", str(refs[key])):
            fail("{} is not a 40-hex commit id".format(key))
    checks.append("schema/status/refs")

    entries = document.get("entries")
    if not isinstance(entries, list) or len(entries) < 50:
        fail("entries must be a list with at least 50 provenance rows")
    ids = set()
    statuses = Counter()
    kinds = Counter()
    ref_count = 0
    anchor_count = 0
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            fail("entry {} is not an object".format(index))
        entry_id = entry.get("id")
        if not isinstance(entry_id, str) or not entry_id.strip():
            fail("entry {} has no id".format(index))
        if entry_id in ids:
            fail("duplicate entry id {!r}".format(entry_id))
        ids.add(entry_id)
        status = entry.get("status")
        if status not in STATUS_ENUM:
            fail("{} has invalid status {!r}".format(entry_id, status))
        statuses[status] += 1
        kind = entry.get("kind")
        if not isinstance(kind, str) or not kind:
            fail("{} has no kind".format(entry_id))
        kinds[kind] += 1
        ios = entry.get("ios")
        android = entry.get("android")
        if not isinstance(ios, list) or not isinstance(android, list):
            fail("{} must have ios and android lists".format(entry_id))
        if not ios and not android:
            fail("{} has no anchor/file at all".format(entry_id))
        if not ios:
            fail("{} has no PR22 source anchor".format(entry_id))
        if status != "missing" and not android:
            fail("{} is {} but has no Android anchor".format(entry_id, status))
        for side, group in (("ios", ios), ("android", android)):
            for ref in group:
                anchor_count += check_ref(entry_id, side, ref)
                ref_count += 1
        evidence = entry.get("evidence")
        if not isinstance(evidence, list) or not evidence:
            fail("{} has no evidence".format(entry_id))
        if not isinstance(entry.get("notes"), str) or not entry["notes"].strip():
            fail("{} has no notes".format(entry_id))
    checks.append(
        "entries/anchors ({} entries, {} refs, {} anchors)".format(
            len(entries), ref_count, anchor_count
        )
    )

    # 2. PR22 source coverage: every page file, drawer, chrome and design section.
    ios_paths = {
        ref["path"]
        for entry in entries
        for ref in entry["ios"]
        if isinstance(ref, dict) and isinstance(ref.get("path"), str)
    }
    swift_pages = sorted(
        path.name
        for path in (ROOT / "examples" / "probe-app" / "PhoneDSHProbe").glob("*Page.swift")
    )
    if len(swift_pages) != 27:
        fail("expected 27 PR22 *Page.swift files, found {}".format(len(swift_pages)))
    missing_pages = [
        name
        for name in swift_pages
        if not any(path.endswith("/" + name) for path in ios_paths)
    ]
    if missing_pages:
        fail("source map does not cover PR22 pages: " + ", ".join(missing_pages))
    for required in ("HomeDrawer.swift", "HomeSpec.swift"):
        if not any(path.endswith("/" + required) for path in ios_paths):
            fail("source map does not cover {}".format(required))
    for section in DESIGN_SECTIONS:
        anchor = 'id="{}"'.format(section)
        if not any(
            ref["path"].endswith("ios-home-design-spec-no-overview.html")
            and anchor in ref.get("anchors", [])
            for entry in entries
            for ref in entry["ios"]
        ):
            fail("source map does not cover design section #{}".format(section))
    # Every `*Page` struct in the pinned PR22 tree (including private subpages
    # declared inside another file) must have an iOS anchor in the map.
    page_structs = set()
    for swift_file in (ROOT / "examples" / "probe-app" / "PhoneDSHProbe").glob("*.swift"):
        page_structs.update(re.findall(r"struct (\w+Page)\b", read_text(swift_file)))
    if len(page_structs) < 27:
        fail("expected at least 27 *Page structs, found {}".format(len(page_structs)))
    anchors = set()
    for entry in entries:
        for ref in entry["ios"]:
            anchors.update(ref.get("anchors", []))
    missing_structs = sorted(
        name for name in page_structs if "struct {}".format(name) not in anchors
    )
    if missing_structs:
        fail("source map misses PR22 Page structs: " + ", ".join(missing_structs))
    checks.append(
        "PR22 coverage (27 page files / {} Page structs + HomeDrawer + HomeSpec + {} design sections)".format(
            len(page_structs), len(DESIGN_SECTIONS)
        )
    )

    # 3. The named surface families.
    if not SIGNATURE_IDS.issubset(ids):
        fail("missing signature surfaces: {}".format(sorted(SIGNATURE_IDS - ids)))
    for kind, minimum in MIN_KIND_COUNTS.items():
        if kinds[kind] < minimum:
            fail(
                "kind {!r} needs at least {} entries, found {}".format(
                    kind, minimum, kinds[kind]
                )
            )
    checks.append("surface families (6 signatures + secondary/settings/schedule/device/host)")

    # 4. No absolute machine paths anywhere in the data.
    check_no_absolute_paths(document)
    checks.append("relative paths only")

    # 5. Baseline cross-links and unaccepted status.
    baseline = load_json(BASELINE_PATH)
    for field in BASELINE_FIELDS:
        value = baseline.get(field)
        if not isinstance(value, str) or not value.strip():
            fail("baseline JSON misses {}".format(field))
        candidate = ROOT / value
        if not candidate.is_file():
            fail("baseline {} points at a missing file: {}".format(field, value))
    status = str(baseline.get("status", ""))
    if "UNACCEPTED" not in status:
        fail("baseline status must stay UNACCEPTED, found {!r}".format(status))
    declared_counts = baseline.get("source_map_counts")
    actual_counts = {
        "entries": len(entries),
        "implemented_on_candidate": statuses["implemented-on-candidate"],
        "partial": statuses["partial"],
        "missing": statuses["missing"],
        "unverifiable": statuses["unverifiable"],
    }
    if declared_counts != actual_counts:
        fail(
            "baseline source_map_counts drift: declared {!r}, actual {!r}".format(
                declared_counts, actual_counts
            )
        )
    if baseline.get("source_map") != "docs/design/android-pr22-source-map.json":
        fail("baseline source_map must point at docs/design/android-pr22-source-map.json")
    for field in ("baseline_audit_receipt", "known_limitations_receipt"):
        if not str(baseline.get(field, "")).startswith("docs/receipts/android-pr22-alignment/"):
            fail("baseline {} must live under docs/receipts/android-pr22-alignment/".format(field))
    checks.append("baseline cross-links + UNACCEPTED")

    # Printed summary: a count is evidence, not acceptance.
    print("status counts: " + ", ".join(
        "{}={}".format(name, statuses[name]) for name in sorted(STATUS_ENUM)
    ))
    print("kind counts: " + ", ".join("{}={}".format(k, kinds[k]) for k in sorted(kinds)))
    for line in checks:
        print("PASS  " + line)
    print("OK {} checks passed; provenance only, candidate remains UNACCEPTED".format(len(checks)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GateError as exc:
        print("FAIL  " + str(exc))
        sys.exit(1)
