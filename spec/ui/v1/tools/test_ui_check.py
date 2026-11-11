#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for the `spec/ui/v1` checker.

Every test runs `tools/ui_check.py` through its command-line interface on a temporary copy of the
specification tree, so the real tree is never modified. Each mutation breaks exactly one rule and
asserts both the exit code and the diagnostic that names the broken rule.
"""

from __future__ import annotations

import importlib.util
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
UI_DIR = ROOT / "spec" / "ui" / "v1"
SPEC_V1 = ROOT / "spec" / "v1"

FORBIDDEN_URL = "https" + "://" + "example" + ".com/leak"


def run_checker(root: Path, strict: bool = False) -> subprocess.CompletedProcess:
    command = [sys.executable, str(root / "spec" / "ui" / "v1" / "tools" / "ui_check.py"), "--root", str(root)]
    if strict:
        command.append("--strict")
    return subprocess.run(command, capture_output=True, text=True, check=False)


def load_checker():
    path = UI_DIR / "tools" / "ui_check.py"
    loader = importlib.util.spec_from_file_location("ui_check_under_test", path)
    module = importlib.util.module_from_spec(loader)
    loader.loader.exec_module(module)
    return module


class UiCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(
            UI_DIR,
            self.root / "spec" / "ui" / "v1",
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
        shutil.copytree(
            SPEC_V1,
            self.root / "spec" / "v1",
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
        # Provenance is now checked against the real PR22 source lines, not just
        # the shape of a `file.swift:line` string. Copy the probe app so the
        # control run resolves every anchor; a spec-only checkout still skips
        # that check (see test_page_cross_check_skipped_without_probe_app).
        probe_source = ROOT / "examples" / "probe-app" / "PhoneDSHProbe"
        probe = self.root / "examples" / "probe-app" / "PhoneDSHProbe"
        if probe_source.is_dir():
            shutil.copytree(
                probe_source,
                probe,
                ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".build", "DerivedData"),
            )
        else:
            probe.mkdir(parents=True)
            (probe / "ChatPage.swift").write_text("struct ChatPage: View {}\n", encoding="utf-8")
            (probe / "MemoryPage.swift").write_text("struct MemoryPage: View {}\n", encoding="utf-8")
        # One measured source lives in the repository's PhoneDSH SDK, outside
        # the probe app. Copy only this explicit owner path for provenance tests.
        sdk_source = ROOT / "Sources" / "PhoneDSH" / "Background" / "TaskScreen.swift"
        if sdk_source.is_file():
            sdk_target = self.root / "Sources" / "PhoneDSH" / "Background" / "TaskScreen.swift"
            sdk_target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(sdk_source, sdk_target)

    # -- helpers ---------------------------------------------------------

    @property
    def ui(self) -> Path:
        return self.root / "spec" / "ui" / "v1"

    def tokens(self) -> dict:
        return json.loads((self.ui / "tokens.json").read_text(encoding="utf-8"))

    def write_tokens(self, document: dict) -> None:
        (self.ui / "tokens.json").write_text(
            json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )

    def drawer_golden(self) -> tuple:
        path = self.ui / "golden" / "drawer-gesture.golden.json"
        return path, json.loads(path.read_text(encoding="utf-8"))

    def write_drawer_golden(self, path: Path, document: dict) -> None:
        path.write_text(
            json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )

    def read_readme(self) -> str:
        return (self.ui / "README.md").read_text(encoding="utf-8")

    def write_readme(self, text: str) -> None:
        (self.ui / "README.md").write_text(text, encoding="utf-8")

    def assert_fails(self, result: subprocess.CompletedProcess, needle: str) -> None:
        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn(needle, result.stdout + result.stderr)
        self.assertIn("FAIL", result.stdout)

    def assert_passes(self, result: subprocess.CompletedProcess) -> None:
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("ui_check: ok", result.stdout)

    # -- the unmodified copy is the control ---------------------------------

    def test_unmodified_copy_passes(self) -> None:
        result = run_checker(self.root)
        self.assert_passes(result)
        self.assertIn("contrast", result.stdout)
        self.assertIn("PASS  light", result.stdout)

    # -- 1. a signature surface points at a token that does not exist -------

    def test_missing_signature_token_fails(self) -> None:
        document = self.tokens()
        document["signatureSurfaces"]["composer"]["tokens"][0] = "colors.inputt"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "unknown token 'colors.inputt'")

    # -- 2. a required pair drops below its WCAG threshold ------------------

    def test_contrast_below_threshold_fails(self) -> None:
        document = self.tokens()
        document["contrast"]["pairs"][0]["foreground"] = "textSubtle"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "contrast textPrimary/surface")

    # -- 3. the whitelist loses one of the seven rows -----------------------

    def test_platform_divergence_missing_fails(self) -> None:
        readme = self.read_readme()
        kept = [
            line
            for line in readme.splitlines(keepends=True)
            if '{"id": "fgs-notification"' not in line
        ]
        self.assertNotEqual(len(kept), len(readme.splitlines(keepends=True)))
        self.write_readme("".join(kept))
        self.assert_fails(run_checker(self.root), "divergences must be the fixed eight")

    def test_divergence_token_reference_fails(self) -> None:
        readme = self.read_readme().replace('"tokens": ["typography.body"', '"tokens": ["typography.boddy"', 1)
        self.write_readme(readme)
        self.assert_fails(run_checker(self.root), "typography.boddy")

    # -- 4. an absolute font size sneaks back in ----------------------------

    def test_absolute_font_size_fails(self) -> None:
        document = self.tokens()
        document["typography"]["styles"]["body"]["fontSizePx"] = 14
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "absolute font sizes are forbidden")

    # -- 4b. PR22 composition facts the generic rules cannot infer ----------

    def test_composer_composition_has_no_border(self) -> None:
        # PR22 composerCard is HomeSpec.surface + homeComposerShadow only.
        document = self.tokens()
        composer = document["signatureSurfaces"]["composer"]["tokens"]
        self.assertFalse([token for token in composer if token.startswith("stroke.")])

    def test_tool_row_keeps_the_hairline(self) -> None:
        document = self.tokens()
        self.assertIn("stroke.hairline", document["signatureSurfaces"]["toolRow"]["tokens"])

    def test_thinking_pill_uses_the_process_font(self) -> None:
        # ShimmerText is called with the process/list-item font, never the 13pt
        # default; the sweep is motion.shimmer, the text is typography.process.
        document = self.tokens()
        thinking = document["signatureSurfaces"]["thinkingPill"]["tokens"]
        self.assertIn("typography.process", thinking)
        self.assertIn("motion.shimmer", thinking)
        self.assertNotIn("typography.shimmer", document["typography"]["styles"])

    # -- 5. provenance is dropped for one token -----------------------------

    def test_missing_provenance_fails(self) -> None:
        document = self.tokens()
        del document["provenance"]["colors.success"]
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "provenance is missing")

    # -- 6. a value has the wrong JSON type (exercises the shared validator) -

    def test_schema_type_error_fails(self) -> None:
        document = self.tokens()
        document["colors"]["textPrimary"]["light"] = 111114
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "expected ['string', 'null']")

    def test_schema_rejects_absolute_size_string(self) -> None:
        document = self.tokens()
        document["typography"]["styles"]["body"]["baseSize"] = "16"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "baseSize must be a number 8..72")

    # -- 7. a page exists in the baseline but not in the inventory ----------

    def test_page_missing_from_readme_fails(self) -> None:
        probe = self.root / "examples" / "probe-app" / "PhoneDSHProbe"
        (probe / "NewPage.swift").write_text("struct NewPage: View {}\n", encoding="utf-8")
        self.assert_fails(run_checker(self.root), "page inventory misses: NewPage")

    def test_surface_missing_from_readme_fails(self) -> None:
        readme = self.read_readme().replace("thinking_pill", "思考面板")
        self.write_readme(readme)
        self.assert_fails(run_checker(self.root), "does not document the signature surface")

    def test_deferred_pair_missing_from_readme_fails(self) -> None:
        readme = self.read_readme().replace("textSubtle/page", "textSubtle-page")
        self.write_readme(readme)
        self.assert_fails(run_checker(self.root), "deferred contrast pair")

    def test_page_cross_check_skipped_without_probe_app(self) -> None:
        shutil.rmtree(self.root / "examples")
        result = run_checker(self.root)
        self.assert_passes(result)
        self.assertIn("cross-check skipped", result.stdout)

    # -- 8. the deferred-AA anti-rot rules ----------------------------------

    def test_deferred_pair_that_now_passes_fails(self) -> None:
        document = self.tokens()
        for pair in document["contrast"]["pairs"]:
            if pair["id"] == "textSubtle/page":
                pair["role"] = "large"
                break
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "promote it to required: true")

    def test_geometry_scales_with_unknown_typography_fails(self) -> None:
        document = self.tokens()
        document["geometry"]["contentInset"]["scalesWith"] = "typography.huge"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "geometry.contentInset.scalesWith")

    def test_geometry_without_scales_with_fails(self) -> None:
        document = self.tokens()
        del document["geometry"]["contentInset"]["scalesWith"]
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "scalesWith")

    def test_deferred_pair_without_owner_fails(self) -> None:
        document = self.tokens()
        for pair in document["contrast"]["pairs"]:
            if not pair["required"]:
                pair.pop("owner", None)
                break
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "needs an owner")

    def test_colour_authority_is_home_spec(self) -> None:
        document = self.tokens()
        document["provenance"]["colors.textPrimary"]["source"] = "NativeChatTheme.swift:8"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "must come from HomeSpec.swift")

    def test_component_colour_uses_its_nativeparity_owner(self) -> None:
        document = self.tokens()
        document["provenance"]["colors.sessionPrimary"] = {
            "source": "NativeParityTokens.swift:18",
            "tier": "component",
            "expect": "labelPrimary",
        }
        self.write_tokens(document)
        self.assert_passes(run_checker(self.root))

    def test_component_colour_light_value_is_bound_to_source(self) -> None:
        document = self.tokens()
        document["colors"]["sessionPrimary"]["light"] = "#FF00FF"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "light value '#FF00FF' does not match source '#1A1A1A'")

    def test_component_colour_dark_value_is_bound_to_source(self) -> None:
        document = self.tokens()
        document["colors"]["sessionPrimary"]["dark"] = "#FF00FF"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "dark value '#FF00FF' does not match source '#F9FAFB'")

    def test_component_colour_alpha_is_bound_to_source(self) -> None:
        document = self.tokens()
        document["colors"]["sessionBorderL2"]["lightAlpha"] = 0.2
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "light alpha does not match source")

    def test_component_colour_rejects_non_owner_file(self) -> None:
        document = self.tokens()
        document["provenance"]["colors.sessionPrimary"]["source"] = "NativeChatTheme.swift:10"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "component colour owner must be one of")

    def test_component_colour_requires_an_exact_source_anchor(self) -> None:
        document = self.tokens()
        document["provenance"]["colors.sessionPrimary"].pop("expect", None)
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "need an exact source-line expect anchor")

    def test_sdk_task_screen_color_uses_repo_relative_owner(self) -> None:
        document = self.tokens()
        document["colors"]["taskScreen"] = {"light": "#000000", "dark": "#000000", "note": "Task screen."}
        document["provenance"]["colors.taskScreen"] = {
            "source": "Sources/PhoneDSH/Background/TaskScreen.swift:157",
            "tier": "component",
            "expect": "Color.black",
        }
        self.write_tokens(document)
        self.assert_passes(run_checker(self.root))

    def test_home_component_metric_value_is_bound_to_its_source(self) -> None:
        document = self.tokens()
        document["componentMetrics"]["homePrimaryButtonDisabledOpacity"]["value"] = 0.5
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "value does not match source")

    def test_home_component_metric_source_line_is_bound(self) -> None:
        document = self.tokens()
        document["componentMetrics"]["homePrimaryButtonPressedOpacity"]["source"] = "HomeSpec.swift:219"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "lost its expect anchor")

    def test_alias_target_must_be_a_real_token(self) -> None:
        document = self.tokens()
        document["aliases"]["colors"]["primary"] = "colors.noSuchRole"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "targets unknown token")

    def test_component_compatibility_token_must_exist(self) -> None:
        document = self.tokens()
        document["componentCompatibility"]["bubble"]["tokens"].append("geometry.invented")
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "names unknown token")

    def test_stale_provenance_line_fails(self) -> None:
        document = self.tokens()
        document["provenance"]["colors.textPrimary"]["source"] = "HomeSpec.swift:9999"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "stale source")

    def test_provenance_value_must_match_exactly(self) -> None:
        # 17 is a substring of the real 17.5; the anchor must not stay green.
        document = self.tokens()
        document["typography"]["styles"]["navTitle"]["baseSize"] = 17
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "no longer names the token or its value")

    def test_same_value_wrong_geometry_line_fails(self) -> None:
        # HomeSpec.swift:44 is navTitleLine = 22, not geometry.navIcon = 22.
        document = self.tokens()
        document["provenance"]["geometry.navIcon"]["source"] = "HomeSpec.swift:44"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "no longer names the token or its value")

    def test_same_value_wrong_spacing_line_fails(self) -> None:
        # HomeSpec.swift:20 is navTop = 8, not spacing.disclosureGap = 8.
        document = self.tokens()
        document["provenance"]["spacing.disclosureGap"]["source"] = "HomeSpec.swift:20"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "no longer names the token or its value")

    def test_stale_provenance_line_content_fails(self) -> None:
        document = self.tokens()
        document["provenance"]["colors.textPrimary"]["source"] = "HomeSpec.swift:1"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "no longer names the token or its value")

    def test_page_layer_expect_snippet_fails_on_wrong_line(self) -> None:
        document = self.tokens()
        document["provenance"]["geometry.bubblePaddingH"]["source"] = "ChatPage.swift:3902"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "expected '.padding(.horizontal, 16)'")

    def test_typography_line_height_is_required(self) -> None:
        document = self.tokens()
        del document["typography"]["styles"]["body"]["lineHeight"]
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "lineHeight")

    def test_font_scale_mapping_missing_fails(self) -> None:
        readme = self.read_readme()
        stripped = re.sub(r', "mapping": \{"typography\.navTitle"[^}]*\}', "", readme)
        self.assertNotEqual(stripped, readme)
        self.write_readme(stripped)
        self.assert_fails(run_checker(self.root), "type-role mapping")

    def test_strict_mode_fails_the_deferred_pairs(self) -> None:
        result = run_checker(self.root, strict=True)
        self.assert_fails(result, "DEFER")
        self.assertIn("--strict", result.stdout)

    # -- 9. documentation shape and forbidden content -----------------------

    def test_readme_line_cap_fails(self) -> None:
        # Read the cap instead of hard-coding it: raising README_MAX_LINES for
        # new normative text must not turn this test into a false failure.
        cap = load_checker().README_MAX_LINES
        self.write_readme(self.read_readme() + ("filler line\n" * (cap + 1)))
        self.assert_fails(run_checker(self.root), f"cap is {cap}")

    def test_external_url_in_readme_fails(self) -> None:
        # Append in place, not as a new paragraph: this test is about the URL
        # rule, so it must not trip the README line cap as a side effect.
        self.write_readme(self.read_readme().rstrip("\n") + f" {FORBIDDEN_URL}\n")
        self.assert_fails(run_checker(self.root), "external URL")

    # -- 10. README section 4 composition must equal tokens.json ------------

    def rewrite_surface_row(self, label: str, mutate) -> None:
        # Section 2 has a component table with the same display labels, so the
        # row has to be found inside the section 4 table, not anywhere in README.
        lines = self.read_readme().splitlines()
        header = next(
            (index for index, line in enumerate(lines) if line.strip().startswith("| 签名面 |")),
            None,
        )
        self.assertIsNotNone(header, msg="README has no section 4 table header")
        for index in range(header + 1, len(lines)):
            line = lines[index]
            if not line.lstrip().startswith("|"):
                break
            if line.startswith("| " + label + " |"):
                mutated = mutate(line)
                self.assertNotEqual(mutated, line, msg=f"the mutation changed no cell of {label!r}")
                lines[index] = mutated
                self.write_readme("\n".join(lines) + "\n")
                return
        self.fail(f"README section 4 has no row {label!r}")

    def test_surface_row_missing_a_declared_token_fails(self) -> None:
        # `approvalCard` really uses colors.primary (ApprovalCard.kt:125); the
        # table dropping it is exactly the drift this rule exists for.
        self.rewrite_surface_row("审批卡", lambda row: row.replace("`colors.sessionPrimary` ", "", 1))
        self.assert_fails(
            run_checker(self.root),
            "surface 'approvalCard' omits token 'colors.sessionPrimary' declared by tokens.json",
        )

    def test_surface_row_with_an_undeclared_token_fails(self) -> None:
        self.rewrite_surface_row(
            "composer",
            lambda row: row.replace("`colors.surface`", "`colors.surface` `colors.invented`", 1),
        )
        self.assert_fails(
            run_checker(self.root),
            "surface 'composer' lists token 'colors.invented' not declared by tokens.json",
        )

    def test_surface_table_header_without_a_family_column_fails(self) -> None:
        # The root cause of the 2026-10-31 drift: the table had no spacing
        # column, so `spacing.iconText` could not be documented anywhere.
        readme = self.read_readme()
        header = next(line for line in readme.splitlines() if line.startswith("| 签名面 |"))
        self.write_readme(readme.replace(header, header.replace("间距", "").replace("`spacing.*`", "")))
        self.assert_fails(
            run_checker(self.root),
            "the section 4 header has no column for token family 'spacing'",
        )

    def projection(self) -> tuple:
        path = self.ui / "golden" / "surface-projection.golden.json"
        return path, json.loads(path.read_text(encoding="utf-8"))

    def write_projection(self, path: Path, document: dict) -> None:
        path.write_text(
            json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )

    def test_projection_row_token_outside_the_surface_fails(self) -> None:
        # `p1` used to name `colors.accent` and `spacing.cardInset` while the card
        # renders `colors.ctaOverride` (ApprovalCard.kt:138) and
        # `geometry.cardPadding` (:113).  A row is a subset of the composition,
        # never one token the surface does not declare.
        path, document = self.projection()
        row = next(entry for entry in document["rows"] if entry["row"] == "p1")
        row["tokens"] = ["colors.surface", "colors.success", "colors.primaryButtonInk", "radius.listCard"]
        self.write_projection(path, document)
        self.assert_fails(
            run_checker(self.root),
            "projection row 'p1' (surface 'approvalCard') names token 'colors.success'",
        )

    def test_partial_projection_row_is_legal(self) -> None:
        # One row renders part of a surface; only tokens outside the composition fail.
        path, document = self.projection()
        row = next(entry for entry in document["rows"] if entry["row"] == "p1")
        row["tokens"] = ["radius.card"]
        self.write_projection(path, document)
        self.assert_passes(run_checker(self.root))

    # -- 12. drawer interaction tokens and the shared gesture golden ------

    def test_drawer_scrim_opacity_value_drift_fails(self) -> None:
        document = self.tokens()
        document["interaction"]["drawer"]["scrimMaxOpacity"]["value"] = 0.30
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "interaction.drawer.scrimMaxOpacity")

    def test_drawer_token_reference_must_exist(self) -> None:
        document = self.tokens()
        document["interaction"]["drawer"]["width"]["token"] = "geometry.drawerWidht"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "references unknown token 'geometry.drawerWidht'")

    def test_drawer_stale_expect_fails(self) -> None:
        document = self.tokens()
        document["interaction"]["drawer"]["scrimMaxOpacity"]["expect"] = (
            ".opacity(0.30 * drawerProgress)"
        )
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "stale source 'NativeShell.swift:144'")

    def test_drawer_golden_flipped_release_result_fails(self) -> None:
        path, document = self.drawer_golden()
        case = next(entry for entry in document["release"] if entry["id"] == "release-t-170-v0")
        case["result"] = "settle"
        self.write_drawer_golden(path, document)
        self.assert_fails(run_checker(self.root), "drawer golden release case 'release-t-170-v0'")

    def test_drawer_value_literal_must_occur_in_expect(self) -> None:
        document = self.tokens()
        document["interaction"]["drawer"]["closeThreshold"]["valueLiteral"] = "drawerWidth / 3"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "valueLiteral 'drawerWidth / 3' does not occur")

    def test_real_files_with_drawer_interaction_pass(self) -> None:
        result = run_checker(ROOT)
        self.assert_passes(result)
        self.assertIn("drawer-gesture.golden.json", result.stdout)
        self.assertIn("22 cases recomputed", result.stdout)

    # -- 12. the P09 batch groups ----------------------------------------

    def golden(self, name: str) -> tuple:
        path = self.ui / "golden" / name
        return path, json.loads(path.read_text(encoding="utf-8"))

    def test_sheet_page_detent_unknown_set_fails(self) -> None:
        document = self.tokens()
        document["interaction"]["sheet"]["pageDetents"][0]["detents"] = "huge"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "references unknown detent set 'huge'")

    def test_sheet_stale_detent_source_fails(self) -> None:
        document = self.tokens()
        document["interaction"]["sheet"]["pageDetents"][0]["expect"] = ".presentationDetents([.medium])"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "interaction.sheet.pageDetents[previewShare]")

    def test_sheet_grabber_value_must_be_anchored(self) -> None:
        document = self.tokens()
        document["interaction"]["sheet"]["grabberVisible"]["value"] = "hidden"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "interaction.sheet.grabberVisible")

    def test_sheet_detent_site_count_must_match_probe_app(self) -> None:
        page = self.root / "examples" / "probe-app" / "PhoneDSHProbe" / "NativeWorkbenchPage.swift"
        page.write_text(
            page.read_text(encoding="utf-8")
            + "\nstruct ProbeSheet: View { var body: some View { Color.clear.presentationDetents([.medium]) } }\n",
            encoding="utf-8",
        )
        self.assert_fails(run_checker(self.root), "14 .presentationDetents site(s)")

    def test_sheet_interactive_dismiss_disabled_fails(self) -> None:
        page = self.root / "examples" / "probe-app" / "PhoneDSHProbe" / "NativeWorkbenchPage.swift"
        page.write_text(
            page.read_text(encoding="utf-8")
            + "\nstruct ProbeSheetDismiss: View { var body: some View { Color.clear.interactiveDismissDisabled() } }\n",
            encoding="utf-8",
        )
        self.assert_fails(run_checker(self.root), "interactive dismissal")

    def test_sheet_golden_page_detent_drift_fails(self) -> None:
        path, document = self.golden("sheet-detents.golden.json")
        page = next(entry for entry in document["pages"] if entry["id"] == "previewShare")
        page["detents"] = "medium"
        self.write_drawer_golden(path, document)
        self.assert_fails(run_checker(self.root), "sheet-detents.golden.json pages")

    def test_context_menu_item_label_drift_fails(self) -> None:
        path, document = self.golden("context-menu-items.golden.json")
        document["surfaces"][0]["items"][0]["label"] = "新建会话"
        self.write_drawer_golden(path, document)
        self.assert_fails(run_checker(self.root), "context-menu-items.golden.json surfaces")

    def test_context_menu_surface_count_must_match_probe_app(self) -> None:
        chat = self.root / "examples" / "probe-app" / "PhoneDSHProbe" / "ChatPage.swift"
        chat.write_text(
            chat.read_text(encoding="utf-8")
            + '\nstruct ExtraMenu: View { var body: some View { EmptyView().contextMenu { Button("x") {} } } }\n',
            encoding="utf-8",
        )
        self.assert_fails(run_checker(self.root), "12 .contextMenu site(s) in the probe app but 11")

    def test_context_menu_custom_preview_fails(self) -> None:
        chat = self.root / "examples" / "probe-app" / "PhoneDSHProbe" / "ChatPage.swift"
        chat.write_text(
            chat.read_text(encoding="utf-8")
            + '\nstruct PreviewMenu: View { var body: some View { EmptyView().contextMenu(menuItems: { EmptyView() }) } }\n',
            encoding="utf-8",
        )
        self.assert_fails(run_checker(self.root), "custom context-menu")

    def test_push_back_order_drift_fails(self) -> None:
        document = self.tokens()
        document["interaction"]["push"]["backOrder"]["value"] = "drawer,sheet,stack,root"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "interaction.push.backOrder")

    def test_push_bar_visibility_value_drift_fails(self) -> None:
        document = self.tokens()
        document["interaction"]["push"]["barHiddenWhenPushed"]["value"] = False
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "push-back golden case 'push-root'")

    def test_push_golden_root_back_drift_fails(self) -> None:
        path, document = self.golden("push-back.golden.json")
        case = next(entry for entry in document["cases"] if entry["id"] == "back-root")
        case["exited"] = False
        self.write_drawer_golden(path, document)
        self.assert_fails(run_checker(self.root), "push-back golden case 'back-root'")

    def test_push_custom_navigation_transition_fails(self) -> None:
        shell = self.root / "examples" / "probe-app" / "PhoneDSHProbe" / "NativeShell.swift"
        shell.write_text(
            shell.read_text(encoding="utf-8") + "\n// .navigationTransition(.zoom) probe\n",
            encoding="utf-8",
        )
        self.assert_fails(run_checker(self.root), "custom navigation transition")

    def test_composer_send_golden_can_submit_drift_fails(self) -> None:
        path, document = self.golden("composer-send.golden.json")
        case = next(entry for entry in document["cases"] if entry["id"] == "enabled-idle-empty")
        case["canSubmit"] = True
        self.write_drawer_golden(path, document)
        self.assert_fails(run_checker(self.root), "composer-send golden case 'enabled-idle-empty'")

    def test_composer_send_scale_value_must_be_anchored(self) -> None:
        document = self.tokens()
        document["interaction"]["composerSend"]["transitionScale"]["value"] = 0.9
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "interaction.composerSend.transitionScale")

    def test_pressed_opacity_value_must_be_anchored(self) -> None:
        document = self.tokens()
        document["interaction"]["pressed"]["pillOverlay"]["value"] = 0.08
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "interaction.pressed.pillOverlay")

    def test_pressed_scale_must_be_one(self) -> None:
        document = self.tokens()
        document["interaction"]["pressed"]["scale"]["value"] = 0.98
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "interaction.pressed.scale must be 1")

    def test_pressed_golden_opacity_drift_fails(self) -> None:
        path, document = self.golden("pressed-states.golden.json")
        case = next(entry for entry in document["rows"] if entry["id"] == "drawerRow")
        case["pressed"] = 0.5
        self.write_drawer_golden(path, document)
        self.assert_fails(run_checker(self.root), "pressed-states golden row 'drawerRow'")

    def test_disclosure_motion_golden_drift_fails(self) -> None:
        document = self.tokens()
        document["motion"]["disclosure"]["durationMs"] = 180
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "disclosure-motion.golden.json rows")

    def test_disclosure_chevron_token_must_resolve(self) -> None:
        document = self.tokens()
        document["interaction"]["disclosure"]["chevronMotion"]["token"] = "motion.chevrons"
        self.write_tokens(document)
        self.assert_fails(
            run_checker(self.root),
            "interaction.disclosure.chevronMotion references unknown token 'motion.chevrons'",
        )

    def test_interaction_unknown_group_fails(self) -> None:
        document = self.tokens()
        document["interaction"]["banner"] = {"motion": {"token": "motion.pressed"}}
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "unexpected member 'banner'")

    def test_interaction_missing_group_fails(self) -> None:
        document = self.tokens()
        del document["interaction"]["pressed"]
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "tokens.json has no interaction.pressed object")

    def test_real_files_with_interaction_batch_pass(self) -> None:
        result = run_checker(ROOT)
        self.assert_passes(result)
        for name in (
            "sheet-detents.golden.json",
            "context-menu-items.golden.json",
            "push-back.golden.json",
            "composer-send.golden.json",
            "pressed-states.golden.json",
            "disclosure-motion.golden.json",
        ):
            self.assertIn(name, result.stdout)

    # -- 11. the WCAG maths itself (no subprocess) -------------------------

    def test_contrast_maths(self) -> None:
        checker = load_checker()
        self.assertAlmostEqual(checker.contrast_ratio("#000000", "#FFFFFF"), 21.0, places=4)
        self.assertAlmostEqual(checker.contrast_ratio("#FFFFFF", "#FFFFFF"), 1.0, places=4)
        # #767676 on white is the canonical WCAG AA boundary (4.54:1).
        self.assertAlmostEqual(checker.contrast_ratio("#767676", "#FFFFFF"), 4.54, places=2)
        self.assertAlmostEqual(
            checker.contrast_ratio("#FFFFFF", "#191919"),
            checker.contrast_ratio("#191919", "#FFFFFF"),
            places=6,
        )


if __name__ == "__main__":
    unittest.main()
