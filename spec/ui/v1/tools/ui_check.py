#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Checker for the dual-target UI reference (`spec/ui/v1`).

Enforces these rules:

1. no absolute font sizes anywhere in `typography.styles` (base value + system scale only);
2. `tokens.json`, both goldens and the schema itself are self-contained (no `$ref`/`$defs`);
3. tokens + goldens validate against `schema/tokens.schema.json` with the shared validator
   from `spec/v1/tools/spec_golden.py` (no second JSON Schema implementation);
4. every leaf token has a provenance line (`file.swift:line`, `system:...` or `unmeasured`)
   with a source tier the token group allows; the cited line must still exist and contain the
   token name/value (or the optional `expect` snippet), so stale provenance is a failure;
5. page-layer geometry is absorbed as tokens (value + unit + scalesWith), so the six
   surfaces have base values instead of prose; geometry that follows the font must derive
   from a typography token;
6. all six signature surfaces exist, are pixel-parity, reference existing tokens, carry at
   least one colour token and either a typography token or an explicit typography-unmeasured
   declaration (a surface whose sizes are system text styles or page-layer numbers);
7. WCAG 2.1 contrast for every ink-on-surface pair: body text >= 4.5, large text and non-text
   >= 3.0. Pairs marked `required: false` are the registered baseline accessibility debt: each
   needs an owner, a reviewBy date and a debtReason, they are printed with their measured ratio,
   and they only fail under `--strict`. A deferred pair that would now pass is a failure
   (promote it), and the deferred count is capped so the debt cannot quietly grow;
8. the eight platform divergences (the plan's seven plus the owner-approved share sheet) exist
   as a machine-readable JSON block, match the README table row for row, reference only real
   tokens and carry the Android type-role mapping for the system text styles;
9. README has the five normative sections, stays under the line cap, pins the mirror target,
   claims the inherited debt with owners and review dates, records the baseline observations,
   names all six signature surfaces and every deferred pair, and names every `*Page` struct that
   exists in the iOS probe app (the page cross-check is skipped when the probe app is absent);
10. README section 4 and `tokens.json` describe the same token composition: every surface's
   backticked token names must equal `signatureSurfaces.<name>.tokens` as a set (a missing token
   and an undeclared token are both failures), the table header must name a column for every
   token family the source uses, and every golden projection row may name only tokens that its
   surface declares (a row is a subset of the composition — partial projection is legal, a token
   outside the composition is not);
11. no external URL host, e-mail address or absolute user path appears in the data files.

Usage:
    python3 spec/ui/v1/tools/ui_check.py [--root DIR] [--strict]

Exit code 0 when every check passes, 1 on any mismatch, 2 on a usage or I/O error.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

UI_REL = Path("spec") / "ui" / "v1"
PROBE_REL = Path("examples") / "probe-app" / "PhoneDSHProbe"
# PR22 replaced the five-tab settings sheet with a grouped settings list and put
# the new/renamed pages (ArchivedSessionsPage, FontSizeSettingsPage,
# ConversationSettingsPage) into that list. The inventory still has to name every
# `*Page` struct, and it now carries the PR22 typography/geometry tables as well.
# 319 -> 345 is a recorded rule change for those normative tables, not a way to
# omit pages; the page cross-check below still fails if one is missing.
README_MAX_LINES = 345
MAX_DEFERRED_PAIRS = 7
REQUIRED_SURFACES = (
    "bubble",
    "toolRow",
    "thinkingPill",
    "approvalCard",
    "composer",
    "failLoudBanner",
)
REQUIRED_STYLES = (
    "navTitle",
    "navSubtitle",
    "body",
    "process",
    "listItem",
    "tabLabel",
)
DIVERGENCE_IDS = (
    "back-gesture",
    "font-scale",
    "ime",
    "insets",
    "scroll-refresh",
    "fgs-notification",
    "cjk-fallback",
    "share-sheet",
)
PLATFORM_DEFAULT_SOURCE = "platform default, not measured in this repo"
TYPE_ROLE_MAP = {"typography.navTitle": "Material titleMedium", "typography.navSubtitle": "Material titleSmall"}
PAGE_RE = re.compile(r"^\s*(?:private |fileprivate |public |internal )*struct (\w+Page)\b", re.M)
SECTION_RE = re.compile(r"^## (\d)\. (.+)$", re.M)
JSON_BLOCK_RE = re.compile(r"```json\s*(\{.*?\})\s*```", re.S)
ABSTRACT_KEY_RE = re.compile(r"(?i)(px$|^px|absolute|rendered|fontSize|pointSize|^sp$|^dp$)")
HEX_RE = re.compile(r"^#[0-9A-F]{6}$")
SWIFT_SOURCE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]*\.swift:[0-9]+$")
SYSTEM_SOURCE_RE = re.compile(r"^system:[A-Za-z0-9 .,'()#-]+$")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
URL_RE = re.compile(r"(?i)\b(?:https?|ftp|wss?)://|(?<![\w/])www\.[a-z0-9-]+\.[a-z]{2,}")
# Assembled from parts so this checker carries no absolute path literal of its own.
ABSOLUTE_USER_PATH = "/" + "Users" + "/"

# PR22 HomeSpec owns the product roles; retained component roles point to their
# current iOS owner. Old 402pt component sources remain excluded.
AUTHORITY_FILE = "HomeSpec.swift"
TYPE_SOURCE_FILES = (
    AUTHORITY_FILE, "NativeParityTokens.swift", "NativeChatPreferences.swift",
    "NativeChatTheme.swift", "Components.swift", "DSHComponents.swift",
    "MarkdownBody.swift", "SettingsChrome.swift",
)
GEOMETRY_SOURCE_FILES = (
    AUTHORITY_FILE, "Components.swift", "NativeMessageRows.swift", "ChatPage.swift",
    "NativeToolDetailCards.swift", "NativeDeviceSessionPage.swift",
    "NativeComposerStats.swift", "NativeShell.swift", "FilesPage.swift",
)
COMPONENT_COLOR_SOURCE_FILES = (
    "NativeParityTokens.swift", "Components.swift", "ChatPage.swift",
    "TaskScreenPage.swift", "Sources/PhoneDSH/Background/TaskScreen.swift",
)
SDK_TASK_SCREEN_SOURCE_RE = re.compile(
    r"^Sources/PhoneDSH/Background/TaskScreen\.swift:[0-9]+$"
)


def is_swift_source(source: str) -> bool:
    return bool(SWIFT_SOURCE_RE.match(source) or SDK_TASK_SCREEN_SOURCE_RE.match(source))


class CheckError(Exception):
    """A failed rule; carries the message printed after ``FAIL``."""


# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CheckError(f"cannot read {path}: {exc}") from exc
    except UnicodeDecodeError as exc:
        raise CheckError(f"{path} is not UTF-8: {exc}") from exc


def load_json(path: Path):
    try:
        return json.loads(read_text(path))
    except json.JSONDecodeError as exc:
        raise CheckError(f"{path} is not valid JSON: {exc}") from exc


def _channel(value: int) -> float:
    channel = value / 255.0
    if channel <= 0.04045:
        return channel / 12.92
    return ((channel + 0.055) / 1.055) ** 2.4


def relative_luminance(hex_value: str) -> float:
    """WCAG 2.1 relative luminance of an sRGB hex colour."""
    if not HEX_RE.match(hex_value):
        raise CheckError(f"colour {hex_value!r} is not #RRGGBB")
    red = _channel(int(hex_value[1:3], 16))
    green = _channel(int(hex_value[3:5], 16))
    blue = _channel(int(hex_value[5:7], 16))
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def contrast_ratio(foreground: str, background: str) -> float:
    first = relative_luminance(foreground)
    second = relative_luminance(background)
    lighter, darker = max(first, second), min(first, second)
    return (lighter + 0.05) / (darker + 0.05)


def resolve_token(document, reference: str):
    """Resolve ``group.name`` against a tokens document; ``None`` when absent."""
    if not isinstance(reference, str) or reference.count(".") != 1:
        return None
    group, name = reference.split(".")
    table = document.get(group)
    if not isinstance(table, dict):
        return None
    if group == "typography":
        styles = table.get("styles")
        if not isinstance(styles, dict):
            return None
        return styles.get(name)
    if name not in table:
        return None
    return table[name]


def numeric_literal_on_line(value, line: str) -> bool:
    """True when *value* appears on *line* as a whole numeric literal.

    Substring matching is not enough: 17 is a substring of 17.5, so a changed
    half-point size would otherwise keep a stale provenance line green.
    """
    literal = f"{value:g}" if isinstance(value, float) else str(value)
    return re.search(r"(?<![\d.])" + re.escape(literal) + r"(?![\d.])", line) is not None


def walk_keys(value, path="$"):
    """Yield (path, key, subvalue) for every dict member below *value*."""
    if isinstance(value, dict):
        for key, sub in value.items():
            yield path, key, sub
            for item in walk_keys(sub, f"{path}.{key}"):
                yield item
    elif isinstance(value, list):
        for index, sub in enumerate(value):
            for item in walk_keys(sub, f"{path}[{index}]"):
                yield item


# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------


class Report:
    def __init__(self) -> None:
        self.file_lines = []
        self.contrast_lines = []
        self.unmeasured_lines = []
        self.failures = []

    def file_ok(self, name: str, detail: str) -> None:
        self.file_lines.append(f"ok   {name:<42} {detail}")

    def contrast(self, line: str) -> None:
        self.contrast_lines.append(line)

    def unmeasured(self, line: str) -> None:
        self.unmeasured_lines.append(line)

    def fail(self, message: str) -> None:
        self.failures.append(message)


# ---------------------------------------------------------------------------
# Rule 1: base sizes + system scale, never an absolute font size.
# ---------------------------------------------------------------------------


def check_typography_units(document) -> None:
    typography = document.get("typography")
    if not isinstance(typography, dict):
        raise CheckError("tokens.json has no typography object")
    scale = typography.get("scale")
    if not isinstance(scale, dict) or scale.get("mode") != "system":
        raise CheckError("typography.scale.mode must be 'system' (base value x platform scale)")
    if scale.get("unit") != "pt":
        raise CheckError("typography.scale.unit must be 'pt' (a base size, not a device pixel)")
    drivers = scale.get("drivers") or {}
    if drivers.get("ios") != "dynamic-type" or drivers.get("android") != "font-scale":
        raise CheckError("typography.scale.drivers must name dynamic-type and font-scale")
    styles = typography.get("styles")
    if not isinstance(styles, dict) or not styles:
        raise CheckError("typography.styles is empty")
    for style_id, style in styles.items():
        if not isinstance(style, dict):
            raise CheckError(f"typography.styles.{style_id} is not an object")
        for key in style:
            if key in ("baseSize", "lineHeight", "weight", "mono", "role", "note", "needsDeviceMeasure"):
                continue
            if ABSTRACT_KEY_RE.search(key):
                raise CheckError(
                    f"typography.styles.{style_id}.{key}: absolute font sizes are forbidden; "
                    "store baseSize/lineHeight and let the platform scale it"
                )
            raise CheckError(f"typography.styles.{style_id}.{key}: unknown member")
        base = style.get("baseSize")
        # PR22 HomeSpec uses half-point sizes (17.5, 14.5, 10.5), so the base
        # value is a number, not an integer. It is still a base size: the
        # platform scale multiplies it and no rendered px is stored.
        if not isinstance(base, (int, float)) or isinstance(base, bool) or not 8 <= base <= 72:
            raise CheckError(f"typography.styles.{style_id}.baseSize must be a number 8..72")
        if "lineHeight" not in style:
            raise CheckError(f"typography.styles.{style_id} must declare lineHeight (null when HomeSpec does not define one)")
        line_height = style.get("lineHeight")
        if line_height is not None and (
            not isinstance(line_height, (int, float)) or isinstance(line_height, bool)
            or not 8 <= line_height <= 96
        ):
            raise CheckError(f"typography.styles.{style_id}.lineHeight must be a number 8..96 or null")
    for style_id in REQUIRED_STYLES:
        if style_id not in styles:
            raise CheckError(f"typography.styles is missing the canonical style {style_id!r}")


# ---------------------------------------------------------------------------
# Rule 2: self-contained schema (no references, no combinators we do not use).
# ---------------------------------------------------------------------------


def check_schema_is_self_contained(schema) -> int:
    banned = {"$ref", "$defs", "definitions", "anyOf", "allOf", "not", "if", "then", "else"}
    for where, key, _value in walk_keys(schema):
        if key in banned:
            raise CheckError(f"schema at {where} uses forbidden keyword {key!r}")
    variants = schema.get("oneOf")
    if not isinstance(variants, list) or len(variants) != 2:
        raise CheckError("schema root must be oneOf [tokens, surface-projection]")
    return len(variants)


# ---------------------------------------------------------------------------
# Rule 4: provenance coverage and tier/source consistency.
# ---------------------------------------------------------------------------


def expected_leaf_ids(document) -> set:
    leaves = set()
    colors = document.get("colors") or {}
    for name in colors:
        leaves.add(f"colors.{name}")
    styles = ((document.get("typography") or {}).get("styles") or {})
    for name in styles:
        leaves.add(f"typography.{name}")
    for group in ("spacing", "geometry", "radius", "stroke", "motion"):
        for name in document.get(group) or {}:
            leaves.add(f"{group}.{name}")
    return leaves


def check_provenance(document) -> list:
    provenance = document.get("provenance")
    if not isinstance(provenance, dict):
        raise CheckError("tokens.json has no provenance object")
    leaves = expected_leaf_ids(document)
    missing = sorted(leaves - set(provenance))
    stale = sorted(set(provenance) - leaves)
    if missing:
        raise CheckError(f"provenance is missing {len(missing)} token(s): {', '.join(missing[:4])}")
    if stale:
        raise CheckError(f"provenance names unknown token(s): {', '.join(stale[:4])}")
    unmeasured = []
    for token in sorted(provenance):
        entry = provenance[token]
        source = entry.get("source")
        tier = entry.get("tier")
        group = token.split(".")[0]
        if isinstance(source, str) and source == "unmeasured":
            if tier != "unmeasured":
                raise CheckError(f"provenance.{token}: source unmeasured needs tier unmeasured")
        if tier == "unmeasured":
            # A value that cannot be read as a constant: it may still name the definition site.
            if source != "unmeasured" and not (isinstance(source, str) and is_swift_source(source)):
                raise CheckError(f"provenance.{token}: unmeasured source must be 'unmeasured' or file.swift:line")
            if group == "colors":
                color = document["colors"][token.split(".")[1]]
                if color.get("light") is not None or color.get("dark") is not None:
                    raise CheckError(f"provenance.{token}: unmeasured colour must have null values")
            unmeasured.append(token)
            continue
        if not isinstance(source, str) or not (
            is_swift_source(source)
            or SYSTEM_SOURCE_RE.match(source)
            or source == PLATFORM_DEFAULT_SOURCE
        ):
            raise CheckError(
                f"provenance.{token}: source {source!r} is not file.swift:line, the allowed SDK path, "
                "system:... or the platform-default marker"
            )
        if tier == "system":
            if group == "typography":
                if source != PLATFORM_DEFAULT_SOURCE:
                    raise CheckError(
                        f"provenance.{token}: system text styles must use the platform-default marker"
                    )
                if entry.get("needsDeviceMeasure") is not True:
                    raise CheckError(f"provenance.{token}: system text styles need needsDeviceMeasure: true")
            elif not SYSTEM_SOURCE_RE.match(source):
                raise CheckError(f"provenance.{token}: tier system needs a system: source")
            continue
        if not is_swift_source(source):
            raise CheckError(f"provenance.{token}: tier {tier} needs a file.swift:line source")
        filename = source.split(":")[0]
        if group == "colors":
            color = document["colors"][token.split(".")[1]]
            if tier == "page":
                if color.get("baselineInconsistency") is not True:
                    raise CheckError(
                        f"provenance.{token}: a page-tier colour needs baselineInconsistency: true"
                    )
            elif tier == "theme" and filename == AUTHORITY_FILE:
                pass
            elif tier == "component":
                if filename not in COMPONENT_COLOR_SOURCE_FILES:
                    raise CheckError(
                        f"provenance.{token}: component colour owner must be one of "
                        + ", ".join(COMPONENT_COLOR_SOURCE_FILES)
                    )
                if not isinstance(entry.get("expect"), str):
                    raise CheckError(
                        f"provenance.{token}: component colours need an exact source-line expect anchor"
                    )
            else:
                raise CheckError(
                    f"provenance.{token}: theme colours must come from {AUTHORITY_FILE}; "
                    "component colours must be source-anchored with tier component; "
                    f"got {filename} / {tier!r}"
                )
        elif group in ("typography", "spacing"):
            if tier not in ("theme", "component"):
                raise CheckError(f"provenance.{token}: {group} needs tier theme or component, not {tier!r}")
            if filename not in TYPE_SOURCE_FILES:
                raise CheckError(f"provenance.{token}: {group} values must come from {', '.join(TYPE_SOURCE_FILES)}")
        elif group in ("geometry", "radius"):
            if tier not in ("component", "page"):
                raise CheckError(f"provenance.{token}: {group} needs tier component or page")
            if tier == "component" and filename not in GEOMETRY_SOURCE_FILES:
                raise CheckError(
                    f"provenance.{token}: component {group} must come from {', '.join(GEOMETRY_SOURCE_FILES)}"
                )
        elif group == "motion":
            if tier not in ("component", "page"):
                raise CheckError(f"provenance.{token}: motion needs tier component or page")
        elif tier not in ("theme", "component", "page"):
            raise CheckError(f"provenance.{token}: tier {tier!r} not allowed for {group}")
    return unmeasured


# ---------------------------------------------------------------------------
# Rule 4b: the cited source line still holds the token.
#
# `file.swift:line` on its own is not provenance: lines move and files get
# renamed, which is exactly how the old NativeChatTheme references stayed green
# after PR22 replaced the design. Every cited line must exist, and it must still
# carry the token name and value (colours: both hex literals; type/geometry:
# the name or the numeric value), or the optional `expect` snippet for page-layer
# lengths whose Swift line is a padding/frame call rather than a named constant.
# The probe app is absent in a spec-only checkout; then there is nothing to
# resolve against and the driver prints the check as skipped instead of passing
# it silently.
# ---------------------------------------------------------------------------


def check_provenance_sources(root: Path, document) -> tuple:
    probe = root / PROBE_REL
    if not probe.is_dir():
        return 0, False
    files = {}
    for path in sorted(probe.rglob("*.swift")):
        files.setdefault(path.name, path)
    checked = 0
    for token, entry in sorted((document.get("provenance") or {}).items()):
        source = entry.get("source")
        if not isinstance(source, str) or not is_swift_source(source):
            continue
        filename, line_text = source.split(":")
        line_number = int(line_text)
        path = root / filename if SDK_TASK_SCREEN_SOURCE_RE.match(source) else files.get(filename)
        if path is None:
            raise CheckError(
                f"provenance.{token}: stale source {source!r}; {filename} is not in the allowed iOS sources"
            )
        lines = read_text(path).splitlines()
        if not 1 <= line_number <= len(lines):
            raise CheckError(
                f"provenance.{token}: stale source {source!r}; {filename} has {len(lines)} line(s)"
            )
        cited = lines[line_number - 1]
        expect = entry.get("expect")
        leaf = token.split(".", 1)[1]
        group = token.split(".", 1)[0]
        tier = entry.get("tier")
        if isinstance(expect, str):
            if expect not in cited:
                raise CheckError(
                    f"provenance.{token}: stale source {source!r}; expected {expect!r} on that line"
                )
            if not (group == "colors" and tier == "component"):
                checked += 1
                continue
        evidence = False
        if group == "colors":
            color = document["colors"][leaf]
            if tier == "component":
                # Parse both channels and alpha from the actual Swift owner line;
                # `expect` anchors the semantic role but cannot bless a changed value.
                values = re.search(
                    r"light:\s*0x([0-9A-Fa-f]{6}).*dark:\s*0x([0-9A-Fa-f]{6})", cited
                )
                if values:
                    source_light = "#" + values.group(1).upper()
                    source_dark = "#" + values.group(2).upper()
                elif ".white" in cited or "Color.white" in cited:
                    source_light = source_dark = "#FFFFFF"
                elif ".black" in cited or "Color.black" in cited:
                    source_light = source_dark = "#000000"
                else:
                    source_light = source_dark = None
                if source_light != color.get("light"):
                    raise CheckError(
                        f"provenance.{token}: light value {color.get('light')!r} does not match source {source_light!r}"
                    )
                if source_dark != color.get("dark"):
                    raise CheckError(
                        f"provenance.{token}: dark value {color.get('dark')!r} does not match source {source_dark!r}"
                    )
                alphas = re.search(
                    r"lightAlpha:\s*([0-9.]+).*darkAlpha:\s*([0-9.]+)", cited
                )
                source_light_alpha, source_dark_alpha = (
                    (float(alphas.group(1)), float(alphas.group(2))) if alphas else (1.0, 1.0)
                )
                if abs(float(color.get("lightAlpha", 1)) - source_light_alpha) > 1e-9:
                    raise CheckError(f"provenance.{token}: light alpha does not match source")
                if abs(float(color.get("darkAlpha", 1)) - source_dark_alpha) > 1e-9:
                    raise CheckError(f"provenance.{token}: dark alpha does not match source")
                evidence = True
            else:
                light = color.get("light") or ""
                dark = color.get("dark") or ""
                upper = cited.upper()
                evidence = (
                    leaf in cited
                    and bool(light)
                    and bool(dark)
                    and f"0X{light[1:].upper()}" in upper
                    and f"0X{dark[1:].upper()}" in upper
                )
        elif group == "typography":
            base = document["typography"]["styles"][leaf].get("baseSize")
            evidence = leaf in cited and numeric_literal_on_line(base, cited)
        elif group == "geometry":
            value = document[group][leaf].get("value")
            evidence = leaf in cited and numeric_literal_on_line(value, cited)
        elif group in ("spacing", "radius"):
            value = document[group][leaf]
            evidence = leaf in cited and numeric_literal_on_line(value, cited)
        if not evidence:
            raise CheckError(
                f"provenance.{token}: stale source {source!r}; the line no longer names the token or its value"
            )
        checked += 1
    for metric, entry in sorted((document.get("componentMetrics") or {}).items()):
        source = entry.get("source")
        if not isinstance(source, str) or not SWIFT_SOURCE_RE.match(source):
            raise CheckError(f"componentMetrics.{metric}: source must be HomeSpec.swift:line")
        filename, line_text = source.split(":")
        lines = read_text(files.get(filename)).splitlines() if files.get(filename) else []
        line_number = int(line_text)
        if not 1 <= line_number <= len(lines):
            raise CheckError(f"componentMetrics.{metric}: stale source {source!r}")
        cited = lines[line_number - 1]
        if entry.get("expect") not in cited:
            raise CheckError(f"componentMetrics.{metric}: source {source!r} lost its expect anchor")
        if not numeric_literal_on_line(entry.get("value"), cited):
            raise CheckError(f"componentMetrics.{metric}: value does not match source {source!r}")
        checked += 1
    for role, entry in sorted((document.get("shadows") or {}).items()):
        source = entry.get("source")
        if not isinstance(source, str) or not is_swift_source(source):
            raise CheckError(f"shadows.{role}: source must be a Swift file:line owner")
        filename, line_text = source.split(":")
        path = root / filename if SDK_TASK_SCREEN_SOURCE_RE.match(source) else files.get(filename)
        lines = read_text(path).splitlines() if path is not None else []
        line_number = int(line_text)
        if not 1 <= line_number <= len(lines):
            raise CheckError(f"shadows.{role}: stale source {source!r}")
        cited = lines[line_number - 1]
        match = re.search(
            r"shadow\(color: \.black\.opacity\(([0-9.]+)\), radius: ([0-9.]+), y: ([0-9.]+)\)",
            cited,
        )
        if match is None:
            raise CheckError(f"shadows.{role}: source {source!r} no longer holds a shadow literal")
        for index, part in enumerate(("opacity", "radius", "y")):
            if abs(float(entry.get(part)) - float(match.group(index + 1))) > 1e-9:
                raise CheckError(f"shadows.{role}.{part} does not match source {source!r}")
        checked += 1
    return checked, True


# ---------------------------------------------------------------------------
# Rule 4c: compatibility tables resolve to real canonical leaves.
# ---------------------------------------------------------------------------


def check_aliases(document) -> int:
    aliases = document.get("aliases") or {}
    if not isinstance(aliases, dict):
        raise CheckError("aliases must be an object")
    checked = 0
    for family, table in aliases.items():
        if family not in ("colors", "typography", "spacing", "radius", "stroke", "motion", "geometry"):
            raise CheckError(f"aliases has unknown token family {family!r}")
        if not isinstance(table, dict):
            raise CheckError(f"aliases.{family} must be an object")
        for alias, target in table.items():
            if not isinstance(target, str) or resolve_token(document, target) is None:
                raise CheckError(f"aliases.{family}.{alias} targets unknown token {target!r}")
            if target.split(".", 1)[0] != family:
                raise CheckError(f"aliases.{family}.{alias} must target the same token family")
            checked += 1
    compatibility = document.get("componentCompatibility") or {}
    if not isinstance(compatibility, dict):
        raise CheckError("componentCompatibility must be an object")
    surfaces = document.get("signatureSurfaces") or {}
    for surface, entry in compatibility.items():
        if surface not in surfaces:
            raise CheckError(f"componentCompatibility.{surface} has no signature surface")
        tokens = entry.get("tokens") if isinstance(entry, dict) else None
        if not isinstance(tokens, list) or not tokens:
            raise CheckError(f"componentCompatibility.{surface}.tokens must be a non-empty list")
        for token in tokens:
            if resolve_token(document, token) is None:
                raise CheckError(f"componentCompatibility.{surface} names unknown token {token!r}")
        checked += len(tokens)
    return checked


# ---------------------------------------------------------------------------
# Rule 5b: page-layer geometry (absorbed so the six surfaces have a base value).
# ---------------------------------------------------------------------------


def check_geometry(document) -> int:
    geometry = document.get("geometry")
    if not isinstance(geometry, dict) or not geometry:
        raise CheckError("tokens.json has no geometry object (the six surfaces need page-layer base values)")
    units = ("pt", "screenRatio")
    for name, entry in geometry.items():
        if not isinstance(entry, dict):
            raise CheckError(f"geometry.{name} is not an object")
        value = entry.get("value")
        # 0 is a legal length: it means "no inset", not "unmeasured". Commit
        # 86a39aac took the composer's outer bottom padding from 8 to 0, so the
        # token has to be able to say zero instead of the value being deleted
        # (the surface still declares it). Negative lengths stay invalid, and a
        # screenRatio still has to be in (0, 1].
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
            raise CheckError(
                f"geometry.{name}.value must be a non-negative number (0 = no inset)"
            )
        if entry.get("unit") not in units:
            raise CheckError(f"geometry.{name}.unit must be one of {units}")
        if entry.get("unit") == "screenRatio" and not 0 < value <= 1:
            raise CheckError(f"geometry.{name}: a screenRatio must be in (0, 1]")
        if "scalesWith" not in entry:
            raise CheckError(
                f"geometry.{name} must declare scalesWith (null for a fixed value, or the typography token it follows)"
            )
        follows = entry["scalesWith"]
        if follows is not None:
            token = resolve_token(document, follows) if isinstance(follows, str) else None
            if not isinstance(follows, str) or not follows.startswith("typography.") or token is None:
                raise CheckError(
                    f"geometry.{name}.scalesWith {follows!r} is not an existing typography token; "
                    "geometry that follows the font must derive from typography, never a hard-coded number"
                )
    return len(geometry)


# ---------------------------------------------------------------------------
# Rule 5: the six signature surfaces.
# ---------------------------------------------------------------------------


def check_surfaces(document) -> int:
    surfaces = document.get("signatureSurfaces")
    if not isinstance(surfaces, dict):
        raise CheckError("tokens.json has no signatureSurfaces object")
    if set(surfaces) != set(REQUIRED_SURFACES):
        raise CheckError("signatureSurfaces must be exactly the six signed surfaces")
    references = 0
    for name in REQUIRED_SURFACES:
        surface = surfaces[name]
        if surface.get("surface") != name:
            raise CheckError(f"signatureSurfaces.{name}.surface must equal {name!r}")
        if surface.get("parity") != "pixel":
            raise CheckError(f"signatureSurfaces.{name}.parity must be 'pixel' (the only pixel set)")
        tokens = surface.get("tokens") or []
        if len(set(tokens)) != len(tokens):
            raise CheckError(f"signatureSurfaces.{name} repeats a token")
        groups = set()
        for reference in tokens:
            if resolve_token(document, reference) is None:
                raise CheckError(f"signatureSurfaces.{name} references unknown token {reference!r}")
            groups.add(reference.split(".")[0])
            references += 1
        if "colors" not in groups:
            raise CheckError(f"signatureSurfaces.{name} references no colour token")
        if "geometry" not in groups:
            raise CheckError(
                f"signatureSurfaces.{name} references no geometry token; page-layer geometry must be in tokens.json"
            )
        unmeasured = surface.get("unmeasured")
        if not isinstance(unmeasured, list):
            raise CheckError(f"signatureSurfaces.{name}.unmeasured must be a list (may be empty)")
        type_free = surface.get("typographyUnmeasured")
        if not isinstance(type_free, bool):
            raise CheckError(f"signatureSurfaces.{name}.typographyUnmeasured must be a boolean")
        if type_free and "typography" in groups:
            raise CheckError(
                f"signatureSurfaces.{name} declares typographyUnmeasured but still references a typography token"
            )
        if "typography" not in groups:
            if not type_free:
                raise CheckError(f"signatureSurfaces.{name} references no typography token")
            if not any("字号" in item for item in unmeasured):
                raise CheckError(
                    f"signatureSurfaces.{name}: typographyUnmeasured needs an unmeasured entry that says 字号"
                )
    return references


# ---------------------------------------------------------------------------
# Rule 6: WCAG contrast.
# ---------------------------------------------------------------------------


def check_contrast(document, strict: bool) -> tuple:
    contrast = document.get("contrast")
    if not isinstance(contrast, dict):
        raise CheckError("tokens.json has no contrast object")
    roles = contrast.get("roles") or {}
    if roles.get("body") != 4.5 or roles.get("large") != 3.0 or roles.get("nonText") != 3.0:
        raise CheckError("contrast.roles must pin body 4.5, large 3.0, nonText 3.0")
    colors = document.get("colors") or {}
    pairs = contrast.get("pairs") or []
    exempt = contrast.get("exempt") or []
    seen_ids = set()
    deferred = 0
    failures = []
    lines = []
    for pair in pairs:
        pair_id = pair.get("id")
        if pair_id in seen_ids:
            raise CheckError(f"contrast pair id {pair_id!r} is used twice")
        seen_ids.add(pair_id)
        foreground = pair.get("foreground")
        background = pair.get("background")
        for role in (foreground, background):
            if role not in colors:
                raise CheckError(f"contrast pair {pair_id}: unknown colour {role!r}")
        if pair.get("role") not in roles:
            raise CheckError(f"contrast pair {pair_id}: unknown role {pair.get('role')!r}")
        threshold = roles[pair["role"]]
        required = pair.get("required")
        if not isinstance(required, bool):
            raise CheckError(f"contrast pair {pair_id}: 'required' must be a boolean")
        light = colors[foreground].get("light")
        dark = colors[foreground].get("dark")
        light_bg = colors[background].get("light")
        dark_bg = colors[background].get("dark")
        if None in (light, dark, light_bg, dark_bg):
            raise CheckError(f"contrast pair {pair_id}: colour values are unmeasured, cannot compute")
        debt_suffix = ""
        if not required:
            owner = pair.get("owner")
            review_by = pair.get("reviewBy")
            debt_reason = pair.get("debtReason")
            if not isinstance(owner, str) or len(owner) < 3:
                raise CheckError(f"deferred contrast pair {pair_id} needs an owner")
            if not isinstance(review_by, str) or not re.match(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$", review_by):
                raise CheckError(f"deferred contrast pair {pair_id} needs a reviewBy date (YYYY-MM-DD)")
            if not isinstance(debt_reason, str) or len(debt_reason) < 12:
                raise CheckError(f"deferred contrast pair {pair_id} needs a debtReason")
            debt_suffix = f"  {owner} / {review_by}"
        ratios = {}
        for scheme, ink, under in (("light", light, light_bg), ("dark", dark, dark_bg)):
            ratio = contrast_ratio(ink, under)
            ratios[scheme] = ratio
            passed = ratio >= threshold
            verdict = "PASS " if passed else ("DEFER" if not required else "FAIL ")
            lines.append(
                f"  {verdict} {scheme:<5} {ratio:5.2f}  {pair_id:<26} {pair['role']:<8} {threshold:.2f}{debt_suffix}"
            )
        if required:
            for scheme in ("light", "dark"):
                if ratios[scheme] < threshold:
                    failures.append(
                        f"contrast {pair_id} ({scheme}) is {ratios[scheme]:.2f}, needs {threshold:.2f}"
                    )
            continue
        note = pair.get("note")
        if not isinstance(note, str) or len(note) < 12:
            raise CheckError(f"deferred contrast pair {pair_id} needs a note naming the gap")
        worst = min(ratios.values())
        if worst >= threshold:
            raise CheckError(
                f"contrast pair {pair_id} now passes at {worst:.2f} in both schemes; "
                "promote it to required: true instead of leaving it deferred"
            )
        deferred += 1
    if deferred > MAX_DEFERRED_PAIRS:
        raise CheckError(
            f"{deferred} deferred contrast pairs; the cap is {MAX_DEFERRED_PAIRS} — "
            "fix the token values or raise the cap deliberately"
        )
    if strict:
        for line in lines:
            if line.strip().startswith("DEFER"):
                failures.append(f"--strict: {line.strip()}")
    covered = set()
    for pair in pairs:
        covered.add(pair["foreground"])
        covered.add(pair["background"])
    for entry in exempt:
        token = entry.get("token")
        if token in covered:
            raise CheckError(f"contrast exempt {token!r} is also measured")
        if token not in colors:
            raise CheckError(f"contrast exempt names unknown colour {token!r}")
        covered.add(token)
    uncovered = sorted(set(colors) - covered)
    if uncovered:
        raise CheckError(
            "colours without a contrast pair or exemption: " + ", ".join(uncovered)
        )
    return lines, failures, deferred, len(pairs)


# ---------------------------------------------------------------------------
# Rule 7: platform divergence whitelist.
# ---------------------------------------------------------------------------


def parse_divergences(readme: str) -> list:
    for match in JSON_BLOCK_RE.finditer(readme):
        try:
            block = json.loads(match.group(1))
        except json.JSONDecodeError:
            continue
        if isinstance(block, dict) and "platformDivergences" in block:
            return block["platformDivergences"]
    raise CheckError("README has no ```json block with a platformDivergences list")


def check_divergences(readme: str, document) -> int:
    entries = parse_divergences(readme)
    if not isinstance(entries, list):
        raise CheckError("platformDivergences must be a list")
    ids = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise CheckError("platformDivergences entries must be objects")
        divergence_id = entry.get("id")
        ids.append(divergence_id)
        for member, minimum in (("android", 8), ("ios", 8), ("equivalence", 12)):
            value = entry.get(member)
            if not isinstance(value, str) or len(value) < minimum:
                raise CheckError(f"divergence {divergence_id!r}: {member} must be a string of {minimum}+ chars")
        tokens = entry.get("tokens", [])
        if not isinstance(tokens, list):
            raise CheckError(f"divergence {divergence_id!r}: tokens must be a list")
        for reference in tokens:
            if resolve_token(document, reference) is None:
                raise CheckError(f"divergence {divergence_id!r} references unknown token {reference!r}")
        if not re.search(r"^\|\s*" + re.escape(str(divergence_id)) + r"\s*\|", readme, re.M):
            raise CheckError(f"divergence {divergence_id!r} has no row in the README table")
        if divergence_id == "font-scale":
            mapping = entry.get("mapping")
            if not isinstance(mapping, dict) or set(mapping) != set(TYPE_ROLE_MAP):
                raise CheckError(
                    "the font-scale divergence must carry the type-role mapping for " + ", ".join(sorted(TYPE_ROLE_MAP))
                )
            for reference in mapping:
                if resolve_token(document, reference) is None:
                    raise CheckError(f"font-scale mapping names unknown token {reference!r}")
                if not isinstance(mapping[reference], str) or len(mapping[reference]) < 6:
                    raise CheckError(f"font-scale mapping for {reference!r} must name the Android type role")
    if len(ids) != len(set(ids)):
        raise CheckError("platformDivergences repeats an id")
    if set(ids) != set(DIVERGENCE_IDS):
        missing = sorted(set(DIVERGENCE_IDS) - set(ids))
        extra = sorted(set(ids) - set(DIVERGENCE_IDS))
        raise CheckError(f"divergences must be the fixed eight (missing {missing}, extra {extra})")
    return len(ids)


# ---------------------------------------------------------------------------
# Rule 8: README shape and page inventory.
# ---------------------------------------------------------------------------


def check_readme_shape(readme: str) -> tuple:
    lines = readme.splitlines()
    if len(lines) > README_MAX_LINES:
        raise CheckError(f"README is {len(lines)} lines, the cap is {README_MAX_LINES}")
    sections = [(int(number), title.strip()) for number, title in SECTION_RE.findall(readme)]
    numbers = [number for number, _ in sections]
    if numbers != [1, 2, 3, 4, 5]:
        raise CheckError(f"README needs sections ## 1. to ## 5. in order, found {numbers}")
    titles = [title for _, title in sections]
    expected = ("页面清单", "组件语义清单", "交互状态机", "签名面", "平台差异白名单")
    for title, keyword in zip(titles, expected):
        if keyword not in title:
            raise CheckError(f"README section {title!r} must mention {keyword!r}")
    return len(lines), sections


SURFACE_LABELS = {
    "bubble": "气泡",
    "toolRow": "工具行",
    "thinkingPill": "thinking_pill",
    "approvalCard": "审批卡",
    "composer": "composer",
    "failLoudBanner": "fail-loud",
}


def check_surface_docs(document, readme: str) -> int:
    """README section 4 must name all six surfaces and every deferred pair."""
    for name, label in SURFACE_LABELS.items():
        if label not in readme:
            raise CheckError(f"README does not document the signature surface {name!r} ({label})")
    deferred = [pair for pair in document["contrast"]["pairs"] if not pair["required"]]
    for pair in deferred:
        if pair["id"] not in readme:
            raise CheckError(f"README does not list the deferred contrast pair {pair['id']!r}")
        if pair["reviewBy"] not in readme:
            raise CheckError(f"README baseline-debt section misses reviewBy {pair['reviewBy']!r}")
    return len(deferred)


# ---------------------------------------------------------------------------
# Rule 10: README section 4 composition equals the single source.
#
# The table is hand-written prose and `tokens.json` is the single source, so the
# two drift the moment one side gains a token: `approvalCard` and `composer`
# gained `colors.primary` and `spacing.iconText` in the source while the table
# kept the old lists, and no rule compared them.  This rule parses the table
# itself -- backticked names, the display labels, the header columns -- and
# requires set equality per surface, in both directions, plus a header column
# for every token family the source uses (there was no `spacing` column at all).
# ---------------------------------------------------------------------------

SURFACE_TABLE_HEADER = "| 签名面 |"
# A family joins the table by naming its Chinese column word; a header may also
# spell it explicitly as `family.*` (that is how `spacing` is written today).
FAMILY_HEADER_WORDS = (
    ("颜色", "colors"),
    ("字号", "typography"),
    ("圆角", "radius"),
    ("描边", "stroke"),
    ("动效", "motion"),
    ("间距", "spacing"),
    ("几何", "geometry"),
)
BACKTICK_RE = re.compile(r"`([^`]+)`")


def canonical_surface_label(label: str):
    """Map a display label (`审批卡`, `fail-loud 横幅`) to its surface id."""
    for name, known in SURFACE_LABELS.items():
        if label == known or label.startswith(known):
            return name
    return None


def parse_surface_table(readme: str) -> tuple:
    """Return ({surface: {token, ...}}, families named by the header).

    Rows are read as written: the first cell is the display label, every
    backticked name in the remaining cells is a token, and a bare name belongs to
    the geometry column (`bubblePadding` means `geometry.bubblePadding`).
    """
    lines = readme.splitlines()
    header_index = None
    for index, line in enumerate(lines):
        if line.strip().startswith(SURFACE_TABLE_HEADER):
            header_index = index
            break
    if header_index is None:
        raise CheckError("README section 4 has no `| 签名面 |` table header")
    header_cells = [cell.strip() for cell in lines[header_index].strip().strip("|").split("|")]
    families = set()
    for cell in header_cells[1:]:
        for word, family in FAMILY_HEADER_WORDS:
            if word in cell:
                families.add(family)
        for prefixed in BACKTICK_RE.findall(cell):
            if prefixed.endswith(".*"):
                families.add(prefixed[: -len(".*")])
    rows = {}
    for line in lines[header_index + 1 :]:
        if not line.lstrip().startswith("|"):
            break
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not cells or set(cells[0]) <= set("-: "):
            continue  # the |---|---| separator
        label = cells[0]
        surface = canonical_surface_label(label)
        if surface is None:
            raise CheckError(
                f"README section 4 row {label!r} is not one of the six signature surfaces"
            )
        if surface in rows:
            raise CheckError(f"README section 4 documents the surface {surface!r} twice")
        tokens = set()
        for cell in cells[1:]:
            for name in BACKTICK_RE.findall(cell):
                name = name.strip()
                if not name or name.endswith(".*"):
                    continue
                tokens.add(name if "." in name else "geometry." + name)
        rows[surface] = tokens
    return rows, families


def check_surface_table(document, readme: str, projection=None) -> int:
    """README section 4 must match `tokens.json`; projection rows must stay inside it.

    Two different relations, on purpose:

    * a README row is that surface's *whole* composition, so it is compared as a
      set in both directions (an omitted token and an undeclared token both fail);
    * a projection row is one rendered row, i.e. a *partial* use of the surface,
      so it is compared as a subset: a row may omit tokens, it may never name a
      token the surface does not declare.

    A new token family needs both a column word in `FAMILY_HEADER_WORDS` and a
    column in the README table; the family error below names the family and the
    surfaces that use it, which is where the next person has to start.
    """
    rows, families = parse_surface_table(readme)
    surfaces = document.get("signatureSurfaces") or {}
    problems = []
    for name in REQUIRED_SURFACES:
        declared = set((surfaces.get(name) or {}).get("tokens") or [])
        documented = rows.get(name)
        if documented is None:
            problems.append(f"surface {name!r} has no row in the section 4 table")
            continue
        for token in sorted(declared - documented):
            problems.append(f"surface {name!r} omits token {token!r} declared by tokens.json")
        for token in sorted(documented - declared):
            problems.append(f"surface {name!r} lists token {token!r} not declared by tokens.json")
    used = {}
    for name in REQUIRED_SURFACES:
        for token in (surfaces.get(name) or {}).get("tokens") or []:
            used.setdefault(token.split(".", 1)[0], []).append(name)
    for family in sorted(set(used) - families):
        owners = ", ".join(sorted(set(used[family])))
        problems.append(
            f"the section 4 header has no column for token family {family!r} "
            f"(used by {owners}); a family with no column is how this drifted"
        )
    for row in (projection or {}).get("rows") or []:
        surface = row.get("surface")
        if surface not in REQUIRED_SURFACES:
            continue  # the driver already fails an unknown surface with its own message
        declared = set((surfaces.get(surface) or {}).get("tokens") or [])
        for token in row.get("tokens") or []:
            if token in declared:
                continue
            problems.append(
                f"projection row {row.get('row')!r} (surface {surface!r}) names token {token!r}, "
                f"which tokens.json does not declare for that surface "
                f"(a row may list a subset of the surface's tokens, never one outside it)"
            )
    if problems:
        raise CheckError("README section 4 vs tokens.json: " + "; ".join(problems))
    return sum(len(rows[name]) for name in REQUIRED_SURFACES)


# ---------------------------------------------------------------------------
# Rule 8b: the decisions that must stay written down in the README.
# ---------------------------------------------------------------------------

README_PHRASES = (
    ("镜像对象", "README must pin the mirror target in a 镜像对象 line"),
    ("已上线外壳", "the mirror target is the shipped shell (Chat + drawer), not the five-tab design draft"),
    ("Baseline accessibility debt", "README needs a Baseline accessibility debt section"),
    ("已知基线观察", "README needs a 已知基线观察 section"),
    ("只记录，不改基线", "the baseline observations are recorded, not fixed"),
    ("生成 Swift/Compose", "the P5 token generator must be registered as a work item"),
)
BASELINE_ANCHORS = ("SessionActivityPage", "DailyBriefPage", "NativeTab", "HomeSpec.swift:5",
                    "HomeSpec.swift:26", "HomeDrawer")


def check_readme_notes(readme: str) -> None:
    for phrase, message in README_PHRASES:
        if phrase not in readme:
            raise CheckError(message)
    for anchor in BASELINE_ANCHORS:
        if anchor not in readme:
            raise CheckError(f"README 已知基线观察 misses {anchor!r}")


def check_pages(root: Path, readme: str) -> tuple:
    probe = root / PROBE_REL
    if not probe.is_dir():
        return 0, False
    names = set()
    for path in sorted(probe.rglob("*.swift")):
        names.update(PAGE_RE.findall(read_text(path)))
    if not names:
        raise CheckError(f"no *Page struct found under {PROBE_REL}")
    missing = sorted(name for name in names if name not in readme)
    if missing:
        raise CheckError("README page inventory misses: " + ", ".join(missing))
    return len(names), True


# ---------------------------------------------------------------------------
# Rule 11: forbidden content in the data files.
# ---------------------------------------------------------------------------


def check_forbidden_content(files) -> None:
    for path, text in files:
        if ABSOLUTE_USER_PATH in text:
            raise CheckError(f"{path}: absolute user path is forbidden")
        email = EMAIL_RE.search(text)
        if email:
            raise CheckError(f"{path}: e-mail address {email.group(0)!r} is forbidden")
        url = URL_RE.search(text)
        if url:
            raise CheckError(f"{path}: external URL {url.group(0)!r} is forbidden")


# ---------------------------------------------------------------------------
# Driver.
# ---------------------------------------------------------------------------


def load_validator(root: Path):
    """Reuse the phone-dsh-v1 JSON Schema subset validator."""
    candidates = [root / "spec" / "v1" / "tools", Path(__file__).resolve().parents[4] / "spec" / "v1" / "tools"]
    for candidate in candidates:
        if (candidate / "spec_golden.py").is_file():
            sys.path.insert(0, str(candidate))
            from spec_golden import validate_json, SpecError

            return validate_json, SpecError
    raise SystemExit("ui_check: cannot find spec/v1/tools/spec_golden.py (the shared validator)")


def run(root: Path, strict: bool) -> int:
    ui = root / UI_REL
    if not ui.is_dir():
        print(f"ui_check: {ui} does not exist", file=sys.stderr)
        return 2
    validate_json, spec_error = load_validator(root)
    report = Report()
    deferred = 0
    pair_count = 0

    schema_path = ui / "schema" / "tokens.schema.json"
    tokens_path = ui / "tokens.json"
    readme_path = ui / "README.md"
    golden_tokens = ui / "golden" / "tokens.golden.json"
    golden_projection = ui / "golden" / "surface-projection.golden.json"
    for path in (schema_path, tokens_path, readme_path, golden_tokens, golden_projection):
        if not path.is_file():
            print(f"ui_check: missing {path.relative_to(root)}", file=sys.stderr)
            return 2

    def show(path: Path) -> str:
        return str(path.relative_to(root))

    try:
        schema = load_json(schema_path)
        document = load_json(tokens_path)
        golden_doc = load_json(golden_tokens)
        projection = load_json(golden_projection)
        readme = read_text(readme_path)

        variants = check_schema_is_self_contained(schema)
        check_typography_units(document)
        unmeasured = check_provenance(document)

        for label, instance, path in (
            ("tokens.json", document, tokens_path),
            ("golden tokens", golden_doc, golden_tokens),
            ("golden projection", projection, golden_projection),
        ):
            try:
                validate_json(instance, schema, show(path))
            except spec_error as exc:
                raise CheckError(f"{label}: {exc}") from exc

        sourced, sourced_checked = check_provenance_sources(root, document)
        geometry_count = check_geometry(document)
        alias_count = check_aliases(document)
        references = check_surfaces(document)
        contrast_lines, contrast_failures, deferred, pair_count = check_contrast(document, strict)
        for line in contrast_lines:
            report.contrast(line)
        for failure in contrast_failures:
            report.fail(failure)
        divergence_count = check_divergences(readme, document)
        deferred_documented = check_surface_docs(document, readme)
        documented_tokens = check_surface_table(document, readme, projection)
        check_readme_notes(readme)
        readme_lines, sections = check_readme_shape(readme)
        page_count, page_checked = check_pages(root, readme)

        for reference in unmeasured:
            group, leaf = reference.split(".", 1)
            if group == "geometry":
                entry = document["geometry"][leaf]
                detail = f"value {entry.get('value')} {entry.get('unit')}"
            else:
                detail = "value null"
            report.unmeasured(f"  token    {reference} ({detail}, tier unmeasured)")
        if sourced_checked:
            report.unmeasured(f"  source   {sourced} file:line provenance anchors resolved against the PR22 probe app")
        else:
            report.unmeasured("  source   provenance line check skipped (probe app absent)")
        surface_items = 0
        surface_lines = []
        for name in REQUIRED_SURFACES:
            items = document["signatureSurfaces"][name].get("unmeasured") or []
            surface_items += len(items)
            if items:
                surface_lines.append(f"  surface  {name:<22} {len(items)} item(s) not tokenised")
        if not surface_items:
            surface_lines.append("  surface  all six signature surfaces fully tokenised (geometry absorbed)")
        for line in surface_lines:
            report.unmeasured(line)

        # Golden cross-checks: every projected surface is one of the six and every token exists.
        seen_surfaces = set()
        for row in projection.get("rows") or []:
            surface = row.get("surface")
            if surface not in REQUIRED_SURFACES:
                raise CheckError(f"projection row {row.get('row')!r} uses unknown surface {surface!r}")
            seen_surfaces.add(surface)
            for reference in row.get("tokens") or []:
                if resolve_token(document, reference) is None:
                    raise CheckError(f"projection row {row.get('row')!r} references unknown token {reference!r}")
        missing_surfaces = sorted(set(REQUIRED_SURFACES) - seen_surfaces)
        if missing_surfaces:
            raise CheckError("projection example does not exercise: " + ", ".join(missing_surfaces))
        golden_surfaces = golden_doc.get("signatureSurfaces") or {}
        for name in REQUIRED_SURFACES:
            for reference in (golden_surfaces.get(name) or {}).get("tokens") or []:
                if resolve_token(golden_doc, reference) is None:
                    raise CheckError(f"golden tokens: surface {name} references unknown token {reference!r}")

        check_forbidden_content(
            [
                (show(readme_path), readme),
                (show(tokens_path), read_text(tokens_path)),
                (show(golden_tokens), read_text(golden_tokens)),
                (show(golden_projection), read_text(golden_projection)),
                (show(schema_path), read_text(schema_path)),
            ]
        )

        report.file_ok(
            show(schema_path),
            f"{variants} variants, no $ref/$defs, subset keywords only",
        )
        report.file_ok(
            show(tokens_path),
            f"{len(document['colors'])} colours, {len(document['typography']['styles'])} styles, "
            f"{geometry_count} geometry tokens, {len(document['signatureSurfaces'])} surfaces, "
            f"{references} token refs, {pair_count} contrast pairs",
        )
        report.file_ok(
            show(golden_tokens),
            f"schema ok, {len(golden_doc['signatureSurfaces'])} surface ref sets resolved",
        )
        report.file_ok(
            show(golden_projection),
            f"schema ok, {len(projection['events'])} events -> {len(projection['rows'])} rows, "
            f"{len(seen_surfaces)}/6 surfaces",
        )
        page_note = f"{page_count} *Page structs documented" if page_checked else "probe app absent, cross-check skipped"
        report.file_ok(
            show(readme_path),
            f"{readme_lines}/{README_MAX_LINES} lines, {len(sections)} sections, "
            f"{divergence_count} divergences, {documented_tokens} section-4 tokens, "
            f"{deferred_documented} deferred pairs, {page_note}",
        )
    except CheckError as exc:
        report.fail(str(exc))
    except spec_error as exc:  # pragma: no cover - defensive
        report.fail(str(exc))
    except json.JSONDecodeError as exc:
        report.fail(f"invalid JSON: {exc}")

    print("== files ==")
    for line in report.file_lines:
        print(line)
    if report.contrast_lines:
        print("== contrast (WCAG 2.1 relative luminance) ==")
        for line in report.contrast_lines:
            print(line)
    if report.unmeasured_lines:
        print("== unmeasured register ==")
        for line in report.unmeasured_lines:
            print(line)
    if report.failures:
        print("== failures ==")
        for failure in report.failures:
            print(f"FAIL {failure}")
        print(f"ui_check: FAILED ({len(report.failures)} failure(s))")
        return 1
    print(
        f"ui_check: ok ({len(report.file_lines)} files, {pair_count} contrast pairs, "
        f"{deferred} deferred AA pairs, {len(unmeasured)} unmeasured tokens, "
        f"{surface_items} unmeasured surface items, {geometry_count} geometry tokens)"
    )
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Check the dual-target UI reference in spec/ui/v1.")
    parser.add_argument("--root", default=".", help="repository root (default: current directory)")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="also fail the deferred contrast pairs inherited from the iOS baseline",
    )
    args = parser.parse_args(argv)
    return run(Path(args.root).resolve(), args.strict)


if __name__ == "__main__":
    sys.exit(main())
