#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Regressions for the reproducible G2 batch planner/receipt tool."""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import quote

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))

import scenario_batch as batch  # noqa: E402

FAKE_RUNNER = r'''#!/usr/bin/env python3
import argparse
import io
import json
import os
import sys
import tarfile
from pathlib import Path

def write_json(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")

def make_tar(path, files):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w") as archive:
        for name, value in sorted(files.items()):
            data = value.encode("utf-8")
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))

def write_result(results, scenario_id, status, attempt):
    directory = results / scenario_id
    directory.mkdir(parents=True, exist_ok=True)
    report = {
        "id": scenario_id,
        "status": status,
        "attempt": attempt,
        "assertions": [{"type": "file_exists", "ok": status == "PASS"}],
        "turns": [],
        "perturbations": [],
        "usage": {"model_requests": 1},
        "console_errors": [],
        "host_states": [],
    }
    write_json(directory / "report.json", report)
    (directory / "transcript.jsonl").write_text('{"event":"fake"}\n', encoding="utf-8")
    write_json(directory / "scenario.json", {"id": scenario_id})
    if status not in ("SKIP", "INFRA"):
        for relative in ("host/materialized/workspace", "host/wal", "host/response-log"):
            (directory / relative).mkdir(parents=True, exist_ok=True)
        (directory / "host/materialized/workspace/README.md").write_text("payload\n", encoding="utf-8")
        (directory / "host/journal.xljournal").write_text("journal\n", encoding="utf-8")
        write_json(directory / "host/fence.json", {"owner": "fake"})
        make_tar(directory / "workspace.tar", {"README.md": "payload\n"})
        make_tar(directory / "host/overlay-boot.tar", {"vfs": "overlay\n"})
    index_path = results / ".capability-index.json"
    if index_path.is_file():
        index = json.loads(index_path.read_text(encoding="utf-8"))
    else:
        index = {"version": 1, "scenarios": {}}
    index["scenarios"][scenario_id] = {
        "current": {"state": "CURRENT", "attempt": attempt, "status": status}
    }
    write_json(index_path, index)

parser = argparse.ArgumentParser()
parser.add_argument("--catalog")
parser.add_argument("--results", required=True)
parser.add_argument("--only", default="")
parser.add_argument("--run-on")
parser.add_argument("--upstream")
parser.add_argument("--destination")
args, _unknown = parser.parse_known_args()
ids = [item.strip() for item in args.only.split(",") if item.strip()]
invocation_log = os.environ.get("FAKE_INVOCATION_LOG")
if invocation_log:
    with open(invocation_log, "a", encoding="utf-8") as handle:
        for scenario_id in ids:
            handle.write(scenario_id + "\n")
if os.environ.get("FAKE_ECHO_SECRET") == "1":
    secret = os.environ.get("PDSH_MODEL_API_KEY", "")
    if secret:
        # Deliberately unlabelled and not sk-shaped: only the in-process exact
        # value can remove it.  Split across writes so a line/chunk redactor
        # must also survive a pipe-read boundary.
        cut = max(1, len(secret) // 2)
        sys.stdout.write(secret[:cut])
        sys.stdout.flush()
        sys.stdout.write(secret[cut:])
        sys.stdout.flush()
        sys.stdout.write("\n")
        sys.stdout.flush()
generic_sk_secret = os.environ.get("FAKE_GENERIC_SK_SECRET", "")
if generic_sk_secret:
    # Not present in the credential environment: only the generic sk- rule can
    # remove this value, so a chunk cut must not leave its suffix behind.
    cut = max(1, len(generic_sk_secret) // 2)
    sys.stdout.write("generic=" + generic_sk_secret[:cut])
    sys.stdout.flush()
    sys.stdout.write(generic_sk_secret[cut:] + "\n")
    sys.stdout.flush()
authorization_secret = os.environ.get("FAKE_AUTHORIZATION_SECRET", "")
if authorization_secret:
    # Not sk-shaped and not in the credential environment: only the generic
    # Authorization rule can remove it.  Cut inside the scheme (the old rule
    # would replace just "B") and again inside the opaque value, so the next
    # chunk starts with an unlabelled token suffix.
    cut = max(1, len(authorization_secret) // 2)
    sys.stdout.write("Authorization: B")
    sys.stdout.flush()
    sys.stdout.write("asic " + authorization_secret[:cut])
    sys.stdout.flush()
    sys.stdout.write(authorization_secret[cut:] + "\n")
    sys.stdout.flush()
mutate_asset = os.environ.get("FAKE_MUTATE_ASSET")
if mutate_asset:
    # Simulate a stale build cache, fixture, catalog or tracked source file
    # being rewritten inside the child after the batch already fingerprinted
    # the old bytes.
    path = Path(mutate_asset)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        os.environ.get("FAKE_MUTATE_CONTENT", "rebuilt by the fake child\n"),
        encoding="utf-8",
    )
large = int(os.environ.get("FAKE_LARGE_OUTPUT_BYTES", "0") or 0)
if large > 0:
    secret = os.environ.get("PDSH_MODEL_API_KEY", "")
    # One huge line with no newline, key at the very end.
    sys.stdout.write("x" * large + secret + "\n")
    sys.stdout.flush()
if os.environ.get("FAKE_EXIT"):
    raise SystemExit(int(os.environ["FAKE_EXIT"]))
results = Path(args.results)
status_map = json.loads(os.environ.get("FAKE_STATUS_MAP", "{}"))
index_path = results / ".capability-index.json"
for scenario_id in ids:
    attempt = 1
    if index_path.is_file():
        index = json.loads(index_path.read_text(encoding="utf-8"))
        current = index.get("scenarios", {}).get(scenario_id, {}).get("current", {})
        if isinstance(current.get("attempt"), int):
            attempt = current["attempt"] + 1
    write_result(results, scenario_id, status_map.get(scenario_id, "PASS"), attempt)
print("fake scenario runner:", ",".join(ids))
if os.environ.get("FAKE_EXIT_AFTER"):
    raise SystemExit(int(os.environ["FAKE_EXIT_AFTER"]))
'''

FAKE_WRAPPER = """#!/usr/bin/env bash
exec python3 "$(dirname "$0")/fake_runner.py" "$@"
"""


def write_text(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def write_json(path, document):
    return write_text(path, json.dumps(document, indent=2, sort_keys=True) + "\n")


def small_catalog(root, ids, lanes=None, fixtures=None):
    scenarios = []
    for scenario_id in ids:
        workspace = {"files": {}}
        if fixtures:
            workspace["fixture"] = fixtures[0]
        scenarios.append(
            {
                "id": scenario_id,
                "category": "test",
                "title": "test",
                "workspace": workspace,
                "turns": [],
                "assertions": [],
                "budget": {"max_minutes": 10, "max_model_requests": 25},
                "perturbations": [],
                "network": "none",
                "tags": [],
                "target": "both",
            }
        )
    document = {
        "version": 1,
        "scenarios": scenarios,
        "fixtures": [{"name": name, "description": "test"} for name in (fixtures or [])],
    }
    if lanes is not None:
        document["run_plan"] = {
            "lane_plan": [
                {"id": "lane-{}".format(index + 1), "scenario_ids": lane}
                for index, lane in enumerate(lanes)
            ]
        }
    return write_json(Path(root) / "catalog.json", document)


def make_runner_at(directory):
    directory = Path(directory)
    write_text(directory / "fake_runner.py", FAKE_RUNNER)
    wrapper = write_text(directory / "scenarios.sh", FAKE_WRAPPER)
    wrapper.chmod(0o755)
    return wrapper


def make_runner(root):
    # Keep the fake runner at the canonical scripts/ci/scenarios.sh path so
    # fixture provenance follows the same script-location rule as the real
    # runner instead of accidentally falling back to the source checkout.
    return make_runner_at(Path(root) / "scripts" / "ci")


def make_git_repo(root):
    """A tiny checkout so source identity has a real HEAD to receipt."""

    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(
        ["git", "-C", str(root), "config", "user.email", "test@example.invalid"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(root), "config", "user.name", "test"],
        check=True,
    )
    write_text(root / "README.md", "test checkout\n")
    subprocess.run(["git", "-C", str(root), "add", "README.md"], check=True)
    subprocess.run(
        ["git", "-C", str(root), "commit", "-q", "-m", "test checkout"],
        check=True,
    )
    return root


def write_fake_bundle(www):
    www = Path(www)
    write_text(www / "worker-entry.js", "// fake worker entry\n")
    write_text(www / "boot.js", "// fake boot\n")
    write_text(www / "index.html", "<html></html>\n")
    write_text(www / "tool-worker.js", "// fake tool worker\n")
    write_text(www / "tool-worker-python.js", "// fake python worker\n")
    write_text(
        www / "phone-dsh-provenance.json", '{"fake":"bundle provenance"}\n'
    )


def make_assets(root):
    """Fake but content-addressed bundle/image/Python/JQ artifacts."""

    root = Path(root)
    assets = root / "assets"
    www = assets / "www"
    write_fake_bundle(www)
    write_text(assets / "image.tar.gz", "fake image bytes\n")
    write_text(assets / "python" / "python.wasm", "fake python wasm\n")
    write_text(assets / "python" / "python313.zip", "fake python zip\n")
    write_text(assets / "jq" / "jq.wasm", "fake jq wasm\n")
    write_text(assets / "jq" / "engine.json", '{"engine":"fake"}\n')
    write_text(root / "plugins" / "dsh-pin.json", '{"commit":"test-pin"}\n')
    return {
        "PDSH_DSH_WWW": str(www),
        "PDSH_DSH_IMAGE": str(assets / "image.tar.gz"),
        "PDSH_PYTHON_ARTIFACTS": str(assets / "python"),
        "PDSH_JQ_ARTIFACTS": str(assets / "jq"),
    }


def make_build_cache(root):
    """A default build cache (bundle image inside it, no prebuilt env pair)."""

    build = Path(root) / "build-cache"
    www = build / "www"
    write_fake_bundle(www)
    write_text(www / "image.tar.gz", "fake image bytes\n")
    return {"PDSH_SCENARIO_BUILD_DIR": str(build)}


def make_smoke_build_cache(root):
    """A build cache with the exact staged layout ``smoke.sh`` produces.

    ``scenarios.sh`` invokes smoke.sh with ``PDSH_SMOKE_DIR=$BUILD_DIR/smoke``
    and copies ``smoke/www`` to ``$BUILD_DIR/www``; the root-level ``www`` here
    is the resulting default build-cache tree.
    """

    build = Path(root) / "smoke-build-cache"
    smoke = build / "smoke"
    worker = smoke / "worker-entry"
    image = smoke / "image"
    www = smoke / "www"
    # plugins/worker-entry/build.mjs writes two tool workers beside the entry.
    write_text(worker / "worker-entry.js", "// built worker entry\n")
    write_text(worker / "worker-entry.js.map", "// built worker entry map\n")
    write_text(worker / "tool-worker-python.js", "// built python worker\n")
    write_text(worker / "tool-worker-python.js.map", "// built python map\n")
    write_text(worker / "tool-worker.js", "// built generic worker\n")
    write_text(worker / "tool-worker.js.map", "// built generic map\n")
    write_text(worker / "www" / "index.html", "<html></html>\n")
    write_text(worker / "www" / "boot.js", "// built boot\n")
    # plugins/scripts/pack-image.mjs writes the image and optional extras.
    write_text(image / "image.tar.gz", "fake image bytes\n")
    write_text(image / "lazy" / "README.txt", "lazy overlay shards\n")
    for name in ("worker.js", "client.js", "manifest.json", "sizes.json"):
        write_text(image / name, "fake image extra\n")
    # The static bundle smoke.sh stages and verify-bundle.mjs --create seals.
    write_text(www / "worker-entry.js", "// prelude + built worker entry\n")
    write_text(www / "worker-entry.js.map", "// built worker entry map\n")
    write_text(www / "index.html", "<html></html>\n")
    write_text(www / "boot.js", "// built boot\n")
    write_text(www / "tool-worker-python.js", "// built python worker\n")
    write_text(www / "tool-worker-python.js.map", "// built python map\n")
    write_text(www / "tool-worker.js", "// built generic worker\n")
    write_text(www / "tool-worker.js.map", "// built generic map\n")
    write_text(www / "image.tar.gz", "fake image bytes\n")
    write_text(www / "lazy" / "README.txt", "lazy overlay shards\n")
    for name in ("worker.js", "client.js", "manifest.json", "sizes.json"):
        write_text(www / name, "fake image extra\n")
    write_text(
        www / "phone-dsh-provenance.json", '{"fake":"bundle provenance"}\n'
    )
    shutil.copytree(www, build / "www")
    return {"PDSH_SCENARIO_BUILD_DIR": str(build)}


def cli(argv):
    stdout = io.StringIO()
    stderr = io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        code = batch.main(argv)
    return code, stdout.getvalue(), stderr.getvalue()


def invocation_ids(path):
    path = Path(path)
    if not path.is_file():
        return []
    return [line for line in path.read_text(encoding="utf-8").splitlines() if line]


def read_summary(batch_dir):
    return json.loads((Path(batch_dir) / batch.SUMMARY_JSON).read_text(encoding="utf-8"))


class CatalogMetadataTests(unittest.TestCase):
    def test_catalog_inventory_lane_plan_and_budgets_are_current(self):
        path = REPO / "scripts/ci/scenarios/catalog.json"
        document = batch.load_catalog(path)
        batch.validate_run_plan_metadata(document)
        ids = batch.catalog_ids(document)
        self.assertEqual(len(ids), 56)
        self.assertEqual(len(set(ids)), 56)
        parts = {}
        for scenario_id in ids:
            parts[scenario_id[3]] = parts.get(scenario_id[3], 0) + 1
        self.assertEqual(parts, {"A": 10, "B": 10, "C": 10, "D": 6, "E": 10, "F": 10})
        self.assertEqual(len(document.get("fixtures") or []), 10)

        minutes = sum(
            scenario["budget"]["max_minutes"] for scenario in document["scenarios"]
        )
        requests = sum(
            scenario["budget"]["max_model_requests"]
            for scenario in document["scenarios"]
        )
        self.assertEqual(minutes, 835)
        self.assertEqual(requests, 2540)

        run_plan = document["run_plan"]
        self.assertEqual(run_plan["inventory"]["scenarios"], 56)
        self.assertEqual(run_plan["inventory"]["by_part"], parts)
        self.assertEqual(run_plan["inventory"]["fixtures"], 10)
        self.assertEqual(run_plan["budget"]["serial_max_minutes"], 835)
        self.assertEqual(run_plan["budget"]["serial_max_model_requests"], 2540)
        self.assertEqual(run_plan["budget"]["normal_50_max_minutes"], 500)
        self.assertEqual(run_plan["budget"]["normal_50_max_model_requests"], 1220)
        self.assertEqual(run_plan["budget"]["long_run_6_max_minutes"], 335)
        self.assertEqual(run_plan["budget"]["long_run_6_max_model_requests"], 1320)
        self.assertEqual(
            run_plan["time_budget_by_category_minutes"]["总计串行"], 835
        )
        self.assertEqual(
            run_plan["model_request_budget"]["catalog_total"], 2540
        )

        lane_plan = run_plan["lane_plan"]
        self.assertEqual(len(lane_plan), 2)
        lane_ids = [scenario_id for lane in lane_plan for scenario_id in lane["scenario_ids"]]
        self.assertEqual(len(lane_ids), 56)
        self.assertEqual(len(set(lane_ids)), 56)
        self.assertEqual(set(lane_ids), set(ids))
        budgets = {
            lane["id"]: (
                sum(
                    scenario_by_id["budget"]["max_minutes"]
                    for scenario_by_id in document["scenarios"]
                    if scenario_by_id["id"] in lane["scenario_ids"]
                ),
                sum(
                    scenario_by_id["budget"]["max_model_requests"]
                    for scenario_by_id in document["scenarios"]
                    if scenario_by_id["id"] in lane["scenario_ids"]
                ),
            )
            for lane in lane_plan
        }
        self.assertEqual(budgets, {"lane-1": (405, 1235), "lane-2": (430, 1305)})


class FixtureProvenanceTests(unittest.TestCase):
    def test_custom_fixture_root_is_plan_only_and_run_or_resume_refuses_it(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-fixture-root-") as temp:
            root = Path(temp)
            make_git_repo(root)
            catalog = small_catalog(root, ["G2-X"], fixtures=["demo"])
            custom = root / "custom-fixtures"
            write_text(custom / "demo" / "files" / "README.md", "custom payload\n")
            runner = make_runner(root)
            invocations = root / "invocations.txt"
            batch_dir = root / "batch"
            base = [
                "--catalog", str(catalog),
                "--repo-root", str(root),
                "--batch-dir", str(batch_dir),
                "--scenarios-script", str(runner),
                "--upstream", "mock",
                "--fixtures-root", str(custom),
            ]
            with mock.patch.dict(
                os.environ, {"FAKE_INVOCATION_LOG": str(invocations)}, clear=False
            ):
                code, out, err = cli(["plan"] + base)
                self.assertEqual(code, 0, out + err)
                plan = json.loads(out)
                self.assertEqual(plan["fixture_provenance"]["source"], "plan-only")
                self.assertFalse(plan["fixture_provenance"]["runner_consumes"])
                self.assertFalse(plan["execution_ready"])
                self.assertIn("PLAN ONLY", err)
                self.assertEqual(invocation_ids(invocations), [])

                for command in ("run", "resume"):
                    code, out, err = cli([command] + base)
                    self.assertEqual(code, 2, out + err)
                    self.assertIn("plan-only", err)
                    self.assertIn("scenarios.sh", err)
                    self.assertEqual(invocation_ids(invocations), [])
                self.assertFalse((batch_dir / batch.BATCH_MANIFEST).exists())

    def test_default_fixture_root_follows_the_scenarios_script(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-fixture-default-") as temp:
            root = Path(temp)
            make_git_repo(root)
            catalog = small_catalog(root, ["G2-X"])
            runner = make_runner(root)
            assets = make_assets(root)
            plan = batch.build_plan(
                catalog,
                root,
                root / "batch",
                env=assets,
                scenarios_script=runner,
            )
            self.assertEqual(plan["fixture_provenance"]["source"], "runner-default")
            self.assertTrue(plan["fixture_provenance"]["runner_consumes"])
            self.assertTrue(plan["execution_ready"])
            self.assertEqual(
                plan["identity"]["catalog"]["fixture_root"],
                str(batch.runner_fixtures_root(runner)),
            )
            self.assertEqual(
                plan["identity"]["catalog"]["fixture_root"],
                str((root / "scripts" / "ci" / "scenarios" / "fixtures").resolve()),
            )
            self.assertNotEqual(
                plan["identity"]["catalog"]["fixture_root"],
                str(batch.default_fixtures_root(REPO)),
            )

    def test_runner_source_repo_differing_from_repo_root_is_plan_only(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-fixture-repo-") as temp:
            root = Path(temp)
            script_repo = root / "script-repo"
            make_git_repo(script_repo)
            runner = make_runner(script_repo)
            fixture_name = "cart-bugs"
            script_fixture = (
                script_repo / "scripts" / "ci" / "scenarios" / "fixtures"
                / fixture_name
            )
            write_text(script_fixture / "files" / "README.md", "script payload\n")
            catalog = small_catalog(script_repo, ["G2-X"], fixtures=[fixture_name])
            invocations = root / "invocations.txt"
            batch_dir = root / "batch"
            base = [
                "--catalog", str(catalog),
                "--repo-root", str(REPO),
                "--batch-dir", str(batch_dir),
                "--scenarios-script", str(runner),
                "--upstream", "mock",
            ]
            with mock.patch.dict(
                os.environ, {"FAKE_INVOCATION_LOG": str(invocations)}, clear=False
            ):
                code, out, err = cli(["plan"] + base)
                self.assertEqual(code, 0, out + err)
                plan = json.loads(out)
                self.assertEqual(
                    plan["fixture_provenance"]["source"], "runner-default"
                )
                self.assertFalse(plan["execution_ready"])
                self.assertFalse(plan["engine_provenance"]["same_source_repo"])
                self.assertIn("source repo", plan["execution_blocked_reason"])
                self.assertEqual(
                    plan["identity"]["catalog"]["fixture_root"],
                    str(script_fixture.parent.resolve()),
                )
                self.assertEqual(
                    plan["identity"]["catalog"]["fixtures_sha256"][fixture_name],
                    batch.hash_tree(script_fixture),
                )
                self.assertNotEqual(
                    plan["identity"]["catalog"]["fixtures_sha256"][fixture_name],
                    batch.hash_tree(
                        batch.default_fixtures_root(REPO) / fixture_name
                    ),
                )
                self.assertEqual(invocation_ids(invocations), [])

                for command in ("run", "resume"):
                    code, out, err = cli([command] + base)
                    self.assertEqual(code, 2, out + err)
                    self.assertIn("source repo", err)
                    self.assertIn("plan-only", err)
                    self.assertEqual(invocation_ids(invocations), [])
                self.assertFalse((batch_dir / batch.BATCH_MANIFEST).exists())


    def test_noncanonical_script_fixture_root_matches_child_repository_layout(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-fixture-tools-") as temp:
            root = Path(temp)
            script_repo = root
            make_git_repo(script_repo)
            # A copy of scenarios.sh outside scripts/ci still computes
            # ROOT="$(cd "$HERE/../.." && pwd)" and reads
            # $ROOT/scripts/ci/scenarios/fixtures.  The script directory is
            # two levels below that root, as required by the runner's ../...
            # The old script-dir-relative guess would have hashed the decoy at
            # $ROOT/tools/runner/scenarios/fixtures instead.
            runner = make_runner_at(script_repo / "tools" / "runner")
            fixture_name = "cart-bugs"
            child_fixture = (
                script_repo / "scripts" / "ci" / "scenarios" / "fixtures"
                / fixture_name
            )
            write_text(child_fixture / "files" / "README.md", "child payload\n")
            decoy_fixture = (
                script_repo / "tools" / "runner" / "scenarios" / "fixtures"
                / fixture_name
            )
            write_text(decoy_fixture / "files" / "README.md", "decoy payload\n")
            catalog = small_catalog(root, ["G2-X"], fixtures=[fixture_name])
            invocations = root / "invocations.txt"
            batch_dir = script_repo / "batch"
            assets = make_assets(script_repo)
            base = [
                "--catalog", str(catalog),
                "--repo-root", str(script_repo),
                "--batch-dir", str(batch_dir),
                "--scenarios-script", str(runner),
                "--upstream", "mock",
            ]
            with mock.patch.dict(
                os.environ,
                {"FAKE_INVOCATION_LOG": str(invocations), **assets},
                clear=False,
            ):
                code, out, err = cli(["plan"] + base)
                self.assertEqual(code, 0, out + err)
                plan = json.loads(out)
                self.assertEqual(
                    plan["fixture_provenance"]["source"], "runner-default"
                )
                self.assertTrue(plan["execution_ready"])
                self.assertEqual(
                    plan["identity"]["catalog"]["fixture_root"],
                    str(child_fixture.parent.resolve()),
                )
                self.assertEqual(
                    plan["identity"]["catalog"]["fixture_root"],
                    str(batch.runner_fixtures_root(runner)),
                )
                self.assertEqual(
                    plan["identity"]["catalog"]["fixtures_sha256"][fixture_name],
                    batch.hash_tree(child_fixture),
                )
                self.assertNotEqual(
                    plan["identity"]["catalog"]["fixtures_sha256"][fixture_name],
                    batch.hash_tree(decoy_fixture),
                )
                self.assertEqual(invocation_ids(invocations), [])

                code, out, err = cli(["run"] + base)
                self.assertEqual(code, 0, out + err)
                self.assertEqual(invocation_ids(invocations), ["G2-X"])
                manifest = batch.load_manifest(batch_dir)
                self.assertEqual(
                    manifest["identity"]["catalog"]["fixture_root"],
                    str(child_fixture.parent.resolve()),
                )
                self.assertEqual(
                    manifest["identity"]["catalog"]["fixtures_sha256"][fixture_name],
                    batch.hash_tree(child_fixture),
                )
                code, out, err = cli(["summary", "--batch-dir", str(batch_dir)])
                self.assertEqual(code, 0, out + err)
                self.assertTrue(read_summary(batch_dir)["ok"])

    def test_noncanonical_script_refuses_fixture_at_wrong_script_dir_path(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-fixture-tools-missing-") as temp:
            root = Path(temp)
            script_repo = root
            make_git_repo(script_repo)
            runner = make_runner_at(script_repo / "tools" / "runner")
            fixture_name = "cart-bugs"
            # Only the old, incorrect script-dir-relative directory exists.
            write_text(
                script_repo / "tools" / "runner" / "scenarios" / "fixtures"
                / fixture_name / "files" / "README.md",
                "wrong payload\n",
            )
            catalog = small_catalog(root, ["G2-X"], fixtures=[fixture_name])
            invocations = root / "invocations.txt"
            batch_dir = script_repo / "batch"
            base = [
                "--catalog", str(catalog),
                "--repo-root", str(script_repo),
                "--batch-dir", str(batch_dir),
                "--scenarios-script", str(runner),
                "--upstream", "mock",
            ]
            with mock.patch.dict(
                os.environ, {"FAKE_INVOCATION_LOG": str(invocations)}, clear=False
            ):
                for command in ("run", "resume"):
                    code, out, err = cli([command] + base)
                    self.assertEqual(code, 2, out + err)
                    self.assertIn("cart-bugs", err)
                    self.assertIn("not a directory", err)
                    self.assertEqual(invocation_ids(invocations), [])
                self.assertFalse((batch_dir / batch.BATCH_MANIFEST).exists())

    def test_run_refuses_missing_fixture_even_if_another_checkout_has_it(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-fixture-missing-") as temp:
            root = Path(temp)
            make_git_repo(root)
            # REPO has cart-bugs, but this checkout does not.  The runner must
            # not fall back to the source checkout's fixture tree.
            runner = make_runner(root)
            catalog = small_catalog(root, ["G2-X"], fixtures=["cart-bugs"])
            invocations = root / "invocations.txt"
            batch_dir = root / "batch"
            base = [
                "--catalog", str(catalog),
                "--repo-root", str(root),
                "--batch-dir", str(batch_dir),
                "--scenarios-script", str(runner),
                "--upstream", "mock",
            ]
            with mock.patch.dict(
                os.environ, {"FAKE_INVOCATION_LOG": str(invocations)}, clear=False
            ):
                for command in ("run", "resume"):
                    code, out, err = cli([command] + base)
                    self.assertEqual(code, 2, out + err)
                    self.assertIn("cart-bugs", err)
                    self.assertIn("not a directory", err)
                    self.assertEqual(invocation_ids(invocations), [])
                self.assertFalse((batch_dir / batch.BATCH_MANIFEST).exists())

    def test_resume_with_custom_fixture_root_refuses_after_default_run(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-fixture-resume-") as temp:
            root = Path(temp)
            make_git_repo(root)
            catalog = small_catalog(root, ["G2-X"])
            runner = make_runner(root)
            assets = make_assets(root)
            invocations = root / "invocations.txt"
            batch_dir = root / "batch"
            base = [
                "--catalog", str(catalog),
                "--repo-root", str(root),
                "--batch-dir", str(batch_dir),
                "--scenarios-script", str(runner),
                "--upstream", "mock",
            ]
            with mock.patch.dict(
                os.environ,
                {"FAKE_INVOCATION_LOG": str(invocations), **assets},
                clear=False,
            ):
                code, out, err = cli(["run"] + base)
                self.assertEqual(code, 0, out + err)
                self.assertEqual(invocation_ids(invocations), ["G2-X"])
                before = invocation_ids(invocations)
                code, out, err = cli(
                    ["resume"] + base + ["--fixtures-root", str(root / "custom")]
                )
                self.assertEqual(code, 2, out + err)
                self.assertIn("plan-only", err)
                self.assertEqual(invocation_ids(invocations), before)


class RedactionStreamTests(unittest.TestCase):
    def assert_sk_token_absent(self, key, output, label):
        # Use only suffixes below the token label so the assertion does not
        # accidentally match unrelated words such as "tail".
        for index in range(3, len(key)):
            self.assertNotIn(
                key[index:], output, "{} leaked suffix at {}".format(label, index)
            )
        self.assertNotIn(key, output, label)
        self.assertIn("<redacted>", output, label)

    def test_sk_key_is_removed_at_every_chunk_cut_without_suffix_leak(self):
        key = "sk-" + "Q7X9Z3M5N8P4R2T6V1W0"
        for env in ({}, {"PDSH_MODEL_API_KEY": key}):
            for cut in range(1, len(key)):
                with mock.patch.dict(os.environ, env, clear=True):
                    output = "".join(
                        batch.redact_chunks(
                            ["lead " + key[:cut], key[cut:] + " tail"]
                        )
                    )
                self.assert_sk_token_absent(
                    key, output, "cut {} env {}".format(cut, bool(env))
                )

    def test_sk_key_straddling_an_emitted_chunk_boundary_is_removed(self):
        key = "sk-" + "Q7X9Z3M5N8P4R2T6V1W0"
        with mock.patch.dict(os.environ, {}, clear=True):
            pieces = list(
                batch.redact_chunks(["p" * 9000 + key[:3], key[3:] + " end"])
            )
        output = "".join(pieces)
        self.assertGreater(len(pieces), 1)
        self.assert_sk_token_absent(key, output, "emitted boundary")
        self.assertIn("end", output)

    def test_overlong_sk_token_is_bounded_and_does_not_leak(self):
        key = "sk-" + "Q7" * 5000
        reads = {"count": 0}

        def chunks():
            for index in range(0, len(key), 1000):
                reads["count"] += 1
                prefix = "lead " if index == 0 else ""
                yield prefix + key[index:index + 1000]

        with mock.patch.dict(os.environ, {}, clear=True):
            pieces = batch.redact_chunks(chunks())
            first = next(pieces)
            reads_at_first_output = reads["count"]
            rest = "".join(pieces)
        output = first + rest
        self.assertLess(reads_at_first_output, len(key) // 1000)
        self.assert_sk_token_absent(key, output, "overlong")
        self.assertIn("lead ", output)
        self.assertLess(len(output), len(key) // 10)

    def test_hyphenated_generic_sk_key_is_removed_at_every_chunk_cut(self):
        key = "sk-proj-" + "Q7X9-Z3M5_N8P4.R2T6V1W0"
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertNotIn(key, batch.redact_text("generic=" + key))
            self.assertIn("<redacted>", batch.redact_text("generic=" + key))
        for cut in range(1, len(key)):
            with mock.patch.dict(os.environ, {}, clear=True):
                output = "".join(
                    batch.redact_chunks(["lead " + key[:cut], key[cut:] + " tail"])
                )
            self.assert_sk_token_absent(
                key, output, "hyphenated cut {}".format(cut)
            )
            self.assertIn(" tail", output)

    def test_overlong_hyphenated_sk_token_is_bounded_and_does_not_leak(self):
        key = "sk-proj-" + "A1b2C3d4-" * 1200
        reads = {"count": 0}

        def chunks():
            for index in range(0, len(key), 1000):
                reads["count"] += 1
                prefix = "lead " if index == 0 else ""
                yield prefix + key[index:index + 1000]

        with mock.patch.dict(os.environ, {}, clear=True):
            pieces = batch.redact_chunks(chunks())
            first = next(pieces)
            reads_at_first_output = reads["count"]
            rest = "".join(pieces)
        output = first + rest
        self.assertLess(reads_at_first_output, len(key) // 1000)
        self.assertNotIn("A1b2C3d4-", output)
        self.assertIn("lead ", output)
        self.assertIn("<redacted>", output)
        self.assertLess(len(output), len(key) // 10)

    def test_punctuation_sk_key_is_removed_at_every_chunk_cut(self):
        # ``/``, ``+``, ``=``, ``,`` and ``;`` are common provider-key bytes
        # but not log delimiters.  A generic (not-in-env) or exact key cut
        # after any of them must not leave its suffix behind.
        keys = [
            "sk-" + "abcdefgh" + separator + "ijklZ9"
            for separator in ("/", "+", "=", ",", ";")
        ]
        for key in keys:
            for env in ({}, {"PDSH_MODEL_API_KEY": key}):
                for cut in range(1, len(key)):
                    with mock.patch.dict(os.environ, env, clear=True):
                        output = "".join(
                            batch.redact_chunks(
                                ["lead " + key[:cut], key[cut:] + " tail"]
                            )
                        )
                    self.assert_sk_token_absent(
                        key,
                        output,
                        "punctuation {!r} cut {} env {}".format(
                            key[11], cut, bool(env)
                        ),
                    )
                    self.assertIn(" tail", output)

    def test_authorization_scheme_and_value_are_held_at_every_chunk_cut(self):
        # The generic Authorization rule consumes the scheme and the value.
        # A cut inside the scheme or just before the value used to let the
        # first chunk's prefix be replaced, leaving the next chunk's token
        # without a label.  Cover Basic/Bearer/Proxy and both a generic and an
        # exact in-process value at every two-chunk cut position.
        token = "SECRETTOKEN123"
        templates = (
            ("basic", "Authorization: Basic " + token + "\n"),
            ("bearer", "Authorization: Bearer " + token + "\n"),
            (
                "proxy",
                "Proxy-Authorization: Basic " + token + "\n",
            ),
        )
        for label, text in templates:
            for env in ({}, {"PDSH_MODEL_API_KEY": token}):
                for cut in range(1, len(text) + 1):
                    with mock.patch.dict(os.environ, env, clear=True):
                        output = "".join(
                            batch.redact_chunks([text[:cut], text[cut:]])
                        )
                    self.assert_sk_token_absent(
                        token,
                        output,
                        "{} cut {} env {}".format(label, cut, bool(env)),
                    )

        # The exact reproduction from the review: the first chunk ends in
        # the scheme and the next chunk starts with the unlabelled value.
        with mock.patch.dict(os.environ, {}, clear=True):
            output = "".join(
                batch.redact_chunks(
                    ["Authorization: B", "asic SECRETTOKEN123\n"]
                )
            )
        self.assertNotIn(token, output)
        self.assertEqual(output, "Authorization: <redacted>\n")

    def test_overlong_authorization_header_is_bounded_and_does_not_leak(self):
        token = "SECRETTOKEN123"
        reads = {"count": 0}

        def chunks():
            reads["count"] += 1
            yield "Authorization: Basic " + "A" * 20000
            reads["count"] += 1
            yield " " + token + "\n"
            reads["count"] += 1
            yield "after\n"

        with mock.patch.dict(os.environ, {}, clear=True):
            pieces = batch.redact_chunks(chunks())
            first = next(pieces)
            reads_at_first_output = reads["count"]
            rest = "".join(pieces)
        output = first + rest
        self.assertLess(reads_at_first_output, 3)
        self.assertNotIn(token, output)
        self.assertIn("<redacted>", output)
        self.assertIn("after", output)

    def test_exact_key_with_space_is_removed_at_every_chunk_cut(self):
        # A generic token stops at whitespace, so this case is only covered by
        # the exact in-process value prefix rule.
        key = "sk-" + "abc def ghiZ9"
        for cut in range(1, len(key)):
            with mock.patch.dict(
                os.environ, {"PDSH_MODEL_API_KEY": key}, clear=True
            ):
                output = "".join(
                    batch.redact_chunks(
                        ["lead " + key[:cut], key[cut:] + " tail"]
                    )
                )
            self.assert_sk_token_absent(key, output, "space cut {}".format(cut))
            self.assertIn(" tail", output)

    def test_opaque_key_is_removed_at_every_chunk_cut(self):
        key = "qp" + "7Rm2" + "xL9" + "t4"
        with mock.patch.dict(os.environ, {}, clear=True):
            # The value does not match any generic credential pattern.
            self.assertEqual(batch.redact_text(key), key)
        for cut in range(1, len(key)):
            with mock.patch.dict(
                os.environ, {"PDSH_MODEL_API_KEY": key}, clear=True
            ):
                output = "".join(
                    batch.redact_chunks(["lead " + key[:cut], key[cut:] + " tail"])
                )
            self.assertNotIn(key, output, "leaked at cut {}".format(cut))
            self.assertIn("<redacted>", output)
            self.assertIn("lead ", output)
            self.assertIn(" tail", output)

    def test_key_straddling_an_emitted_chunk_boundary_is_removed(self):
        key = "qp" + "7Rm2" + "xL9" + "t4"
        with mock.patch.dict(os.environ, {"PDSH_MODEL_API_KEY": key}, clear=True):
            pieces = list(
                batch.redact_chunks(["p" * 9000 + key[:3], key[3:] + "end"])
            )
        output = "".join(pieces)
        self.assertGreater(len(pieces), 1)
        self.assertNotIn(key, output)
        self.assertIn("end", output)

    def test_large_newline_free_stream_emits_before_eof(self):
        state = {"reads": 0}

        def chunks():
            for _ in range(4):
                state["reads"] += 1
                yield "y" * 10000

        with mock.patch.dict(os.environ, {}, clear=True):
            pieces = batch.redact_chunks(chunks())
            first = next(pieces)
            self.assertEqual(state["reads"], 1)
            self.assertGreater(len(first), 0)
            self.assertLess(len(first), 10000)
            rest = "".join(pieces)
        self.assertEqual(len(first) + len(rest), 40000)


class PlanTests(unittest.TestCase):
    def test_plan_is_exact_and_gives_each_lane_independent_directories(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-plan-") as temp:
            root = Path(temp)
            catalog = REPO / "scripts/ci/scenarios/catalog.json"
            batch_dir = root / "batch"
            plan = batch.build_plan(
                catalog,
                REPO,
                batch_dir,
                run_on="macos",
                upstream="mock",
            )
            ids = [scenario["id"] for scenario in batch.load_catalog(catalog)["scenarios"]]
            lane_ids = [item for lane in plan["lanes"] for item in lane["scenario_ids"]]
            self.assertEqual(len(lane_ids), 56)
            self.assertEqual(len(set(lane_ids)), 56)
            self.assertEqual(set(lane_ids), set(ids))
            self.assertEqual(plan["budget"], {"max_minutes": 835, "max_model_requests": 2540})
            for key in ("results_dir", "work_dir", "sim_dir"):
                values = [lane[key] for lane in plan["lanes"]]
                self.assertEqual(len(values), len(set(values)))
            self.assertEqual(plan["lanes"][0]["scenario_ids"][-3:], ["G2-D01", "G2-D04", "G2-D03"])
            phases = batch.lane_phases(plan, plan["lanes"][0]["scenario_ids"])
            self.assertEqual([len(phase) for phase in phases], [25, 2, 1])
            flattened = [item for phase in phases for item in phase]
            self.assertEqual(flattened, plan["lanes"][0]["scenario_ids"])

    def test_duplicate_catalog_ids_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-dup-") as temp:
            root = Path(temp)
            catalog = small_catalog(root, ["G2-X", "G2-X"])
            with self.assertRaises(batch.BatchError):
                batch.load_catalog(catalog)

    def test_lane_metadata_must_cover_every_case_exactly_once(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-lanes-") as temp:
            root = Path(temp)
            catalog = small_catalog(root, ["G2-X", "G2-Y", "G2-Z"], lanes=[["G2-X", "G2-Y"]])
            with self.assertRaises(batch.BatchError):
                batch.build_plan(
                    catalog,
                    REPO,
                    root / "batch",
                    scenarios_script=make_runner(root),
                )
            duplicate = small_catalog(
                root, ["G2-X", "G2-Y", "G2-Z"],
                lanes=[["G2-X", "G2-Y"], ["G2-Y", "G2-Z"]],
            )
            with self.assertRaises(batch.BatchError):
                batch.build_plan(
                    duplicate,
                    REPO,
                    root / "batch2",
                    scenarios_script=make_runner(root),
                )

    def test_declared_inventory_must_match_the_catalog(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-inventory-") as temp:
            root = Path(temp)
            catalog = small_catalog(root, ["G2-X", "G2-Y"])
            document = json.loads(catalog.read_text(encoding="utf-8"))
            document["run_plan"] = {"inventory": {"scenarios": 99}}
            catalog.write_text(json.dumps(document) + "\n", encoding="utf-8")
            with self.assertRaises(batch.BatchError):
                batch.build_plan(
                    catalog,
                    REPO,
                    root / "batch",
                    scenarios_script=make_runner(root),
                )

    def test_fallback_partition_without_metadata_is_balanced_and_exact(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-fallback-") as temp:
            root = Path(temp)
            catalog = small_catalog(root, ["G2-X", "G2-Y", "G2-Z", "G2-W"])
            plan = batch.build_plan(
                catalog,
                REPO,
                root / "batch",
                lanes=2,
                scenarios_script=make_runner(root),
            )
            lane_ids = [item for lane in plan["lanes"] for item in lane["scenario_ids"]]
            self.assertEqual(sorted(lane_ids), ["G2-W", "G2-X", "G2-Y", "G2-Z"])
            self.assertEqual(len(lane_ids), len(set(lane_ids)))

    def test_simulator_lanes_require_distinct_devices(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-batch-sim-") as temp:
            root = Path(temp)
            catalog = small_catalog(root, ["G2-X", "G2-Y", "G2-Z"], lanes=[["G2-X"], ["G2-Y", "G2-Z"]])
            with self.assertRaises(batch.BatchError):
                batch.build_plan(
                    catalog,
                    REPO,
                    root / "batch",
                    run_on="sim",
                    scenarios_script=make_runner(root),
                )
            plan = batch.build_plan(
                catalog,
                REPO,
                root / "batch",
                run_on="sim",
                simulators=["iPhone A", "iPhone B"],
                scenarios_script=make_runner(root),
            )
            self.assertEqual([lane["simulator"] for lane in plan["lanes"]], ["iPhone A", "iPhone B"])
            self.assertEqual(len({lane["sim_dir"] for lane in plan["lanes"]}), 2)


class BatchIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pdsh-batch-run-")
        self.root = Path(self.temp.name)
        make_git_repo(self.root)
        self.catalog = small_catalog(
            self.root,
            ["G2-X", "G2-Y", "G2-Z"],
            lanes=[["G2-X", "G2-Y"], ["G2-Z"]],
        )
        self.runner = make_runner(self.root)
        self.assets = make_assets(self.root)
        self.build_cache = make_build_cache(self.root)
        self.batch_dir = self.root / "batch"
        self.invocations = self.root / "invocations.txt"

    def tearDown(self):
        self.temp.cleanup()

    def default_cache_env(self, extra=None):
        values = {
            **self.build_cache,
            "PDSH_DSH_WWW": None,
            "PDSH_DSH_IMAGE": None,
        }
        values.update(extra or {})
        return values

    def run_cli(self, extra=None, env=None):
        argv = [
            "run",
            "--catalog", str(self.catalog),
            "--repo-root", str(self.root),
            "--batch-dir", str(self.batch_dir),
            "--scenarios-script", str(self.runner),
            "--upstream", "mock",
        ]
        argv += list(extra or [])
        requested = env or {}
        values = {
            "FAKE_INVOCATION_LOG": str(self.invocations),
            **self.assets,
        }
        values.update(
            {name: value for name, value in requested.items() if value is not None}
        )
        with mock.patch.dict(os.environ, values, clear=False):
            for name, value in requested.items():
                if value is None:
                    os.environ.pop(name, None)
            return cli(argv)

    def summary(self, extra=None):
        argv = ["summary", "--batch-dir", str(self.batch_dir)]
        argv += list(extra or [])
        return cli(argv)

    def test_all_pass_run_writes_receipts_and_summary(self):
        code, out, err = self.run_cli()
        self.assertEqual(code, 0, out + err)
        summary = read_summary(self.batch_dir)
        self.assertTrue(summary["ok"])
        self.assertEqual(summary["counts"]["PASS"], 3)
        self.assertEqual(len(invocation_ids(self.invocations)), 3)
        self.assertEqual(sorted(invocation_ids(self.invocations)), ["G2-X", "G2-Y", "G2-Z"])
        for scenario_id in ("G2-X", "G2-Y", "G2-Z"):
            receipt = json.loads(
                (self.batch_dir / summary["scenarios"][scenario_id]["lane"] / "work" / "receipts" / (scenario_id + ".json")).read_text(encoding="utf-8")
            )
            self.assertEqual(receipt["status"], "PASS")
            self.assertTrue(receipt["evidence"])
            self.assertEqual(receipt["source_sha"], summary["source_sha"])
            self.assertEqual(receipt["fixture_root_source"], "runner-default")
            self.assertEqual(receipt["fixtures_sha256"], {})
        manifest = batch.load_manifest(self.batch_dir)
        self.assertEqual(
            manifest["fixture_provenance"]["source"], "runner-default"
        )
        self.assertTrue(manifest["execution_ready"])
        code, out, _err = self.summary()
        self.assertEqual(code, 0, out)
        self.assertTrue(read_summary(self.batch_dir)["ok"])

    def test_explicit_resume_reuses_complete_pass_without_rerun(self):
        self.assertEqual(self.run_cli()[0], 0)
        before = invocation_ids(self.invocations)
        code, out, err = self.run_cli(["--resume"])
        self.assertEqual(code, 0, out + err)
        self.assertEqual(invocation_ids(self.invocations), before)
        self.assertEqual(read_summary(self.batch_dir)["counts"]["PASS"], 3)

    def test_resume_reruns_fail_and_missing_report_instead_of_reusing(self):
        self.assertEqual(self.run_cli()[0], 0)
        report_path = self.batch_dir / "lane-1" / "results" / "G2-X" / "report.json"
        report = json.loads(report_path.read_text(encoding="utf-8"))
        report["status"] = "FAIL"
        report_path.write_text(json.dumps(report) + "\n", encoding="utf-8")
        # A reused PASS is expected to be older than the lane that reruns the
        # FAIL; the stale-report guard must not turn it into NOT_RUN.
        old = 1_600_000_000
        for relative in (
            "lane-1/results/G2-Y/report.json",
            "lane-2/results/G2-Z/report.json",
        ):
            os.utime(self.batch_dir / relative, (old, old))
        before = invocation_ids(self.invocations)
        code, out, err = self.run_cli(["--resume"])
        self.assertEqual(code, 0, out + err)
        after = invocation_ids(self.invocations)
        self.assertEqual(after[len(before):], ["G2-X"])
        self.assertEqual(read_summary(self.batch_dir)["counts"]["PASS"], 3)

        (self.batch_dir / "lane-2" / "results" / "G2-Z" / "report.json").unlink()
        before = invocation_ids(self.invocations)
        code, out, err = self.run_cli(["--resume"])
        self.assertEqual(code, 0, out + err)
        self.assertEqual(invocation_ids(self.invocations)[len(before):], ["G2-Z"])

    def test_summary_blocks_tampered_evidence_and_missing_report(self):
        self.assertEqual(self.run_cli()[0], 0)
        transcript = self.batch_dir / "lane-1" / "results" / "G2-X" / "transcript.jsonl"
        transcript.write_text("tampered\n", encoding="utf-8")
        code, out, _err = self.summary()
        self.assertEqual(code, 1)
        summary = read_summary(self.batch_dir)
        self.assertEqual(summary["scenarios"]["G2-X"]["status"], "BLOCKED")
        self.assertEqual(summary["scenarios"]["G2-Y"]["status"], "PASS")

        (self.batch_dir / "lane-2" / "results" / "G2-Z" / "report.json").unlink()
        code, _out, _err = self.summary()
        self.assertEqual(code, 1)
        summary = read_summary(self.batch_dir)
        self.assertEqual(summary["scenarios"]["G2-Z"]["status"], "NOT_RUN")
        self.assertFalse(summary["ok"])

    def test_summary_rejects_attempt_and_report_id_mismatch(self):
        self.assertEqual(self.run_cli()[0], 0)
        report_path = self.batch_dir / "lane-1" / "results" / "G2-X" / "report.json"
        report = json.loads(report_path.read_text(encoding="utf-8"))
        report["attempt"] = 999
        report_path.write_text(json.dumps(report) + "\n", encoding="utf-8")
        code, out, _err = self.summary()
        self.assertEqual(code, 1)
        summary = read_summary(self.batch_dir)
        self.assertEqual(summary["scenarios"]["G2-X"]["status"], "FAIL")
        self.assertIn("attempt", summary["scenarios"]["G2-X"]["detail"])

        report["attempt"] = 1
        report["id"] = "G2-OTHER"
        report_path.write_text(json.dumps(report) + "\n", encoding="utf-8")
        code, _out, _err = self.summary()
        self.assertEqual(code, 1)
        summary = read_summary(self.batch_dir)
        self.assertEqual(summary["scenarios"]["G2-X"]["status"], "FAIL")
        self.assertIn("does not match", summary["scenarios"]["G2-X"]["detail"])

    def test_summary_rejects_expected_source_and_catalog_mismatch(self):
        self.assertEqual(self.run_cli()[0], 0)
        code, out, _err = self.summary(["--expect-source-sha", "0" * 40])
        self.assertEqual(code, 1)
        summary = read_summary(self.batch_dir)
        self.assertEqual(summary["counts"]["BLOCKED"], 3)
        self.assertFalse(summary["ok"])
        self.assertIn("source SHA", out)

        code, _out, _err = self.summary(["--expect-catalog-sha", "0" * 64])
        self.assertEqual(code, 1)
        self.assertEqual(read_summary(self.batch_dir)["counts"]["BLOCKED"], 3)

    def test_identity_change_disables_resume_and_reruns_everything(self):
        self.assertEqual(self.run_cli()[0], 0)
        document = json.loads(self.catalog.read_text(encoding="utf-8"))
        document["run_plan"]["note"] = "catalog changed"
        self.catalog.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        before = invocation_ids(self.invocations)
        code, out, err = self.run_cli(["--resume"])
        self.assertEqual(code, 0, out + err)
        self.assertEqual(sorted(invocation_ids(self.invocations)[len(before):]), ["G2-X", "G2-Y", "G2-Z"])

    def test_runner_failure_leaves_missing_reports_as_not_run(self):
        code, out, err = self.run_cli(env={"FAKE_EXIT": "7"})
        self.assertEqual(code, 1, out + err)
        summary = read_summary(self.batch_dir)
        self.assertFalse(summary["ok"])
        self.assertEqual(summary["counts"]["PASS"], 0)
        self.assertEqual(summary["counts"]["NOT_RUN"], 3)

    def test_product_failure_in_one_phase_does_not_skip_later_phases(self):
        self.catalog = small_catalog(
            self.root,
            ["G2-X", "G2-Y", "G2-Z"],
            lanes=[["G2-X", "G2-Z", "G2-Y"]],
        )
        code, out, err = self.run_cli(
            env={
                "FAKE_STATUS_MAP": json.dumps({"G2-X": "FAIL"}),
                "FAKE_EXIT_AFTER": "5",
            }
        )
        self.assertEqual(code, 1, out + err)
        summary = read_summary(self.batch_dir)
        self.assertEqual(summary["scenarios"]["G2-X"]["status"], "FAIL")
        self.assertEqual(summary["scenarios"]["G2-Z"]["status"], "PASS")
        self.assertEqual(summary["scenarios"]["G2-Y"]["status"], "PASS")
        self.assertTrue(
            (self.batch_dir / "lane-1" / "results" / "G2-Y" / "report.json").is_file()
        )
        self.assertEqual(sorted(invocation_ids(self.invocations)), ["G2-X", "G2-Y", "G2-Z"])

    def test_skip_infra_and_pending_host_are_explicit_and_never_reused(self):
        code, out, err = self.run_cli(
            env={
                "FAKE_STATUS_MAP": json.dumps(
                    {"G2-X": "SKIP", "G2-Y": "INFRA", "G2-Z": "PENDING_HOST"}
                )
            }
        )
        self.assertEqual(code, 1, out + err)
        summary = read_summary(self.batch_dir)
        self.assertEqual(summary["scenarios"]["G2-X"]["status"], "NOT_RUN")
        self.assertEqual(summary["scenarios"]["G2-Y"]["status"], "BLOCKED")
        self.assertEqual(summary["scenarios"]["G2-Z"]["status"], "PENDING_HOST")
        self.assertFalse(summary["ok"])

        before = invocation_ids(self.invocations)
        code, out, err = self.run_cli(["--resume"])
        self.assertEqual(code, 0, out + err)
        self.assertEqual(sorted(invocation_ids(self.invocations)[len(before):]), ["G2-X", "G2-Y", "G2-Z"])
        self.assertEqual(read_summary(self.batch_dir)["counts"]["PASS"], 3)

    def test_runner_nonzero_fails_even_when_reports_pass(self):
        code, out, err = self.run_cli(env={"FAKE_EXIT_AFTER": "5"})
        self.assertEqual(code, 1, out + err)
        summary = read_summary(self.batch_dir)
        self.assertFalse(summary["ok"])
        self.assertEqual(summary["counts"]["PASS"], 3)
        self.assertTrue(summary["runner_failures"])
        self.assertIn("RUNNER FAILED", out)

    def test_resume_after_runner_failure_reruns_instead_of_reusing_pass_reports(self):
        code, out, err = self.run_cli(env={"FAKE_EXIT_AFTER": "5"})
        self.assertEqual(code, 1, out + err)
        self.assertFalse(read_summary(self.batch_dir)["ok"])
        before = invocation_ids(self.invocations)
        self.assertEqual(len(before), 3)

        code, out, err = self.run_cli(["--resume"])
        self.assertEqual(code, 0, out + err)
        after = invocation_ids(self.invocations)
        self.assertEqual(sorted(after[len(before):]), ["G2-X", "G2-Y", "G2-Z"])
        summary = read_summary(self.batch_dir)
        self.assertTrue(summary["ok"])
        self.assertFalse(summary["runner_failures"])

    def test_summary_requires_a_finished_state_and_blocks_on_deleted_or_broken_state(self):
        self.assertEqual(self.run_cli()[0], 0)
        state_path = self.batch_dir / batch.RUN_STATE
        saved_state = state_path.read_text(encoding="utf-8")
        state_path.unlink()
        code, _out, _err = self.summary()
        self.assertEqual(code, 1)
        summary = read_summary(self.batch_dir)
        self.assertFalse(summary["ok"])
        self.assertEqual(summary["counts"]["BLOCKED"], 3)
        self.assertIn("state", " ".join(summary["issues"]).lower())

        broken = json.loads(saved_state)
        broken["lanes"].pop("lane-1")
        state_path.write_text(json.dumps(broken) + "\n", encoding="utf-8")
        code, _out, _err = self.summary()
        self.assertEqual(code, 1)
        summary = read_summary(self.batch_dir)
        self.assertFalse(summary["ok"])
        self.assertEqual(summary["counts"]["BLOCKED"], 3)

        state_path.write_text("{not valid json\n", encoding="utf-8")
        code, _out, _err = self.summary()
        self.assertEqual(code, 1)
        summary = read_summary(self.batch_dir)
        self.assertFalse(summary["ok"])
        self.assertEqual(summary["counts"]["BLOCKED"], 3)

    def test_resume_with_changed_simulators_reruns_every_lane(self):
        sim_args = ["--run-on", "sim", "--simulators", "iPhone A,iPhone B"]
        code, out, err = self.run_cli(sim_args)
        self.assertEqual(code, 0, out + err)
        before = invocation_ids(self.invocations)
        self.assertEqual(len(before), 3)

        code, out, err = self.run_cli(
            sim_args[:2] + ["--simulators", "iPhone C,iPhone D", "--resume"]
        )
        self.assertEqual(code, 0, out + err)
        after = invocation_ids(self.invocations)
        self.assertEqual(sorted(after[len(before):]), ["G2-X", "G2-Y", "G2-Z"])
        manifest = batch.load_manifest(self.batch_dir)
        self.assertEqual(
            [lane["simulator"] for lane in manifest["lanes"]],
            ["iPhone C", "iPhone D"],
        )
        self.assertTrue(read_summary(self.batch_dir)["ok"])

    def test_lane_thread_exception_is_a_runner_failure_not_a_reuse(self):
        self.assertEqual(self.run_cli()[0], 0)
        transcript = self.batch_dir / "lane-1" / "results" / "G2-X" / "transcript.jsonl"
        transcript.write_text("tampered\n", encoding="utf-8")

        with mock.patch.object(
            batch, "_run_one_lane", side_effect=OSError("simulated lane start failure")
        ):
            code, out, err = self.run_cli(["--resume"])
        self.assertEqual(code, 1, out + err)
        summary = read_summary(self.batch_dir)
        self.assertFalse(summary["ok"])
        self.assertTrue(summary["runner_failures"])
        self.assertIn("lane-1", " ".join(summary["runner_failures"]))
        self.assertEqual(summary["scenarios"]["G2-X"]["status"], "BLOCKED")
        state = json.loads((self.batch_dir / batch.RUN_STATE).read_text(encoding="utf-8"))
        self.assertEqual(state["lanes"]["lane-1"]["status"], "error")
        self.assertNotEqual(state["lanes"]["lane-1"]["returncode"], 0)
        self.assertNotEqual(state["lanes"]["lane-1"]["returncode"], None)

        # The failed attempt must not poison the next explicit resume either.
        code, out, err = self.run_cli(["--resume"])
        self.assertEqual(code, 0, out + err)
        self.assertTrue(read_summary(self.batch_dir)["ok"])

    def test_credentials_are_not_written_or_left_in_logs(self):
        secret = "sk-" + "abcdefgh"
        env = {
            "PDSH_MODEL_BASE_URL": "https://" + "user" + ":" + "pass"
            + "@api.example.invalid/v1?token=" + "hidden",
            "PDSH_MODEL_NAME": "deepseek-flash",
            "PDSH_MODEL_API_KEY": secret,
        }
        identity = batch.build_identity(
            self.root,
            self.catalog,
            "macos",
            "real",
            env={**self.assets, **env},
            scenarios_script=self.runner,
        )
        serialized = json.dumps(identity, sort_keys=True)
        self.assertNotIn(secret, serialized)
        self.assertNotIn("user:pass", serialized)
        self.assertNotIn("token=hidden", serialized)
        self.assertEqual(identity["model"]["base_url"], "https://api.example.invalid")
        self.assertEqual(
            identity["model"]["base_url_sha256"],
            batch.sha256_bytes(b"https://api.example.invalid/v1"),
        )
        self.assertEqual(identity["model"]["credential_context"]["source"], "unknown")

        values = {
            "FAKE_INVOCATION_LOG": str(self.invocations),
            "FAKE_ECHO_SECRET": "1",
            **self.assets,
            **env,
        }
        with mock.patch.dict(os.environ, values, clear=False):
            code, out, err = cli([
                "run",
                "--catalog", str(self.catalog),
                "--repo-root", str(self.root),
                "--batch-dir", str(self.batch_dir),
                "--scenarios-script", str(self.runner),
                "--upstream", "mock",
            ])
        self.assertEqual(code, 0, out + err)
        summary = read_summary(self.batch_dir)
        self.assertNotIn(secret, json.dumps(summary, sort_keys=True))
        for log_path in self.batch_dir.glob("lane-*/work/scenarios.log"):
            text = log_path.read_text(encoding="utf-8")
            self.assertNotIn(secret, text)
        self.assertNotIn(secret, out)
        self.assertIn("<redacted>", out)

    def test_opaque_credential_is_redacted_from_streamed_logs_and_artifacts(self):
        key = "qp" + "7Rm2" + "xL9" + "t4"
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(batch.redact_text(key), key)
        env = {
            "PDSH_MODEL_BASE_URL": "https://api.example.invalid/v1",
            "PDSH_MODEL_NAME": "deepseek-flash",
            "PDSH_MODEL_API_KEY": key,
            "FAKE_ECHO_SECRET": "1",
            "FAKE_LARGE_OUTPUT_BYTES": "200000",
        }
        code, out, err = self.run_cli(env=env)
        self.assertEqual(code, 0, err)
        self.assertNotIn(key, out)
        self.assertIn("<redacted>", out)
        for log_path in self.batch_dir.glob("lane-*/work/scenarios.log"):
            text = log_path.read_text(encoding="utf-8")
            self.assertNotIn(key, text)
            self.assertIn("<redacted>", text)
            self.assertIn("x" * 1000, text)
        for path in self.batch_dir.rglob("report.json"):
            self.assertNotIn(key, path.read_text(encoding="utf-8"))
        for relative in (
            batch.BATCH_MANIFEST,
            batch.RUN_STATE,
            batch.SUMMARY_JSON,
            batch.SUMMARY_MD,
        ):
            path = self.batch_dir / relative
            self.assertTrue(path.is_file(), relative)
            self.assertNotIn(key, path.read_text(encoding="utf-8"))
        for receipt in (self.batch_dir.glob("lane-*/work/receipts/*.json")):
            self.assertNotIn(key, receipt.read_text(encoding="utf-8"))

    def test_authorization_scheme_split_does_not_leak_value(self):
        # The fake child cuts inside the Authorization scheme and again inside
        # an opaque value that matches no generic credential pattern and is
        # not in the credential environment.  Only holding the unfinished
        # header line across the pipe read can remove it.
        key = "qp" + "Auth" + "Z9x7" + "K2m4"
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(batch.redact_text(key), key)
        cut = max(1, len(key) // 2)
        code, out, err = self.run_cli(env={"FAKE_AUTHORIZATION_SECRET": key})
        self.assertEqual(code, 0, out + err)
        self.assertNotIn(key, out)
        self.assertNotIn(key[cut:], out)
        self.assertIn("<redacted>", out)
        for log_path in self.batch_dir.glob("lane-*/work/scenarios.log"):
            text = log_path.read_text(encoding="utf-8")
            self.assertNotIn(key, text, str(log_path))
            self.assertNotIn(key[cut:], text, str(log_path))
            self.assertIn("<redacted>", text, str(log_path))
        for path in (
            list(self.batch_dir.rglob("report.json"))
            + list(self.batch_dir.glob("lane-*/work/receipts/*.json"))
            + [
                self.batch_dir / batch.BATCH_MANIFEST,
                self.batch_dir / batch.RUN_STATE,
                self.batch_dir / batch.SUMMARY_JSON,
                self.batch_dir / batch.SUMMARY_MD,
            ]
        ):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn(key, text, str(path))
            self.assertNotIn(key[cut:], text, str(path))

    def test_generic_sk_key_is_redacted_from_streamed_logs_and_stdout(self):
        key = "sk-" + "Q7X9Z3M5N8P4R2T6V1W0"
        code, out, err = self.run_cli(env={"FAKE_GENERIC_SK_SECRET": key})
        self.assertEqual(code, 0, out + err)
        self.assertNotIn(key, out)
        for index in range(3, len(key) - 3):
            self.assertNotIn(key[index:], out, "stdout suffix {}".format(index))
        self.assertIn("<redacted>", out)
        self.assertIn("generic=", out)
        for log_path in self.batch_dir.glob("lane-*/work/scenarios.log"):
            text = log_path.read_text(encoding="utf-8")
            self.assertNotIn(key, text)
            for index in range(3, len(key) - 3):
                self.assertNotIn(
                    key[index:], text, "{} suffix {}".format(log_path, index)
                )
            self.assertIn("<redacted>", text)
        for path in (
            list(self.batch_dir.rglob("report.json"))
            + [self.batch_dir / batch.SUMMARY_JSON, self.batch_dir / batch.SUMMARY_MD]
        ):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn(key, text, str(path))
            for index in range(3, len(key) - 3):
                self.assertNotIn(key[index:], text, "{} suffix {}".format(path, index))

    def test_generic_hyphenated_sk_key_is_redacted_from_streamed_outputs(self):
        # A provider key shape that is not in the credential environment and
        # would not match the old alphanumeric-only generic rule.
        key = "sk-proj-" + "Q7X9-Z3M5_N8P4.R2T6V1W0"
        code, out, err = self.run_cli(env={"FAKE_GENERIC_SK_SECRET": key})
        self.assertEqual(code, 0, out + err)
        self.assertNotIn(key, out)
        for index in range(3, len(key) - 3):
            self.assertNotIn(key[index:], out, "stdout suffix {}".format(index))
        self.assertIn("<redacted>", out)
        self.assertIn("generic=", out)
        for log_path in self.batch_dir.glob("lane-*/work/scenarios.log"):
            text = log_path.read_text(encoding="utf-8")
            self.assertNotIn(key, text)
            for index in range(3, len(key) - 3):
                self.assertNotIn(
                    key[index:], text, "{} suffix {}".format(log_path, index)
                )
            self.assertIn("<redacted>", text)
        for path in (
            list(self.batch_dir.rglob("report.json"))
            + [self.batch_dir / batch.SUMMARY_JSON, self.batch_dir / batch.SUMMARY_MD]
        ):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn(key, text, str(path))
            for index in range(3, len(key) - 3):
                self.assertNotIn(key[index:], text, "{} suffix {}".format(path, index))

    def test_punctuation_sk_key_is_redacted_from_streamed_outputs(self):
        # The fake child cuts at len//2, which is exactly after the separator
        # here, so both the exact-env and generic paths exercise the boundary
        # that used to leak a suffix.
        separators = ("/", "+", "=", ",", ";")
        for index, exact in enumerate((False, True)):
            for offset, separator in enumerate(
                separators + ((" ",) if exact else ())
            ):
                key = "sk-" + "A" * 8 + separator + "B" * 12
                self.batch_dir = self.root / "batch-{}-{}".format(index, offset)
                with self.subTest(exact=exact, separator=separator):
                    if exact:
                        env = {
                            "PDSH_MODEL_API_KEY": key,
                            "PDSH_MODEL_BASE_URL": "https://api.example.invalid/v1",
                            "PDSH_MODEL_NAME": "deepseek-flash",
                            "FAKE_ECHO_SECRET": "1",
                        }
                    else:
                        env = {
                            "PDSH_MODEL_API_KEY": None,
                            "FAKE_GENERIC_SK_SECRET": key,
                        }
                    code, out, err = self.run_cli(env=env)
                    self.assertEqual(code, 0, out + err)
                    self.assertNotIn(key, out)
                    for suffix_index in range(3, len(key) - 3):
                        self.assertNotIn(
                            key[suffix_index:],
                            out,
                            "stdout suffix {}".format(suffix_index),
                        )
                    self.assertIn("<redacted>", out)

                    logs = {}
                    for log_path in self.batch_dir.glob(
                        "lane-*/work/scenarios.log"
                    ):
                        logs[str(log_path)] = log_path.read_text(encoding="utf-8")
                    for label, text in logs.items():
                        self.assertNotIn(key, text, label)
                        for suffix_index in range(3, len(key) - 3):
                            self.assertNotIn(
                                key[suffix_index:],
                                text,
                                "{} suffix {}".format(label, suffix_index),
                            )
                        self.assertIn("<redacted>", text, label)
                    for path in (
                        list(self.batch_dir.rglob("report.json"))
                        + list(self.batch_dir.glob("lane-*/work/receipts/*.json"))
                        + [
                            self.batch_dir / batch.BATCH_MANIFEST,
                            self.batch_dir / batch.RUN_STATE,
                            self.batch_dir / batch.SUMMARY_JSON,
                            self.batch_dir / batch.SUMMARY_MD,
                        ]
                    ):
                        text = path.read_text(encoding="utf-8")
                        self.assertNotIn(key, text, str(path))
                        for suffix_index in range(3, len(key) - 3):
                            self.assertNotIn(
                                key[suffix_index:],
                                text,
                                "{} suffix {}".format(path, suffix_index),
                            )

    def test_real_credential_context_controls_resume_and_never_stores_key(self):
        key_one = "qp" + "7Rm2" + "xL9" + "t4"
        key_two = "zn" + "3Kp8" + "wQ1" + "m6"
        base_env = {
            "PDSH_MODEL_BASE_URL": "https://api.example.invalid/v1",
            "PDSH_MODEL_NAME": "deepseek-flash",
            "PDSH_MODEL_API_KEY": key_one,
        }
        real = ["--upstream", "real"]
        code, out, err = self.run_cli(real, env=base_env)
        self.assertEqual(code, 0, out + err)
        manifest_text = (self.batch_dir / batch.BATCH_MANIFEST).read_text(
            encoding="utf-8"
        )
        manifest = json.loads(manifest_text)
        self.assertEqual(
            manifest["identity"]["model"]["credential_context"]["source"],
            "unknown",
        )
        self.assertNotIn(key_one, manifest_text)
        self.assertNotIn(batch.sha256_bytes(key_one.encode()), manifest_text)
        summary_text = (self.batch_dir / batch.SUMMARY_JSON).read_text(
            encoding="utf-8"
        )
        summary_md = (self.batch_dir / batch.SUMMARY_MD).read_text(encoding="utf-8")
        self.assertEqual(
            json.loads(summary_text)["credential_context"]["source"], "unknown"
        )
        self.assertIn("Credential context is **unknown**", summary_md)

        # Unknown tenant/deployment: a real PASS is evidence for that run, but
        # an explicit resume must rerun instead of pretending the key rotation
        # still names the same credential context.
        before = invocation_ids(self.invocations)
        code, out, err = self.run_cli(real + ["--resume"], env=base_env)
        self.assertEqual(code, 0, out + err)
        self.assertIn("credential context is unknown", err)
        after = invocation_ids(self.invocations)
        self.assertEqual(sorted(after[len(before):]), ["G2-X", "G2-Y", "G2-Z"])

        # A non-secret config id makes the context explicit.  Changing it is a
        # new identity and reruns; rotating only the key under the same id can
        # reuse the PASS because the key is not part of the identity.
        explicit_one = dict(base_env, PDSH_MODEL_CONFIG_ID="tenant-a/deploy-1")
        before = invocation_ids(self.invocations)
        code, out, err = self.run_cli(real + ["--resume"], env=explicit_one)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(
            sorted(invocation_ids(self.invocations)[len(before):]),
            ["G2-X", "G2-Y", "G2-Z"],
        )
        explicit_rotated = dict(
            explicit_one, PDSH_MODEL_API_KEY=key_two
        )
        before = invocation_ids(self.invocations)
        code, out, err = self.run_cli(real + ["--resume"], env=explicit_rotated)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(invocation_ids(self.invocations), before)
        manifest = batch.load_manifest(self.batch_dir)
        self.assertEqual(
            manifest["identity"]["model"]["credential_context"],
            {
                "source": "explicit",
                "config_id": "tenant-a/deploy-1",
                "resume_reusable": True,
            },
        )
        for text in (
            (self.batch_dir / batch.BATCH_MANIFEST).read_text(encoding="utf-8"),
            (self.batch_dir / batch.SUMMARY_JSON).read_text(encoding="utf-8"),
            "".join(
                path.read_text(encoding="utf-8")
                for path in self.batch_dir.glob("lane-*/work/receipts/*.json")
            ),
        ):
            self.assertNotIn(key_one, text)
            self.assertNotIn(key_two, text)
            self.assertNotIn(batch.sha256_bytes(key_one.encode()), text)
            self.assertNotIn(batch.sha256_bytes(key_two.encode()), text)

    def test_base_url_path_credential_never_becomes_an_endpoint_digest(self):
        key = "qp" + "7Rm2" + "xL9" + "t4"
        raw_url = "https://api.example.invalid/v1/" + key
        env = {
            "PDSH_MODEL_BASE_URL": raw_url,
            "PDSH_MODEL_NAME": "deepseek-flash",
            "PDSH_MODEL_API_KEY": key,
        }
        identity = batch.build_identity(
            self.root,
            self.catalog,
            "macos",
            "real",
            env={**self.assets, **env},
            scenarios_script=self.runner,
        )
        serialized = json.dumps(identity, sort_keys=True)
        self.assertNotIn(key, serialized)
        self.assertNotIn(
            batch.sha256_bytes(raw_url.encode()), serialized
        )
        self.assertNotEqual(
            identity["model"]["base_url_sha256"],
            batch.sha256_bytes(raw_url.encode()),
        )
        self.assertIn("<redacted>", batch._safe_endpoint_url(raw_url, env=env))

        code, out, err = self.run_cli(["--upstream", "real"], env=env)
        self.assertEqual(code, 0, out + err)
        raw_digest = batch.sha256_bytes(raw_url.encode())
        for path in (
            self.batch_dir / batch.BATCH_MANIFEST,
            self.batch_dir / batch.SUMMARY_JSON,
            self.batch_dir / batch.SUMMARY_MD,
        ):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn(key, text, str(path))
            self.assertNotIn(raw_digest, text, str(path))
        for path in self.batch_dir.glob("lane-*/work/receipts/*.json"):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn(key, text, str(path))
            self.assertNotIn(raw_digest, text, str(path))

    def test_base_url_query_credential_never_becomes_an_endpoint_digest(self):
        key = "qp" + "7Rm2" + "/xL9" + "t4"
        urls = (
            ("plain", "https://api.example.invalid/v1?code=" + key),
            (
                "percent-encoded",
                "https://api.example.invalid/v1?code=" + quote(key, safe=""),
            ),
        )
        for index, (label, raw_url) in enumerate(urls):
            with self.subTest(label=label):
                self.batch_dir = self.root / ("batch-query-" + str(index))
                env = {
                    "PDSH_MODEL_BASE_URL": raw_url,
                    "PDSH_MODEL_NAME": "deepseek-flash",
                    "PDSH_MODEL_API_KEY": key,
                }
                identity = batch.build_identity(
                    self.root,
                    self.catalog,
                    "macos",
                    "real",
                    env={**self.assets, **env},
                    scenarios_script=self.runner,
                )
                serialized = json.dumps(identity, sort_keys=True)
                raw_digest = batch.sha256_bytes(raw_url.encode())
                key_digest = batch.sha256_bytes(key.encode())
                self.assertNotIn(key, serialized)
                self.assertNotIn(raw_digest, serialized)
                self.assertNotIn(key_digest, serialized)
                self.assertNotEqual(
                    identity["model"]["base_url_sha256"], raw_digest
                )
                sanitized = batch._safe_endpoint_url(raw_url, env=env)
                self.assertNotIn(key, sanitized)
                self.assertNotIn(quote(key, safe=""), sanitized)
                self.assertIn("code=", sanitized)
                self.assertIn("redacted", sanitized)

                code, out, err = self.run_cli(
                    ["--upstream", "real"], env=env
                )
                self.assertEqual(code, 0, label + ": " + out + err)
                for path in (
                    self.batch_dir / batch.BATCH_MANIFEST,
                    self.batch_dir / batch.SUMMARY_JSON,
                    self.batch_dir / batch.SUMMARY_MD,
                ):
                    content = path.read_text(encoding="utf-8")
                    self.assertNotIn(key, content, str(path))
                    self.assertNotIn(raw_digest, content, str(path))
                    self.assertNotIn(key_digest, content, str(path))
                for path in self.batch_dir.glob(
                    "lane-*/work/receipts/*.json"
                ):
                    content = path.read_text(encoding="utf-8")
                    self.assertNotIn(key, content, str(path))
                    self.assertNotIn(raw_digest, content, str(path))
                    self.assertNotIn(key_digest, content, str(path))

    def test_base_url_host_credential_never_becomes_endpoint_identity(self):
        key = "qp" + "7Rm2" + "xL9" + "t4"
        raw_url = "https://" + key + ".example.invalid/v1"
        env = {
            "PDSH_MODEL_BASE_URL": raw_url,
            "PDSH_MODEL_NAME": "deepseek-flash",
            "PDSH_MODEL_API_KEY": key,
        }
        # Hosts are case-insensitive; urlsplit lowercases them.  The key must
        # be removed from both batch.json's plaintext host and the URL hash.
        self.assertEqual(
            batch.safe_url(raw_url, env=env),
            "https://<redacted>.example.invalid",
        )
        self.assertEqual(
            batch.safe_url(
                "https://" + key.upper() + ".example.invalid/v1", env=env
            ),
            "https://<redacted>.example.invalid",
        )

        identity = batch.build_identity(
            self.root,
            self.catalog,
            "macos",
            "real",
            env={**self.assets, **env},
            scenarios_script=self.runner,
        )
        serialized = json.dumps(identity, sort_keys=True)
        raw_digest = batch.sha256_bytes(raw_url.encode())
        key_digest = batch.sha256_bytes(key.encode())
        self.assertNotIn(key, serialized)
        self.assertNotIn(raw_digest, serialized)
        self.assertNotIn(key_digest, serialized)
        self.assertIn("<redacted>", identity["model"]["base_url"])
        self.assertNotEqual(identity["model"]["base_url_sha256"], raw_digest)
        sanitized = batch._safe_endpoint_url(raw_url, env=env)
        self.assertNotIn(key, sanitized)
        self.assertIn("<redacted>", sanitized)
        self.assertTrue(sanitized.endswith("/v1"))

        code, out, err = self.run_cli(["--upstream", "real"], env=env)
        self.assertEqual(code, 0, out + err)
        for path in (
            self.batch_dir / batch.BATCH_MANIFEST,
            self.batch_dir / batch.SUMMARY_JSON,
            self.batch_dir / batch.SUMMARY_MD,
        ):
            content = path.read_text(encoding="utf-8")
            self.assertNotIn(key, content, str(path))
            self.assertNotIn(raw_digest, content, str(path))
            self.assertNotIn(key_digest, content, str(path))
        for path in self.batch_dir.glob("lane-*/work/receipts/*.json"):
            content = path.read_text(encoding="utf-8")
            self.assertNotIn(key, content, str(path))
            self.assertNotIn(raw_digest, content, str(path))
            self.assertNotIn(key_digest, content, str(path))

    def test_base_url_userinfo_delimiters_never_become_endpoint_identity(self):
        # urlsplit treats "/" and "?" as delimiters even inside URL userinfo.
        # An unencoded key containing one of them spills into host/path/query,
        # so sanitizing each parsed component in isolation can neither remove
        # the whole key nor prevent hashing the URL that still contains it.
        for index, separator in enumerate(("/", "?")):
            key = "sk-" + "abc" + separator + "def"
            raw_url = "https://" + key + "@api.example.invalid/v1"
            with self.subTest(separator=separator):
                self.batch_dir = self.root / "batch-userinfo-{}".format(index)
                env = {
                    "PDSH_MODEL_BASE_URL": raw_url,
                    "PDSH_MODEL_NAME": "deepseek-flash",
                    "PDSH_MODEL_API_KEY": key,
                }
                self.assertNotIn(key, batch.safe_url(raw_url, env=env))
                sanitized = batch._safe_endpoint_url(raw_url, env=env)
                self.assertNotIn(key, sanitized)
                self.assertNotIn(quote(key, safe=""), sanitized)
                self.assertEqual(
                    sanitized, "https://api.example.invalid/v1"
                )
                # A differently-cased percent-encoded spelling escapes both
                # raw and component replacement; it must fail closed instead
                # of being hashed with the key still inside.
                residual = "https://api.example.invalid/v1/" + key.upper().replace(
                    separator, "%2f" if separator == "/" else "%3f"
                )
                self.assertEqual(
                    batch._safe_endpoint_url(residual, env=env),
                    "<invalid-url>",
                )

                identity = batch.build_identity(
                    self.root,
                    self.catalog,
                    "macos",
                    "real",
                    env={**self.assets, **env},
                    scenarios_script=self.runner,
                )
                serialized = json.dumps(identity, sort_keys=True)
                raw_digest = batch.sha256_bytes(raw_url.encode())
                key_digest = batch.sha256_bytes(key.encode())
                self.assertNotIn(key, serialized)
                self.assertNotIn(raw_digest, serialized)
                self.assertNotIn(key_digest, serialized)
                self.assertNotEqual(
                    identity["model"]["base_url_sha256"], raw_digest
                )

                code, out, err = self.run_cli(
                    ["--upstream", "real"], env=env
                )
                self.assertEqual(
                    code, 0, "{}: {}".format(separator, out + err)
                )
                for path in (
                    self.batch_dir / batch.BATCH_MANIFEST,
                    self.batch_dir / batch.SUMMARY_JSON,
                    self.batch_dir / batch.SUMMARY_MD,
                ):
                    content = path.read_text(encoding="utf-8")
                    self.assertNotIn(key, content, str(path))
                    self.assertNotIn(raw_digest, content, str(path))
                    self.assertNotIn(key_digest, content, str(path))
                for path in self.batch_dir.glob(
                    "lane-*/work/receipts/*.json"
                ):
                    content = path.read_text(encoding="utf-8")
                    self.assertNotIn(key, content, str(path))
                    self.assertNotIn(raw_digest, content, str(path))
                    self.assertNotIn(key_digest, content, str(path))

    def test_prebuilt_engine_identity_skips_unconsumed_python_and_jq(self):
        unused_python = self.root / "unused-python"
        unused_jq = self.root / "unused-jq"
        env = {
            "PDSH_PYTHON_ARTIFACTS": str(unused_python),
            "PDSH_JQ_ARTIFACTS": str(unused_jq),
        }
        planned = batch.build_plan(
            self.catalog,
            self.root,
            self.root / "plan-batch",
            env={**self.assets, **env},
            scenarios_script=self.runner,
        )
        self.assertTrue(planned["execution_ready"])
        self.assertEqual(
            planned["identity"]["engine"]["assets"]["mode"], "prebuilt"
        )
        code, out, err = self.run_cli(env=env)
        self.assertEqual(code, 0, out + err)
        self.assertFalse(unused_python.exists())
        self.assertFalse(unused_jq.exists())
        manifest = batch.load_manifest(self.batch_dir)
        engine = manifest["identity"]["engine"]
        assets = engine["assets"]
        www = Path(self.assets["PDSH_DSH_WWW"])
        image = Path(self.assets["PDSH_DSH_IMAGE"])
        self.assertEqual(assets["mode"], "prebuilt")
        self.assertTrue(engine["execution_provenance"]["ready"])
        self.assertEqual(
            assets["bundle"]["sha256"], batch.hash_file_tree(www)[0]
        )
        self.assertEqual(assets["image"]["sha256"], batch.sha256_file(image))
        for key in ("python", "jq"):
            self.assertIs(assets[key]["consumed"], False)
            self.assertIsNone(assets[key]["sha256"])
            self.assertEqual(assets[key]["files"], {})
            self.assertEqual(assets[key]["missing"], [])
            self.assertTrue(assets[key]["reason"])
        self.assertEqual(
            engine["dsh_pin_sha256"],
            batch.sha256_file(self.root / "plugins" / "dsh-pin.json"),
        )
        self.assertTrue(assets["complete"])
        self.assertEqual(assets["missing"], [])
        receipt = json.loads(
            (
                self.batch_dir / "lane-1" / "work" / "receipts" / "G2-X.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(
            receipt["engine_fingerprint"], engine["fingerprint"]
        )

    def test_build_cache_engine_identity_hashes_python_and_jq(self):
        code, out, err = self.run_cli(env=self.default_cache_env())
        self.assertEqual(code, 0, out + err)
        manifest = batch.load_manifest(self.batch_dir)
        engine = manifest["identity"]["engine"]
        assets = engine["assets"]
        build_www = (
            Path(self.build_cache["PDSH_SCENARIO_BUILD_DIR"]) / "www"
        )
        self.assertEqual(assets["mode"], "build-cache")
        self.assertTrue(engine["execution_provenance"]["ready"])
        self.assertEqual(
            assets["bundle"]["sha256"], batch.hash_file_tree(build_www)[0]
        )
        self.assertEqual(
            assets["image"]["sha256"],
            batch.sha256_file(build_www / "image.tar.gz"),
        )
        python_digest = hashlib.sha256()
        for name in ("python.wasm", "python313.zip"):
            python_digest.update(
                (Path(self.assets["PDSH_PYTHON_ARTIFACTS"]) / name).read_bytes()
            )
        self.assertEqual(assets["python"]["sha256"], python_digest.hexdigest())
        jq_digest = hashlib.sha256()
        for name in ("jq.wasm", "engine.json"):
            jq_digest.update(
                (Path(self.assets["PDSH_JQ_ARTIFACTS"]) / name).read_bytes()
            )
        self.assertEqual(assets["jq"]["sha256"], jq_digest.hexdigest())
        self.assertTrue(assets["complete"])
        self.assertEqual(assets["missing"], [])
        self.assertEqual(
            assets["python"]["missing"] + assets["jq"]["missing"], []
        )

    def test_default_build_cache_accepts_smoke_bundle_layout(self):
        smoke_env = make_smoke_build_cache(self.root)
        code, out, err = self.run_cli(env=self.default_cache_env(smoke_env))
        self.assertEqual(code, 0, out + err)
        manifest = batch.load_manifest(self.batch_dir)
        engine = manifest["identity"]["engine"]
        assets = engine["assets"]
        www = (
            Path(smoke_env["PDSH_SCENARIO_BUILD_DIR"]) / "www"
        )
        self.assertEqual(assets["mode"], "build-cache")
        self.assertTrue(engine["execution_provenance"]["ready"])
        self.assertTrue(assets["complete"], assets["missing"])
        self.assertEqual(assets["bundle"]["sha256"], batch.hash_file_tree(www)[0])
        for name in batch.BUNDLE_REQUIRED_FILES:
            self.assertTrue((www / name).is_file(), name)
        self.assertTrue(read_summary(self.batch_dir)["ok"])

    def test_smoke_bundle_assembly_stages_every_required_worker_asset(self):
        smoke = (REPO / "scripts" / "ci" / "smoke.sh").read_text(
            encoding="utf-8"
        )
        staged = {
            "worker-entry.js": (
                '"$WORKER_OUT/worker-entry.js"',
                '> "$BUNDLE_DIR/worker-entry.js"',
            ),
            "tool-worker-python.js": (
                'cp "$WORKER_OUT/tool-worker-python.js" "$BUNDLE_DIR/"',
            ),
            "tool-worker.js": (
                'cp "$WORKER_OUT/tool-worker.js" "$BUNDLE_DIR/"',
            ),
            "index.html": (
                'cp "$WORKER_OUT/www/index.html" "$WORKER_OUT/www/boot.js" '
                '"$BUNDLE_DIR/"',
            ),
            "boot.js": (
                'cp "$WORKER_OUT/www/index.html" "$WORKER_OUT/www/boot.js" '
                '"$BUNDLE_DIR/"',
            ),
        }
        self.assertEqual(
            set(staged) | {"phone-dsh-provenance.json"},
            set(batch.BUNDLE_REQUIRED_FILES),
        )
        for name, snippets in staged.items():
            for snippet in snippets:
                self.assertIn(
                    snippet,
                    smoke,
                    "smoke.sh must stage the required bundle file {}".format(
                        name
                    ),
                )
        for name in ("tool-worker.js", "tool-worker-python.js"):
            self.assertIn(
                'cp "$WORKER_OUT/{}.map" "$BUNDLE_DIR/"'.format(name),
                smoke,
                "smoke.sh must stage the {} source map".format(name),
            )
        self.assertIn(
            'cp "$IMAGE_OUT/image.tar.gz" "$BUNDLE_DIR/"', smoke
        )
        self.assertIn(
            '--out "$BUNDLE_DIR"', smoke
        )
        self.assertGreaterEqual(
            smoke.count('[ ! -f "$PDSH_DSH_WWW/tool-worker.js" ]'),
            2,
            "smoke.sh must require tool-worker.js for prebuilt and built bundles",
        )

    def test_run_refuses_missing_engine_assets_before_any_child(self):
        empty = self.root / "empty-tmp"
        env = {
            "TMPDIR": str(empty),
            "PDSH_DSH_WWW": "",
            "PDSH_DSH_IMAGE": "",
            "PDSH_PYTHON_ARTIFACTS": "",
            "PDSH_JQ_ARTIFACTS": "",
        }
        code, out, err = self.run_cli(env=env)
        self.assertEqual(code, 2, out + err)
        self.assertIn("execution provenance is not complete", err)
        self.assertIn("PDSH_DSH_WWW", err)
        self.assertEqual(invocation_ids(self.invocations), [])
        self.assertFalse((self.batch_dir / batch.BATCH_MANIFEST).exists())

    def test_resume_reruns_when_any_engine_asset_or_pin_changes(self):
        build_www = (
            Path(self.build_cache["PDSH_SCENARIO_BUILD_DIR"]) / "www"
        )
        self.assertEqual(
            self.run_cli(env=self.default_cache_env())[0], 0
        )
        changes = (
            (
                "bundle",
                lambda: (build_www / "worker-entry.js").write_text(
                    "// changed bundle\n", encoding="utf-8"
                ),
            ),
            (
                "image",
                lambda: (build_www / "image.tar.gz").write_text(
                    "changed image\n", encoding="utf-8"
                ),
            ),
            (
                "python",
                lambda: (
                    Path(self.assets["PDSH_PYTHON_ARTIFACTS"]) / "python.wasm"
                ).write_text("changed python\n", encoding="utf-8"),
            ),
            (
                "jq",
                lambda: (
                    Path(self.assets["PDSH_JQ_ARTIFACTS"]) / "engine.json"
                ).write_text('{"engine":"changed"}\n', encoding="utf-8"),
            ),
            (
                "pin",
                lambda: (self.root / "plugins" / "dsh-pin.json").write_text(
                    '{"commit":"changed-pin"}\n', encoding="utf-8"
                ),
            ),
        )
        for label, mutate in changes:
            previous = batch.load_manifest(self.batch_dir)
            mutate()
            before = invocation_ids(self.invocations)
            code, out, err = self.run_cli(
                ["--resume"], env=self.default_cache_env()
            )
            self.assertEqual(code, 0, label + ": " + out + err)
            after = invocation_ids(self.invocations)
            self.assertEqual(
                sorted(after[len(before):]),
                ["G2-X", "G2-Y", "G2-Z"],
                label,
            )
            current = batch.load_manifest(self.batch_dir)
            self.assertNotEqual(
                current["identity"]["fingerprint"],
                previous["identity"]["fingerprint"],
                label,
            )
            self.assertTrue(read_summary(self.batch_dir)["ok"], label)

    def test_zero_byte_engine_assets_fail_closed_before_any_child(self):
        build_www = (
            Path(self.build_cache["PDSH_SCENARIO_BUILD_DIR"]) / "www"
        )
        targets = (
            ("bundle", build_www / "boot.js"),
            ("image", build_www / "image.tar.gz"),
            (
                "python",
                Path(self.assets["PDSH_PYTHON_ARTIFACTS"]) / "python.wasm",
            ),
            (
                "python-zip",
                Path(self.assets["PDSH_PYTHON_ARTIFACTS"]) / "python313.zip",
            ),
            ("jq", Path(self.assets["PDSH_JQ_ARTIFACTS"]) / "jq.wasm"),
            (
                "jq-engine",
                Path(self.assets["PDSH_JQ_ARTIFACTS"]) / "engine.json",
            ),
            ("pin", self.root / "plugins" / "dsh-pin.json"),
        )
        for label, target in targets:
            original = target.read_bytes()
            try:
                target.write_bytes(b"")
                code, out, err = self.run_cli(env=self.default_cache_env())
                self.assertEqual(code, 2, label + ": " + out + err)
                self.assertIn(
                    "engine assets are missing or empty", err, label
                )
                self.assertIn("empty", err, label)
                self.assertEqual(invocation_ids(self.invocations), [], label)
                self.assertFalse(
                    (self.batch_dir / batch.BATCH_MANIFEST).exists(), label
                )
            finally:
                target.write_bytes(original)

    def test_runtime_engine_rebuild_never_writes_a_pass_receipt(self):
        image = (
            Path(self.build_cache["PDSH_SCENARIO_BUILD_DIR"])
            / "www"
            / "image.tar.gz"
        )
        code, out, err = self.run_cli(
            env=self.default_cache_env({"FAKE_MUTATE_ASSET": str(image)})
        )
        self.assertEqual(code, 1, out + err)
        self.assertIn("changed while the batch was running", err)
        summary = read_summary(self.batch_dir)
        self.assertFalse(summary["ok"])
        self.assertEqual(summary["counts"]["PASS"], 0)
        for scenario_id in ("G2-X", "G2-Y", "G2-Z"):
            self.assertEqual(
                summary["scenarios"][scenario_id]["status"], "BLOCKED"
            )
        receipts = list(
            self.batch_dir.glob("lane-*/work/receipts/*.json")
        )
        self.assertEqual(len(receipts), 3)
        for path in receipts:
            receipt = json.loads(path.read_text(encoding="utf-8"))
            self.assertNotEqual(receipt["status"], "PASS", str(path))
            self.assertEqual(receipt["status"], "BLOCKED", str(path))
        self.assertTrue(
            any(
                "Worker image changed" in issue
                for issue in summary["issues"]
            ),
            summary["issues"],
        )

    def test_runtime_fixture_change_blocks_receipts_and_resume_reruns(self):
        fixture = (
            self.root
            / "scripts"
            / "ci"
            / "scenarios"
            / "fixtures"
            / "demo"
            / "files"
            / "README.md"
        )
        original = "original fixture payload\n"
        write_text(fixture, original)
        self.catalog = small_catalog(
            self.root,
            ["G2-X", "G2-Y", "G2-Z"],
            lanes=[["G2-X", "G2-Y"], ["G2-Z"]],
            fixtures=["demo"],
        )
        code, out, err = self.run_cli(
            env={
                "FAKE_MUTATE_ASSET": str(fixture),
                "FAKE_MUTATE_CONTENT": original + "changed by the child\n",
            }
        )
        self.assertEqual(code, 1, out + err)
        self.assertIn("fixture payload changed while the batch was running", err)
        summary = read_summary(self.batch_dir)
        self.assertFalse(summary["ok"])
        self.assertEqual(summary["counts"]["PASS"], 0)
        receipts = list(self.batch_dir.glob("lane-*/work/receipts/*.json"))
        self.assertEqual(len(receipts), 3)
        for path in receipts:
            receipt = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(receipt["status"], "BLOCKED", str(path))

        # Restoring the pre-run bytes makes the manifest identity current
        # again, but the blocked receipts must still force a real rerun.
        write_text(fixture, original)
        before = invocation_ids(self.invocations)
        code, out, err = self.run_cli(["--resume"])
        self.assertEqual(code, 0, out + err)
        after = invocation_ids(self.invocations)
        self.assertEqual(
            sorted(after[len(before):]), ["G2-X", "G2-Y", "G2-Z"]
        )
        self.assertTrue(read_summary(self.batch_dir)["ok"])

    def test_runtime_catalog_and_source_change_block_receipts(self):
        cases = (
            (
                "catalog",
                self.catalog,
                "catalog changed while the batch was running",
            ),
            (
                "source",
                self.root / "README.md",
                "source changed while the batch was running",
            ),
        )
        for label, target, expected in cases:
            with self.subTest(label=label):
                target = Path(target)
                original = target.read_text(encoding="utf-8")
                self.batch_dir = self.root / ("batch-runtime-" + label)
                code, out, err = self.run_cli(
                    env={
                        "FAKE_MUTATE_ASSET": str(target),
                        "FAKE_MUTATE_CONTENT": original + "\n",
                    }
                )
                self.assertEqual(code, 1, label + ": " + out + err)
                self.assertIn(expected, err)
                summary = read_summary(self.batch_dir)
                self.assertFalse(summary["ok"], label)
                self.assertEqual(summary["counts"]["PASS"], 0, label)
                receipts = list(
                    self.batch_dir.glob("lane-*/work/receipts/*.json")
                )
                self.assertEqual(len(receipts), 3, label)
                for path in receipts:
                    receipt = json.loads(path.read_text(encoding="utf-8"))
                    self.assertEqual(receipt["status"], "BLOCKED", str(path))

                target.write_text(original, encoding="utf-8")
                before = invocation_ids(self.invocations)
                code, out, err = self.run_cli(["--resume"])
                self.assertEqual(code, 0, label + ": " + out + err)
                after = invocation_ids(self.invocations)
                self.assertEqual(
                    sorted(after[len(before):]),
                    ["G2-X", "G2-Y", "G2-Z"],
                    label,
                )
                self.assertTrue(read_summary(self.batch_dir)["ok"], label)

    def test_resume_refuses_missing_asset_and_summary_blocks_it(self):
        self.assertEqual(self.run_cli()[0], 0)
        before = invocation_ids(self.invocations)
        Path(self.assets["PDSH_DSH_IMAGE"]).unlink()
        code, out, err = self.run_cli(["--resume"])
        self.assertEqual(code, 2, out + err)
        self.assertIn("engine assets", err)
        self.assertEqual(invocation_ids(self.invocations), before)
        code, out, err = self.summary()
        self.assertEqual(code, 1, out + err)
        summary = read_summary(self.batch_dir)
        self.assertFalse(summary["ok"])
        self.assertTrue(
            any(
                "Worker image changed" in issue or "engine" in issue
                for issue in summary["issues"]
            ),
            summary["issues"],
        )

    def test_summary_blocks_bundle_change_without_a_resume(self):
        self.assertEqual(self.run_cli()[0], 0)
        write_text(
            Path(self.assets["PDSH_DSH_WWW"]) / "worker-entry.js",
            "// changed without resume\n",
        )
        code, out, err = self.summary()
        self.assertEqual(code, 1, out + err)
        summary = read_summary(self.batch_dir)
        self.assertFalse(summary["ok"])
        self.assertTrue(
            any("Worker bundle changed" in issue for issue in summary["issues"]),
            summary["issues"],
        )

    def test_redactor_handles_exports_bearer_and_authorization_values(self):
        secret = "sk-" + "abcdefgh"
        bearer = "opaque" + "token123"
        text = "export PDSH_MODEL_API_KEY='{}'\nAuthorization: Bearer {}\napi_key={}".format(
            secret, bearer, secret
        )
        redacted = batch.redact_text(text)
        self.assertNotIn(secret, redacted)
        self.assertNotIn(bearer, redacted)
        self.assertIn("<redacted>", redacted)

    def test_redactor_handles_prefixed_keys_any_auth_scheme_and_url_values(self):
        key = "opaque-key-" + "123456789"
        basic = "YWxpY2U6czNjcjN0"
        base = (
            "https://alice:s3cr3t!@api.test/v1/private"
            "?token=hidden&mode=test"
        )
        text = "\n".join(
            [
                "TEST_RUNNER_PDSH_MODEL_API_KEY=" + key,
                "SIMCTL_CHILD_PDSH_MODEL_API_KEY=" + key,
                "Authorization: Basic " + basic,
                "Authorization: Token " + key,
                "Proxy-Authorization: Basic " + basic,
                "url=" + base,
                "userinfo=alice:s3cr3t!",
                "path=/v1/private",
                "query=hidden",
            ]
        )
        with mock.patch.dict(
            os.environ,
            {"PDSH_MODEL_API_KEY": key, "PDSH_MODEL_BASE_URL": base},
            clear=False,
        ):
            redacted = batch.redact_text(text)
        for secret in (key, basic, "alice:s3cr3t!", "hidden", "/v1/private", base):
            self.assertNotIn(secret, redacted)
        self.assertIn("<redacted>", redacted)

        # The generic URL rules still protect a value that is not in this
        # process's model environment at all.
        with mock.patch.dict(os.environ, {}, clear=True):
            generic = batch.redact_text(
                "https://bob:pw!@api.test/v1?token=zzz&mode=test"
            )
        self.assertNotIn("bob:pw!", generic)
        self.assertNotIn("zzz", generic)
        self.assertIn("<redacted>", generic)

    def test_redactor_uses_prefixed_credential_value_even_without_plain_name(self):
        key = "prefixed-" + "opaque-value"
        with mock.patch.dict(
            os.environ,
            {"TEST_RUNNER_PDSH_MODEL_API_KEY": key},
            clear=True,
        ):
            redacted = batch.redact_text("leaked=" + key)
        self.assertNotIn(key, redacted)
        self.assertIn("<redacted>", redacted)


if __name__ == "__main__":
    unittest.main()
