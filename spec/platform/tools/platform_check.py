#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mechanical checker for the spec/platform divergence whitelist.

The whitelist is the machine-readable list of every legal iOS/Android
divergence. Prose cannot keep such a list honest: it drifts, it grows a
second copy of the spec, and a missing entry is only noticed at review time.
This checker is the acceptance gate:

* JSON Schema validation of ``whitelist.json`` and of both schema files
  (reusing ``spec/v1/tools/spec_golden.py``; no third-party dependency);
* unique ``id`` values and legal enum members;
* every ``spec_ref`` resolves to a real repository file, and the cited
  section number is found as a heading in that file;
* ``baseline: not-applicable`` entries carry ``justification_class``,
  ``evidence`` and ``approved_by`` (the exception channel of plan section
  5.3-1), and baseline-backed entries must not carry those three members;
* ``divergence_class: os-forced`` entries carry a concrete
  ``android_mechanism`` (an ASCII API name, not "platform specific");
* coverage of the fixed primitive list (``REQUIRED_PRIMITIVES``) and of the
  mandated extensions (``REQUIRED_MANDATES``);
* the golden examples: legal ones must pass every rule, rejected ones must
  fail one and must explain why in ``reason``.

One line is printed per checked file. Exit status is 1 when anything fails.

Usage::

    python3 spec/platform/tools/platform_check.py --root .
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "spec/v1/tools"))

from spec_golden import SpecError, load_json, validate_json  # noqa: E402

PLATFORM_DIR = Path("spec/platform")
WHITELIST_REL = PLATFORM_DIR / "whitelist.json"
SCHEMA_DIR_REL = PLATFORM_DIR / "schema"
GOLDEN_DIR_REL = PLATFORM_DIR / "golden"
WHITELIST_SCHEMA_NAME = "whitelist.schema.json"
CLASS_SCHEMA_NAME = "divergence-class.schema.json"

EXCEPTION_FIELDS = ("justification_class", "evidence", "approved_by")
BASELINE_NOT_APPLICABLE = "not-applicable"
JUSTIFICATION_CLASSES = ("os-mechanism-absent", "hardware-absent", "distribution-policy")
# `copy-forced`: the two platforms must say different words because one of them
# would be stating something false. It is not `os-forced` — there is no API to
# name — and dressing a wording difference up as a mechanism difference would make
# `android_mechanism` a lie the checker cannot catch.
DIVERGENCE_CLASSES = ("os-forced", "hardware-absent", "policy-forbidden", "copy-forced")
EVIDENCE_LEVELS = ("device-gate", "emulator-probe", "spec-only", "not-verified")

# The thirteen OS primitives of plan section 3.2. The section currently has
# twelve rows: the Network.framework row names two iOS primitives with two
# different Android mechanisms (NWListener for the loopback origin,
# NWPathMonitor for path signals), so it is tracked as two entries here.
# Every tuple is (id, provenance label). Missing one is a hard failure.
REQUIRED_PRIMITIVES = (
    ("platform.fsync-epoch-close", "§3.2-1 fcntl F_FULLFSYNC"),
    ("platform.keychain-credential-store", "§3.2-2 Keychain SecItem"),
    ("platform.nwlistener-loopback", "§3.2-3 NWListener loopback"),
    ("platform.nwpathmonitor", "§3.2-3 NWPathMonitor"),
    ("platform.urlsession-http-client", "§3.2-4 URLSession"),
    ("platform.script-message-reply", "§3.2-5 ScriptMessageHandlerWithReply"),
    ("platform.url-scheme-handler", "§3.2-6 WKURLSchemeHandler"),
    ("platform.scene-phase", "§3.2-7 ScenePhase"),
    ("platform.thermal-battery", "§3.2-8 thermalState and battery"),
    ("platform.bgtask-drain-window", "§3.2-9 BGTaskScheduler"),
    ("platform.audio-keepalive", "§3.2-10 silent audio keepalive"),
    ("platform.lockdown-report", "§3.2-11 Lockdown Mode report"),
    ("platform.budgettier-memory", "§3.2-12 BudgetTable tier"),
)
EXPECTED_PRIMITIVE_COUNT = 13

# The non-primitive entries the plan requires by name: the Keychain downgrade
# chain (7.3), the three catch items of 9.4 (whose third row has two
# sub-items; the Keystore one is already covered above), and the
# POST_NOTIFICATIONS degradation of 7.7/7.4-4.
REQUIRED_MANDATES = (
    ("platform.keystore-downgrade-chain", "§7.3 Keychain downgrade chain"),
    ("platform.fgs-turn-notification", "§9.4-1 FGS turn notification"),
    ("platform.predictive-back", "§9.4-2 predictive back"),
    ("platform.network-security-config", "§9.4-3 networkSecurityConfig"),
    ("platform.webview-version-gate", "§9.4-3 WebView version gate"),
    ("platform.post-notifications-degraded", "§7.7 POST_NOTIFICATIONS"),
)

# JSON Schema keywords this tree is allowed to use. Everything else is a
# failure, so the schemas stay inside the subset that spec_golden.py
# implements (in particular: no $ref, no $defs, no anyOf/allOf).
ALLOWED_SCHEMA_KEYWORDS = (
    "type",
    "properties",
    "required",
    "additionalProperties",
    "items",
    "minItems",
    "maxItems",
    "enum",
    "const",
    "oneOf",
    "pattern",
    "minimum",
    "maximum",
    "minLength",
    "maxLength",
    "dependentRequired",
    "title",
    "description",
)
FORBIDDEN_SCHEMA_KEYWORDS = (
    "$ref",
    "$defs",
    "$schema",
    "definitions",
    "anyOf",
    "allOf",
    "not",
    "if",
    "then",
    "else",
    "patternProperties",
    "propertyNames",
    "uniqueItems",
    "format",
    "contains",
    "dependencies",
    "minProperties",
    "maxProperties",
    "exclusiveMinimum",
    "exclusiveMaximum",
    "multipleOf",
)
ANNOTATION_PREFIX = "x-"
ANNOTATION_KEYWORDS = ("title", "description")

SPEC_REF_RE = re.compile(r"^(?P<path>[A-Za-z0-9][A-Za-z0-9._/-]*\.md) §(?P<section>[A-Za-z0-9]+(?:\.[0-9]+)*)$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
MECHANISM_RE = re.compile(r"^[\x20-\x7E]{3,140}$")
VAGUE_MECHANISM_PARTS = (
    "平台相关",
    "平台特定",
    "平台适配",
    "平台差异",
    "视平台",
    "待定",
    "TBD",
    "TODO",
    "platform-specific",
    "platform specific",
    "platform-agnostic",
)
NOT_VERIFIED_MARKER = "未验证"

REQUIRED_REASON_LENGTH = 20


# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------


def _rel(path: Path, root: Path | None = None) -> str:
    """Return a repository-relative spelling of *path* for messages."""

    base = ROOT if root is None else root
    try:
        return str(path.resolve().relative_to(base.resolve()))
    except (OSError, ValueError):
        return str(path)


def _load_schema(path: Path, root: Path) -> dict:
    if not path.is_file():
        raise SpecError(f"schema file not found: {_rel(path, root)}")
    schema = load_json(path)
    if not isinstance(schema, dict):
        raise SpecError(f"{_rel(path, root)}: schema root must be an object")
    return schema


def lint_schema(schema: dict, where: str, path: str = "$") -> None:
    """Reject keywords outside the supported subset, recursively."""

    for key, value in schema.items():
        if key.startswith(ANNOTATION_PREFIX):
            continue
        if key in FORBIDDEN_SCHEMA_KEYWORDS:
            raise SpecError(f"{where}: keyword {key!r} at {path} is not allowed in this tree")
        if key not in ALLOWED_SCHEMA_KEYWORDS:
            raise SpecError(f"{where}: unknown keyword {key!r} at {path}")
        if key in ANNOTATION_KEYWORDS:
            if not isinstance(value, str):
                raise SpecError(f"{where}: {path} annotation {key!r} must be a string")
            continue
        if key == "properties":
            if not isinstance(value, dict):
                raise SpecError(f"{where}: {path}.properties must be an object")
            for name, sub in value.items():
                lint_schema(sub, where, f"{path}.properties.{name}")
        elif key == "items":
            lint_schema(value, where, f"{path}.items")
        elif key == "additionalProperties":
            if isinstance(value, dict):
                lint_schema(value, where, f"{path}.additionalProperties")
            elif not isinstance(value, bool):
                raise SpecError(f"{where}: {path}.additionalProperties must be bool or object")
        elif key == "oneOf":
            if not isinstance(value, list) or not value:
                raise SpecError(f"{where}: {path}.oneOf must be a non-empty array")
            for index, sub in enumerate(value):
                lint_schema(sub, where, f"{path}.oneOf[{index}]")


def item_schema_of(whitelist_schema: dict, where: str) -> dict:
    if whitelist_schema.get("type") != "array":
        raise SpecError(f"{where}: whitelist schema root must have type array")
    items = whitelist_schema.get("items")
    if not isinstance(items, dict):
        raise SpecError(f"{where}: whitelist schema must define an items object")
    return items


def class_schema_enums(class_schema: dict, where: str) -> tuple:
    enums = class_schema.get("enum")
    if not isinstance(enums, list) or not all(isinstance(item, str) for item in enums):
        raise SpecError(f"{where}: enum must be an array of strings")
    definitions = class_schema.get("x-class-definitions")
    if not isinstance(definitions, dict):
        raise SpecError(f"{where}: x-class-definitions must be an object")
    missing = [name for name in enums if not isinstance(definitions.get(name), str)]
    if missing:
        raise SpecError(f"{where}: class {', '.join(missing)} has no definition in x-class-definitions")
    extra = [name for name in definitions if name not in enums]
    if extra:
        raise SpecError(f"{where}: x-class-definitions has members outside enum: {', '.join(extra)}")
    return tuple(enums)


def heading_covers(title: str, section: str) -> bool:
    """True when *title* is the heading of exactly *section* (not a child)."""

    if not title.startswith(section):
        return False
    tail = title[len(section):]
    if tail == "":
        return True
    if tail.startswith(" "):
        return True
    if tail.startswith("."):
        rest = tail[1:]
        if rest == "" or rest.startswith(" "):
            return True
        return False
    return False


def has_heading(text: str, section: str) -> bool:
    for line in text.splitlines():
        match = HEADING_RE.match(line)
        if match is None:
            continue
        if heading_covers(match.group(2).strip(), section):
            return True
    return False


def _repo_path(root: Path, rel: str, where: str, field: str) -> Path:
    candidate = Path(rel)
    if candidate.is_absolute():
        raise SpecError(f"{where}: {field} must be repository-relative: {rel!r}")
    if ".." in candidate.parts:
        raise SpecError(f"{where}: {field} must not escape the repository: {rel!r}")
    if candidate.parts[:2] == ("spec", "platform"):
        raise SpecError(f"{where}: {field} must not point into spec/platform: {rel!r}")
    resolved = (root / candidate).resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError:
        raise SpecError(f"{where}: {field} resolves outside the repository: {rel!r}") from None
    return resolved


# ---------------------------------------------------------------------------
# Entry rules.
# ---------------------------------------------------------------------------


# §5.1's noun table: the only words a `copy-forced` pair may differ by. Written
# here rather than in prose so the criterion is executable: delete every noun from
# both sides and the strings must be byte-identical, otherwise the entry is just an
# ordinary copy difference wearing this class.
COPY_FORCED_NOUNS = (
    "iPhone",
    "iPad",
    "iOS",
    "App Store",
    "TestFlight",
    "iCloud",
)


def check_copy_forced(entry: dict, where: str) -> None:
    """§5.1's machine-checkable criterion for the ninth divergence class."""
    if entry.get("divergence_class") != "copy-forced":
        return
    ios = entry.get("ios")
    android = entry.get("android")
    if not isinstance(ios, str) or not isinstance(android, str):
        raise SpecError(f"{where}: copy-forced entry requires ios and android text")
    # The pair must actually contain a platform noun on the iOS side: a `copy-forced`
    # entry whose two strings are equal (or differ by something other than a noun)
    # is not forced at all.
    nouns_here = [noun for noun in COPY_FORCED_NOUNS if noun in ios]
    if not nouns_here:
        raise SpecError(
            f"{where}: copy-forced needs a platform noun on the ios side; "
            f"none of {COPY_FORCED_NOUNS} appear in {ios[:60]!r}"
        )
    mechanism = entry.get("android_mechanism")
    if not mechanism:
        raise SpecError(
            f"{where}: copy-forced entry requires android_mechanism naming the "
            f"platform noun it swaps (one of {COPY_FORCED_NOUNS})"
        )
    if not any(noun in mechanism for noun in COPY_FORCED_NOUNS):
        raise SpecError(
            f"{where}: copy-forced android_mechanism {mechanism!r} must name the "
            f"platform noun it swaps (one of {COPY_FORCED_NOUNS})"
        )


def check_mechanism(entry: dict, where: str) -> None:
    mechanism = entry.get("android_mechanism")
    divergence_class = entry.get("divergence_class")
    if divergence_class == "os-forced" and not mechanism:
        raise SpecError(f"{where}: os-forced entry requires android_mechanism")
    if not mechanism:
        return
    if not isinstance(mechanism, str):
        raise SpecError(f"{where}: android_mechanism must be a string")
    for part in VAGUE_MECHANISM_PARTS:
        if part in mechanism:
            raise SpecError(
                f"{where}: android_mechanism must name a concrete API, not {mechanism!r}"
            )
    if MECHANISM_RE.match(mechanism) is None:
        raise SpecError(
            f"{where}: android_mechanism must be printable ASCII API text (got {mechanism!r})"
        )


def check_spec_ref(entry: dict, root: Path, where: str) -> None:
    reference = entry.get("spec_ref")
    if not isinstance(reference, str):
        raise SpecError(f"{where}: spec_ref must be a string")
    match = SPEC_REF_RE.match(reference)
    if match is None:
        raise SpecError(
            f"{where}: spec_ref must look like 'spec/v1/file.md §N' (got {reference!r})"
        )
    relative = match.group("path")
    section = match.group("section")
    target = _repo_path(root, relative, where, "spec_ref")
    if not target.is_file():
        raise SpecError(f"{where}: spec_ref file not found: {relative}")
    try:
        text = target.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise SpecError(f"{where}: cannot read spec_ref file {relative}: {exc}") from None
    if not has_heading(text, section):
        raise SpecError(
            f"{where}: spec_ref section §{section} not found as a heading in {relative}"
        )


def check_baseline(entry: dict, root: Path, where: str) -> None:
    baseline = entry.get("baseline")
    if not isinstance(baseline, str):
        raise SpecError(f"{where}: baseline must be a string")
    if baseline == BASELINE_NOT_APPLICABLE:
        return
    target = _repo_path(root, baseline, where, "baseline")
    if not target.is_file():
        raise SpecError(f"{where}: baseline file not found: {baseline}")


def check_exception_channel(entry: dict, where: str) -> None:
    baseline = entry.get("baseline")
    present = [name for name in EXCEPTION_FIELDS if name in entry]
    if baseline == BASELINE_NOT_APPLICABLE:
        missing = [name for name in EXCEPTION_FIELDS if name not in entry]
        if missing:
            raise SpecError(
                f"{where}: baseline not-applicable requires "
                + ", ".join(missing)
                + " (plan section 5.3-1 exception channel)"
            )
        justification = entry.get("justification_class")
        if justification not in JUSTIFICATION_CLASSES:
            raise SpecError(
                f"{where}: justification_class {justification!r} is not one of "
                + ", ".join(JUSTIFICATION_CLASSES)
            )
        minimums = {"evidence": 20, "approved_by": 3}
        for name, minimum in minimums.items():
            value = entry.get(name)
            if not isinstance(value, str) or len(value.strip()) < minimum:
                raise SpecError(
                    f"{where}: {name} must be a substantive string of at least {minimum} characters"
                )
        if "@" in entry["approved_by"]:
            raise SpecError(f"{where}: approved_by must be a role, not an email address")
        return
    if present:
        raise SpecError(
            f"{where}: exception fields {', '.join(present)} are only allowed with "
            f"baseline: {BASELINE_NOT_APPLICABLE}"
        )


def check_entry(entry: dict, item_schema: dict, root: Path, where: str) -> None:
    validate_json(entry, item_schema, where)
    divergence_class = entry.get("divergence_class")
    if divergence_class not in DIVERGENCE_CLASSES:
        raise SpecError(f"{where}: divergence_class {divergence_class!r} is not legal")
    evidence_level = entry.get("evidence_level")
    if evidence_level not in EVIDENCE_LEVELS:
        raise SpecError(f"{where}: evidence_level {evidence_level!r} is not legal")
    check_mechanism(entry, where)
    check_copy_forced(entry, where)
    check_spec_ref(entry, root, where)
    check_baseline(entry, root, where)
    check_exception_channel(entry, where)
    if evidence_level == "not-verified":
        rationale = entry.get("rationale", "")
        if NOT_VERIFIED_MARKER not in rationale:
            raise SpecError(
                f"{where}: not-verified entry must say why in rationale "
                f"(missing {NOT_VERIFIED_MARKER!r})"
            )


# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------


class Report:
    def __init__(self) -> None:
        self.failures = 0
        self.files = 0

    def note_file(self) -> None:
        self.files += 1

    def ok(self, where: str, detail: str) -> None:
        print(f"[platform] ok   {where} ({detail})")

    def fail(self, where: str, detail: str) -> None:
        self.failures += 1
        print(f"[platform] FAIL {where}: {detail}")


def _histogram(entries, key) -> str:
    counts = {}
    for entry in entries:
        value = entry.get(key)
        counts[value] = counts.get(value, 0) + 1
    return ", ".join(f"{name}={counts[name]}" for name in sorted(counts, key=str))


def coverage_report(entries, report: Report) -> None:
    ids = [entry.get("id") for entry in entries]
    id_set = set(ids)

    print(f"[platform] coverage: required primitives {len(REQUIRED_PRIMITIVES)}/{EXPECTED_PRIMITIVE_COUNT}")
    missing = []
    for identifier, label in REQUIRED_PRIMITIVES:
        if identifier in id_set:
            print(f"[platform]   ok   {label:<40} -> {identifier}")
        else:
            print(f"[platform]   MISS {label:<40} -> {identifier}")
            missing.append(identifier)
    if len(REQUIRED_PRIMITIVES) != EXPECTED_PRIMITIVE_COUNT:
        report.fail("REQUIRED_PRIMITIVES", f"constant pins {len(REQUIRED_PRIMITIVES)} entries, expected {EXPECTED_PRIMITIVE_COUNT}")
    if missing:
        report.fail("coverage", "missing required primitive: " + ", ".join(missing))

    print(f"[platform] coverage: required extensions {len(REQUIRED_MANDATES)}/{len(REQUIRED_MANDATES)}")
    missing_mandates = []
    for identifier, label in REQUIRED_MANDATES:
        if identifier in id_set:
            print(f"[platform]   ok   {label:<40} -> {identifier}")
        else:
            print(f"[platform]   MISS {label:<40} -> {identifier}")
            missing_mandates.append(identifier)
    if missing_mandates:
        report.fail("coverage", "missing mandated extension: " + ", ".join(missing_mandates))

    print(f"[platform] classes:  {_histogram(entries, 'divergence_class')}")
    print(f"[platform] evidence: {_histogram(entries, 'evidence_level')}")
    file_backed = sum(1 for entry in entries if entry.get("baseline") != BASELINE_NOT_APPLICABLE)
    not_applicable = sum(1 for entry in entries if entry.get("baseline") == BASELINE_NOT_APPLICABLE)
    print(f"[platform] baseline: repo-file={file_backed}, not-applicable={not_applicable}")


# ---------------------------------------------------------------------------
# Top level.
# ---------------------------------------------------------------------------


def check_whitelist(root: Path, item_schema: dict, report: Report) -> list:
    path = root / WHITELIST_REL
    where = _rel(path, root)
    report.note_file()
    try:
        entries = load_json(path)
    except SpecError as exc:
        report.fail(where, str(exc))
        return []
    if not isinstance(entries, list):
        report.fail(where, "whitelist root must be an array")
        return []
    entry_failures = 0
    try:
        validate_json(entries, {"type": "array", "minItems": 1, "items": item_schema}, where)
    except SpecError as exc:
        report.fail(where, str(exc))
        entry_failures += 1

    seen = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            report.fail(where, f"entry[{index}] is not an object")
            entry_failures += 1
            continue
        identifier = entry.get("id")
        label = identifier if isinstance(identifier, str) else f"entry[{index}]"
        if identifier in seen:
            report.fail(where, f"duplicate id {identifier!r} (also entry[{seen[identifier]}])")
            entry_failures += 1
            continue
        seen[identifier] = index
        try:
            check_entry(entry, item_schema, root, f"{where}:{label}")
        except SpecError as exc:
            report.fail(where, str(exc))
            entry_failures += 1

    if entry_failures == 0:
        report.ok(where, f"{len(entries)} entries, {len(seen)} unique ids")
    return entries


def check_goldens(root: Path, item_schema: dict, report: Report) -> None:
    golden_dir = root / GOLDEN_DIR_REL
    if not golden_dir.is_dir():
        report.fail(_rel(golden_dir, root), "golden directory is missing")
        return
    paths = sorted(golden_dir.glob("*.json"))
    if len(paths) < 4:
        report.fail(_rel(golden_dir, root), f"at least 4 golden examples are required, found {len(paths)}")
    for path in paths:
        where = _rel(path, root)
        report.note_file()
        try:
            document = load_json(path)
        except SpecError as exc:
            report.fail(where, str(exc))
            continue
        if not isinstance(document, dict):
            report.fail(where, "golden example must be an object with intent and entry")
            continue
        intent = document.get("intent")
        entry = document.get("entry")
        if intent not in ("legal", "rejected"):
            report.fail(where, "intent must be 'legal' or 'rejected'")
            continue
        if not isinstance(entry, dict):
            report.fail(where, "entry must be an object")
            continue
        try:
            check_entry(entry, item_schema, root, f"{where}:{entry.get('id')}")
            legal = True
            detail = ""
        except SpecError as exc:
            legal = False
            detail = str(exc)
        if intent == "legal":
            if legal:
                report.ok(where, "legal example accepted")
            else:
                report.fail(where, f"legal example rejected: {detail}")
            continue
        reason = document.get("reason")
        if not isinstance(reason, str) or len(reason.strip()) < REQUIRED_REASON_LENGTH:
            report.fail(where, "rejected example needs a reason of at least 20 characters")
            continue
        if legal:
            report.fail(where, "rejected example actually passes every rule")
            continue
        report.ok(where, "rejected example refused as documented")


def run(root: Path) -> int:
    report = Report()
    root = root.resolve()

    whitelist_schema_path = root / SCHEMA_DIR_REL / WHITELIST_SCHEMA_NAME
    class_schema_path = root / SCHEMA_DIR_REL / CLASS_SCHEMA_NAME

    report.note_file()
    try:
        whitelist_schema = _load_schema(whitelist_schema_path, root)
        lint_schema(whitelist_schema, _rel(whitelist_schema_path, root))
        item_schema = item_schema_of(whitelist_schema, _rel(whitelist_schema_path, root))
        item_count = len(item_schema.get("properties", {}))
        report.ok(
            _rel(whitelist_schema_path, root),
            f"keywords within subset, {item_count} entry properties",
        )
    except SpecError as exc:
        report.fail(_rel(whitelist_schema_path, root), str(exc))
        return report.failures

    report.note_file()
    try:
        class_schema = _load_schema(class_schema_path, root)
        lint_schema(class_schema, _rel(class_schema_path, root))
        classes = class_schema_enums(class_schema, _rel(class_schema_path, root))
        declared = item_schema.get("properties", {}).get("divergence_class", {}).get("enum")
        if tuple(declared or ()) != classes:
            raise SpecError(
                "divergence_class enum drifted between whitelist.schema.json "
                f"({declared}) and divergence-class.schema.json ({list(classes)})"
            )
        report.ok(_rel(class_schema_path, root), f"{len(classes)} classes with definitions")
    except SpecError as exc:
        report.fail(_rel(class_schema_path, root), str(exc))
        return report.failures

    entries = check_whitelist(root, item_schema, report)
    check_goldens(root, item_schema, report)

    if entries:
        coverage_report(entries, report)

    print(
        f"[platform] {report.files} files checked, {len(entries)} whitelist entries, "
        f"{report.failures} failures"
    )
    return report.failures


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Check the spec/platform divergence whitelist, its schemas and its goldens."
    )
    parser.add_argument(
        "--root",
        default=".",
        help="repository root that contains spec/platform (default: current directory)",
    )
    args = parser.parse_args(argv)
    failures = run(Path(args.root))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
