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
        probe = self.root / "examples" / "probe-app" / "PhoneDSHProbe"
        probe.mkdir(parents=True)
        (probe / "ChatPage.swift").write_text("struct ChatPage: View {}\n", encoding="utf-8")
        (probe / "MemoryPage.swift").write_text("struct MemoryPage: View {}\n", encoding="utf-8")

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
        document["contrast"]["pairs"][0]["foreground"] = "tertiary"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "contrast onInput/input")

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

    # -- 5. provenance is dropped for one token -----------------------------

    def test_missing_provenance_fails(self) -> None:
        document = self.tokens()
        del document["provenance"]["colors.warning"]
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "provenance is missing")

    # -- 6. a value has the wrong JSON type (exercises the shared validator) -

    def test_schema_type_error_fails(self) -> None:
        document = self.tokens()
        document["colors"]["primary"]["light"] = 111114
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "expected ['string', 'null']")

    def test_schema_rejects_absolute_size_string(self) -> None:
        document = self.tokens()
        document["typography"]["styles"]["body"]["baseSize"] = "14"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "baseSize must be an integer")

    # -- 7. a page exists in the baseline but not in the inventory ----------

    def test_page_missing_from_readme_fails(self) -> None:
        probe = self.root / "examples" / "probe-app" / "PhoneDSHProbe"
        (probe / "NewPage.swift").write_text("struct NewPage: View {}\n", encoding="utf-8")
        self.assert_fails(run_checker(self.root), "page inventory misses: NewPage")

    def test_surface_missing_from_readme_fails(self) -> None:
        readme = self.read_readme().replace("thinking_pill", "思考行")
        self.write_readme(readme)
        self.assert_fails(run_checker(self.root), "does not document the signature surface")

    def test_deferred_pair_missing_from_readme_fails(self) -> None:
        readme = self.read_readme().replace("caption/code", "caption-code")
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
        document["colors"]["caption"]["light"] = "#000000"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "promote it to required: true")

    def test_geometry_scales_with_unknown_typography_fails(self) -> None:
        document = self.tokens()
        document["geometry"]["bubblePadding"]["scalesWith"] = "typography.huge"
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "geometry.bubblePadding.scalesWith")

    def test_geometry_without_scales_with_fails(self) -> None:
        document = self.tokens()
        del document["geometry"]["bubblePadding"]["scalesWith"]
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

    def test_page_tier_colour_without_baseline_flag_fails(self) -> None:
        document = self.tokens()
        document["colors"]["ctaOverride"]["baselineInconsistency"] = False
        self.write_tokens(document)
        self.assert_fails(run_checker(self.root), "baselineInconsistency")

    def test_font_scale_mapping_missing_fails(self) -> None:
        readme = self.read_readme()
        stripped = re.sub(r', "mapping": \{"typography\.headline"[^}]*\}', "", readme)
        self.assertNotEqual(stripped, readme)
        self.write_readme(stripped)
        self.assert_fails(run_checker(self.root), "type-role mapping")

    def test_strict_mode_fails_the_deferred_pairs(self) -> None:
        result = run_checker(self.root, strict=True)
        self.assert_fails(result, "DEFER")
        self.assertIn("--strict", result.stdout)

    # -- 9. documentation shape and forbidden content -----------------------

    def test_readme_line_cap_fails(self) -> None:
        self.write_readme(self.read_readme() + ("filler line\n" * 130))
        self.assert_fails(run_checker(self.root), "cap is 280")

    def test_external_url_in_readme_fails(self) -> None:
        # Append in place, not as a new paragraph: this test is about the URL
        # rule, so it must not trip the README line cap (280) as a side effect.
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
        self.rewrite_surface_row("审批卡", lambda row: row.replace("`colors.primary` ", "", 1))
        self.assert_fails(
            run_checker(self.root),
            "surface 'approvalCard' omits token 'colors.primary' declared by tokens.json",
        )

    def test_surface_row_with_an_undeclared_token_fails(self) -> None:
        self.rewrite_surface_row(
            "composer",
            lambda row: row.replace("`colors.input`", "`colors.input` `colors.invented`", 1),
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
        row["tokens"] = ["colors.selector", "colors.accent", "colors.onAccent", "radius.card"]
        self.write_projection(path, document)
        self.assert_fails(
            run_checker(self.root),
            "projection row 'p1' (surface 'approvalCard') names token 'colors.accent'",
        )

    def test_partial_projection_row_is_legal(self) -> None:
        # One row renders part of a surface; only tokens outside the composition fail.
        path, document = self.projection()
        row = next(entry for entry in document["rows"] if entry["row"] == "p1")
        row["tokens"] = ["radius.card"]
        self.write_projection(path, document)
        self.assert_passes(run_checker(self.root))

    # -- 11. the WCAG maths itself (no subprocess) -------------------------

    def test_contrast_maths(self) -> None:
        checker = load_checker()
        self.assertAlmostEqual(checker.contrast_ratio("#000000", "#FFFFFF"), 21.0, places=4)
        self.assertAlmostEqual(checker.contrast_ratio("#FFFFFF", "#FFFFFF"), 1.0, places=4)
        # #767676 on white is the canonical WCAG AA boundary (4.54:1).
        self.assertAlmostEqual(checker.contrast_ratio("#767676", "#FFFFFF"), 4.54, places=2)
        self.assertAlmostEqual(
            checker.contrast_ratio("#FFFFFF", "#3964FE"),
            checker.contrast_ratio("#3964FE", "#FFFFFF"),
            places=6,
        )


if __name__ == "__main__":
    unittest.main()
