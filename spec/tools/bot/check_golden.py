#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Verify the Bot golden split: upstream exports plus append-only overlays.

Offline mode (used by CI) checks that
  * ``export-manifest.json`` lists exactly the golden JSON files,
  * every file digest matches the manifest,
  * the manifest partitions files into ``upstream`` and ``*.phone.json``,
  * every overlay names its upstream file and only adds/replaces cases, or
    declares ``upstream: []`` for one of the small, explicit phone-only
    vectors (currently ``turn-origin.phone.json``, ``mcp-egress.phone.json``,
    ``authority.phone.json``, ``record-reference.phone.json``,
    ``observation-envelope.phone.json``, ``record-query.phone.json``,
    ``erasure-event.phone.json``, ``verification.phone.json``,
    ``store.phone.json``, ``user-action-transaction.phone.json``,
    ``session-lifecycle.phone.json``, ``projection.phone.json``,
    ``mcp-rpc-cases.phone.json``, ``identity-approval-cases.phone.json``,
    ``tool-call-cases.phone.json``, ``team-cases.phone.json``,
    ``task-cases.phone.json``, ``tool-catalog-tiers.phone.json``,
    ``volatile-context-time.phone.json`` and
    ``model-purpose-enforcement.phone.json``) that have no dsh-bot counterpart.

With ``--checkout`` it also runs the real exporter into a temporary directory
and requires every upstream golden file to be byte-identical to the export.
That is the only mode that proves "upstream file == original export"; CI does
not have the private dsh-bot checkout, so it must be run by a developer or a
release gate that does.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:  # Run as a script (the CI/README form).
    from golden_overlay import (  # noqa: E402
        METADATA_KEYS,
        assert_append_only,
        load_json,
        merged_fixture,
        overlay_name,
    )
except ImportError:  # `python3 -m spec.tools.bot.check_golden`
    from spec.tools.bot.golden_overlay import (  # noqa: E402
        METADATA_KEYS,
        assert_append_only,
        load_json,
        merged_fixture,
        overlay_name,
    )

PINNED_SHA = "bf4075b0a2e8092b04b726c59a7b085d5a37e6f6"
# A phone-only vector has no upstream dsh-bot export to extend. Keep this list
# explicit: a new standalone golden needs review, not just a suffix.
PHONE_ONLY_VECTORS = frozenset({
    "tool-call-cases.phone.json",
    "identity-approval-cases.phone.json",
    "mcp-rpc-cases.phone.json",
    "team-cases.phone.json",
    "task-cases.phone.json",
    "turn-origin.phone.json", "mcp-egress.phone.json", "authority.phone.json",
    "record-reference.phone.json", "observation-envelope.phone.json", "record-query.phone.json",
    "erasure-event.phone.json",
    "verification.phone.json",
    "tool-catalog-tiers.phone.json",
    "volatile-context-time.phone.json",
    "model-purpose-enforcement.phone.json",
    "store.phone.json",
    "user-action-transaction.phone.json",
    "session-lifecycle.phone.json",
    "projection.phone.json",
})


def fail(message: str) -> None:
    raise AssertionError(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_layout(root: Path) -> dict:
    bot = root / "spec" / "bot" / "v1"
    golden = bot / "golden"
    manifest_path = bot / "export-manifest.json"
    if not manifest_path.is_file():
        fail(f"missing {manifest_path.relative_to(root)}")
    manifest = load_json(manifest_path)
    if manifest.get("schemaVersion") != 1:
        fail("export-manifest.json schemaVersion must be 1")
    source = manifest.get("source", {})
    if source.get("checkout") != PINNED_SHA:
        fail(f"export-manifest source.checkout must be {PINNED_SHA}")
    if manifest.get("generator") != "spec/tools/bot/export-vectors.mjs":
        fail("export-manifest generator must be spec/tools/bot/export-vectors.mjs")

    actual = sorted(path.name for path in golden.glob("*.json") if path.is_file())
    listed = manifest.get("files")
    if not isinstance(listed, list) or sorted(listed) != actual:
        fail("export-manifest files != spec/bot/v1/golden/*.json")
    upstream = manifest.get("upstream")
    overlays = manifest.get("phoneOverlays")
    if not isinstance(upstream, list) or not isinstance(overlays, list):
        fail("export-manifest upstream/phoneOverlays must be arrays")
    if sorted(upstream + overlays) != actual:
        fail("export-manifest upstream + phoneOverlays != files")
    if any(not name.endswith(".phone.json") for name in overlays):
        fail("phoneOverlays may contain only *.phone.json")
    if any(name.endswith(".phone.json") for name in upstream):
        fail("upstream may not contain *.phone.json")

    hashes = manifest.get("sha256")
    if not isinstance(hashes, dict) or sorted(hashes) != actual:
        fail("export-manifest sha256 must cover exactly the golden files")
    for name in actual:
        path = golden / name
        expected = hashes[name]
        if not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None:
            fail(f"sha256[{name}] must be a lowercase sha256")
        if digest(path) != expected:
            fail(f"sha256 mismatch for {name}; re-run export-vectors.mjs")

    for name in upstream:
        if not (golden / name).is_file():
            fail(f"missing upstream golden {name}")

    replaced: list[str] = []
    for name in overlays:
        overlay_path = golden / name
        overlay = load_json(overlay_path)
        declared = overlay.get("upstream")
        if declared is None:
            declared_names = [name[:-len(".phone.json")] + ".json"]
        elif isinstance(declared, str):
            declared_names = [declared]
        elif isinstance(declared, dict):
            declared_names = list(declared.values())
        elif isinstance(declared, list) and all(isinstance(item, str) for item in declared):
            declared_names = declared
        else:
            fail(f"{name}: upstream must be a string, an object, an array or absent")
        if overlay.get("vector") != name[:-5]:
            fail(f"{name}: vector must be {name[:-5]!r}")
        if overlay.get("source", {}).get("checkout") != source["checkout"]:
            fail(f"{name}: source.checkout must match the export manifest")
        base_name = name[:-len(".phone.json")] + ".json"
        if declared_names == []:
            if name not in PHONE_ONLY_VECTORS:
                fail(f"{name}: phone-only vectors must be registered in PHONE_ONLY_VECTORS")
            if base_name in upstream:
                fail(f"{name}: phone-only vector shadows upstream {base_name}")
            if not isinstance(overlay.get("delta"), list) or not overlay["delta"]:
                fail(f"{name}: phone-only vector needs a non-empty delta")
            if not overlay.get("valid") and not overlay.get("invalid"):
                fail(f"{name}: phone-only vector needs valid or invalid cases")
            continue
        if not all(isinstance(item, str) and item in upstream for item in declared_names):
            fail(f"{name}: upstream must name listed upstream golden files")
        if base_name not in upstream:
            fail(f"{name}: no upstream {base_name}")
        upstream_fixture = load_json(golden / base_name)
        replaced.extend(assert_append_only(upstream_fixture, overlay, name))
        merged = merged_fixture(upstream_fixture, overlay)
        if not merged:
            fail(f"{name}: merged fixture is empty")
    return {"manifest": manifest, "actual": actual, "replaced": replaced, "upstream": upstream}


def check_export(root: Path, checkout: Path, sha: str) -> None:
    node = shutil.which("node")
    if node is None:
        fail("--checkout needs node on PATH to run export-vectors.mjs")
    exporter = root / "spec" / "tools" / "bot" / "export-vectors.mjs"
    if not exporter.is_file():
        fail(f"missing {exporter.relative_to(root)}")
    with tempfile.TemporaryDirectory(prefix="phonedsh-bot-golden-") as temporary:
        command = [node, str(exporter), "--checkout", str(checkout), "--sha", sha, "--out", temporary]
        result = subprocess.run(command, cwd=root, text=True, capture_output=True)
        if result.returncode != 0:
            sys.stderr.write(result.stdout)
            sys.stderr.write(result.stderr)
            fail("export-vectors.mjs failed")
        exported = Path(temporary) / "golden"
        manifest = load_json(Path(temporary) / "export-manifest.json")
        exported_names = sorted(manifest["upstream"])
        repository = root / "spec" / "bot" / "v1" / "golden"
        for name in exported_names:
            expected = exported / name
            actual = repository / name
            if not actual.is_file():
                fail(f"missing upstream golden {name}")
            if expected.read_bytes() != actual.read_bytes():
                fail(f"{name} differs from a fresh export; move phone cases to {overlay_name(name)}")
        repo_manifest = load_json(root / "spec" / "bot" / "v1" / "export-manifest.json")
        if exported_names != repo_manifest["upstream"]:
            fail("export-manifest upstream list differs from a fresh export")
        for name in exported_names:
            if digest(exported / name) != repo_manifest["sha256"][name]:
                fail(f"{name}: manifest digest differs from a fresh export")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--checkout", type=Path, help="read-only dsh-bot checkout")
    parser.add_argument("--sha", default=PINNED_SHA, help="expected dsh-bot SHA")
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    layout = check_layout(root)
    print(f"bot golden: PASS ({len(layout['actual'])} files, "
          f"{len(layout['upstream'])} upstream, {len(layout['actual']) - len(layout['upstream'])} overlays)")
    if layout["replaced"]:
        print("bot golden: overlay overrides: " + ", ".join(layout["replaced"]))
    if arguments.checkout is not None:
        check_export(root, arguments.checkout.resolve(), arguments.sha)
        print(f"bot golden: PASS (fresh export {arguments.sha} is byte-identical)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - the gate must print one actionable line
        print(f"bot golden: FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
