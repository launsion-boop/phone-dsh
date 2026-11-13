#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Structural gate for the PDSH Android adapter tree.

The gate is intentionally independent of Gradle and the network: it is the
only Android check that can run on the current host. Each check prints exactly
one PASS/FAIL line; the process exits 1 if any check fails.

Checks:
  settings-includes   include(...) set == module directories, both directions
  module-build-files  every included module has build.gradle.kts
  module-inventory    the module set is the prepared PR22/PR14 14-module tree
  page-inventory      the UI page layer still carries the prepared baseline pages
  sdk-levels          :lib and :app declare minSdk 26 and targetSdk 35
  readme-map          README, source modules and Android packages match the reviewed inventory
  kotlin-stubs        no TODO()/not-implemented stub left in src/main Kotlin
  repositories        only google()/mavenCentral() are allowed, plus the in-tree
                      publish repository (a path, never a URL)
  absolute-paths      no hard-coded home/SDK/toolchain absolute paths
  local-properties    android/local.properties stays gitignored (machine-local)
  catalog-pins        every [versions] entry is marked "# unverified pin"
  android-16k-link-arg shell/crates/pdsh-jni/build.rs pins 16 KB pages for
                      Android targets only (plan P2a; a commented-out flag
                      does not count, because comments are stripped first)
  android-16k-artifact every PT_LOAD of a built Android libpdsh_jni.so
                      (arm64-v8a debug/release, x86_64 debug) has
                      p_align >= 0x4000; SKIPs (with the build command) when
                      no artifact is in the tree
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "spec" / "v1" / "tools"))
from spec_golden import SpecError, load_json, validate_json  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "spec" / "platform" / "tools"))
from platform_check import lint_schema  # noqa: E402

SWIFT_PREFIX = "PhoneDSH"
# The prepared PR14 baseline after the shared-shell merge. This is an inventory,
# not a generic "number of include lines": a module that disappears (or appears
# without a reviewed README mapping) is a structural change and must be seen.
EXPECTED_MODULES = (
    "platform",
    "platform-android",
    "domain",
    "core",
    "net",
    "pclink",
    "bot",
    "controller",
    "engine",
    "shell",
    "dsh",
    "lib",
    "testkit",
    "app",
    "lib-consumer-test",
)
# PR22 replaces the old five-tab Chrome with the real App pages. The prepared
# candidate carries 34 `*Page.kt` files under this directory. Later page lanes
# may add files (the count is a floor), but deleting below the prepared tree is
# a regression, not a refactor. `ChatPage.kt` is the PR22 home, so it is the one
# file the inventory requires by name.
UI_PAGE_DIR_REL = Path("android") / "lib" / "src" / "main" / "kotlin" / "com" / "phonedsh" / "ui" / "page"
EXPECTED_UI_PAGES = 34
REQUIRED_UI_PAGES = ("ChatPage.kt",)
SDK_MODULES = {"lib": 26, "app": 26}
TARGET_SDK = 35

# 16 KB page alignment (plan P2a, DSV F5). Android 15+ can run on a 16 KB-page
# kernel and then refuses any .so whose PT_LOAD p_align is below 0x4000; a 4 KB
# emulator cannot show the defect. The flag lives in the JNI crate's build script
# (not a workspace Cargo config: a config is hashed by another lane's jq source
# fingerprint and is one `cfg` mistake away from the host/wasm links). The gate
# reads that script and strips comments first, so a flag someone commented out
# is not mistaken for a flag that is on. The artifact half needs a build product;
# it SKIPs (with the build command) instead of pretending green.
CARGO_16K_CONFIG = "shell/crates/pdsh-jni/build.rs"
MIN_PAGE_SIZE = 16384
ANDROID_SO_CANDIDATES = (
    # arm64-v8a is the release ABI; x86_64 is the debug/emulator product, which
    # must also load on a 16 KB emulator image.
    "shell/target/aarch64-linux-android/debug/libpdsh_jni.so",
    "shell/target/aarch64-linux-android/release/libpdsh_jni.so",
    "shell/target/x86_64-linux-android/debug/libpdsh_jni.so",
)


SKIP_DIR_NAMES = {".git", ".gradle", "build", "__pycache__"}
# `TODO()` or `error("... not implemented")` in src/main: an unfinished stub.
STUB_RE = re.compile(r"\bTODO\(|\berror\(\s*\"[^\"]*not implemented", re.IGNORECASE)
TEXT_SUFFIXES = {
    ".kt",
    ".kts",
    ".toml",
    ".properties",
    ".pro",
    ".md",
    ".py",
    ".yml",
    ".yaml",
    ".txt",
    ".json",
}

INCLUDE_RE = re.compile(r"\binclude\s*\(([^)]*)\)", re.S)
QUOTED_RE = re.compile(r"[\"']([^\"']+)[\"']")
PACKAGE_RE = re.compile(r"^package\s+[A-Za-z_][\w.]*\s*;?$")
IMPORT_RE = re.compile(r"^import\s+(?:static\s+)?[A-Za-z_][\w.*]*\s*;?$")
MIN_SDK_RE = re.compile(r"\bminSdk\s*=\s*(\d+)\b")
TARGET_SDK_RE = re.compile(r"\btargetSdk\s*=\s*(\d+)\b")
# Repository policy: a *network* repository must be google() or mavenCentral().
# The one other thing a build in this tree may declare is the in-tree publish
# repository (`android/build/repo`), because a published coordinate cannot be
# declared without a `maven { }` block, and a path inside the build tree is not a
# network dependency: it is a product of this checkout (root `.gitignore` rule
# `build/`, so it never ships), resolving from it needs no network, and it writes
# nothing outside the tree.
#
# The exception is narrow on purpose, and the tests pin BOTH directions:
#   * `maven { }`/`ivy { }` is admitted only in a file that points its url at a
#     path containing `build/repo` through `uri(...)` — i.e. a path, not a URL;
#     a `maven { }` naming any URL still fails on the `://` rule below, which is
#     what keeps `test_external_maven_url_still_fails` red;
#   * `mavenLocal()`, `gradlePluginPortal()`, `jcenter()` and `flatDir { }` stay
#     forbidden outright: they resolve against machine state or a dead
#     repository, which is exactly what this check exists to keep out.
HARD_FORBIDDEN_REPO_RE = re.compile(
    r"\b(?:mavenLocal|gradlePluginPortal|jcenter|flatDir)\s*\("
)
PATH_REPO_RE = re.compile(r"\b(?:maven|ivy)\s*[({]")
# Both markers must appear in the file that declares the path repository: the
# path itself, and `uri(...)` rather than a string literal (a `file:` URL is
# rejected too — the rule below fails on its `://`).
IN_TREE_REPO_MARKERS = ("build/repo", "url = uri(")
# `-Wl,-z,max-page-size=16384` (the value is checked, not assumed).
MAX_PAGE_RE = re.compile(r"max-page-size=(\d+)")
# An absolute path starts a token. A slash that follows a path-join character is a
# continuation, not a new path: `<root>/home/a` and `"$X"/bin` are relative joins,
# and flagging them turns a correct doc comment into a build failure. The preceders
# excluded here are the ones that end an expression (`>`, `}`, `)`, `+`) or an escape.
ABS_POSIX_RE = re.compile(
    r"(?<![\w.\->}+)\\])/(?:"
    + "|".join(("Users", "home", "opt", "usr", "var", "tmp", "private", "Volumes", "mnt", "srv", "etc"))
    + r")/"
)
ABS_WINDOWS_RE = re.compile(r"(?<![A-Za-z0-9])[A-Za-z]:[\\/]")


def strip_comments(text):
    """Remove Kotlin/TOML/Gradle line and block comments, respecting strings."""
    collected = []
    in_block = False
    for raw in text.splitlines():
        line = raw
        buf = []
        index = 0
        quote = None
        while index < len(line):
            if in_block:
                end = line.find("*/", index)
                if end < 0:
                    index = len(line)
                else:
                    in_block = False
                    index = end + 2
                continue
            char = line[index]
            if quote is not None:
                buf.append(char)
                if char == "\\" and index + 1 < len(line):
                    buf.append(line[index + 1])
                    index += 2
                    continue
                if char == quote:
                    quote = None
                index += 1
                continue
            if char in "\"'":
                quote = char
                buf.append(char)
                index += 1
                continue
            if line.startswith("//", index):
                break
            if line.startswith("/*", index):
                in_block = True
                index += 2
                continue
            buf.append(char)
            index += 1
        collected.append("".join(buf))
    return "\n".join(collected)


def read_text(path):
    return path.read_text(encoding="utf-8", errors="replace")


def parse_includes(settings_text):
    found = []
    for match in INCLUDE_RE.finditer(strip_comments(settings_text)):
        for value in QUOTED_RE.findall(match.group(1)):
            value = value.strip()
            if not value:
                continue
            found.append(value if value.startswith(":") else ":" + value)
    return found


def module_dirs(android):
    result = {}
    for child in sorted(android.iterdir()):
        if not child.is_dir():
            continue
        if child.name.startswith(".") or child.name in SKIP_DIR_NAMES:
            continue
        if (child / "build.gradle.kts").is_file():
            result[child.name] = child
    return result


def check_settings_includes(root):
    android = root / "android"
    settings = android / "settings.gradle.kts"
    if not settings.is_file():
        return False, "missing android/settings.gradle.kts"
    includes = parse_includes(read_text(settings))
    if len(includes) != len(set(includes)):
        return False, "duplicate include(...) entries"
    declared = {name.lstrip(":") for name in includes}
    disk = set(module_dirs(android))
    missing = sorted(disk - declared)
    extra = sorted(declared - disk)
    if missing or extra:
        parts = []
        if extra:
            parts.append("declared without directory: " + ", ".join(":" + name for name in extra))
        if missing:
            parts.append("directory without include: " + ", ".join(":" + name for name in missing))
        return False, "; ".join(parts)
    return True, "{} modules match disk exactly".format(len(declared))


def check_module_build_files(root):
    android = root / "android"
    settings = android / "settings.gradle.kts"
    if not settings.is_file():
        return False, "missing android/settings.gradle.kts"
    includes = sorted({name.lstrip(":") for name in parse_includes(read_text(settings))})
    problems = []
    for name in includes:
        module = android / name
        if not module.is_dir():
            problems.append(":{} has no directory".format(name))
        elif not (module / "build.gradle.kts").is_file():
            problems.append(":{} lacks build.gradle.kts".format(name))
    if problems:
        return False, "; ".join(problems)
    return True, "{0}/{0} modules declare build.gradle.kts".format(len(includes))


def check_module_inventory(root):
    """The include set must be exactly the reviewed 14-module tree."""
    android = root / "android"
    if not android.is_dir():
        return False, "missing android/"
    disk = set(module_dirs(android))
    expected = set(EXPECTED_MODULES)
    missing = sorted(expected - disk)
    unexpected = sorted(disk - expected)
    if missing or unexpected:
        parts = []
        if missing:
            parts.append("missing modules: " + ", ".join(":" + name for name in missing))
        if unexpected:
            parts.append("unreviewed modules: " + ", ".join(":" + name for name in unexpected))
        return False, "; ".join(parts)
    return True, "{} modules match the prepared PR22/PR14 inventory".format(len(expected))


def check_page_inventory(root):
    """The UI page layer must keep the prepared PR22 page floor."""
    directory = root / UI_PAGE_DIR_REL
    if not directory.is_dir():
        return False, "missing {}".format(UI_PAGE_DIR_REL.as_posix())
    pages = sorted(path.name for path in directory.glob("*Page.kt") if path.is_file())
    problems = []
    if len(pages) < EXPECTED_UI_PAGES:
        problems.append(
            "found {} *Page.kt files, prepared baseline is {} (a page was deleted or renamed)".format(
                len(pages), EXPECTED_UI_PAGES
            )
        )
    for name in REQUIRED_UI_PAGES:
        if name not in pages:
            problems.append("required page missing: {}".format(name))
    if problems:
        return False, "; ".join(problems)
    return True, "{} *Page.kt files (prepared floor {}), required anchors present".format(
        len(pages), EXPECTED_UI_PAGES
    )


def check_sdk_levels(root):
    problems = []
    details = []
    for name, expected_min in sorted(SDK_MODULES.items()):
        path = root / "android" / name / "build.gradle.kts"
        if not path.is_file():
            problems.append(":{} lacks build.gradle.kts".format(name))
            continue
        text = strip_comments(read_text(path))
        mins = {int(value) for value in MIN_SDK_RE.findall(text)}
        targets = {int(value) for value in TARGET_SDK_RE.findall(text)}
        if expected_min not in mins:
            problems.append(":{} minSdk is {}, expected {}".format(name, sorted(mins) or "absent", expected_min))
        if TARGET_SDK not in targets:
            problems.append(":{} targetSdk is {}, expected {}".format(name, sorted(targets) or "absent", TARGET_SDK))
        details.append(":{} minSdk={} targetSdk={}".format(name, expected_min, TARGET_SDK))
    if problems:
        return False, "; ".join(problems)
    return True, "; ".join(details)


def parse_mapping_rows(readme_text):
    lines = readme_text.splitlines()
    headers = [index for index, line in enumerate(lines)
               if line.strip().startswith("|") and "Swift 模块" in line
               and "Kotlin 包" in line and "Gradle 模块" in line and "状态" in line]
    if len(headers) != 1:
        raise ValueError("README must contain exactly one mapping table with a status column")
    start = headers[0]
    if start + 1 >= len(lines) or not re.fullmatch(
        r"\s*\|(?:\s*:?-{3,}:?\s*\|){5}\s*", lines[start + 1]
    ):
        raise ValueError("invalid README mapping table separator")
    rows = []
    for line in lines[start + 2:]:
        if not line.strip().startswith("|"):
            break
        cells = [cell.strip().strip("`").strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 5 or any(not cell for cell in cells):
            raise ValueError("invalid README mapping row")
        rows.append(cells[:4])
    return rows


def _load_android_module_map(root):
    inventory = root / "spec" / "platform" / "android-module-map.json"
    schema = root / "spec" / "platform" / "schema" / "android-module-map.schema.json"
    vector_schema = root / "spec" / "platform" / "schema" / "android-module-map-vector.schema.json"
    inventory_schema = load_json(schema)
    lint_schema(inventory_schema, str(schema))
    lint_schema(load_json(vector_schema), str(vector_schema))
    data = load_json(inventory)
    validate_json(data, inventory_schema, str(inventory))
    entries = {}
    for entry in data["modules"]:
        name = entry["swift"]
        if name in entries:
            raise ValueError("duplicate inventory module: {}".format(name))
        entries[name] = entry
    return entries


def _kotlin_code_without_literals(text):
    """Mask Kotlin strings, characters and comments while preserving line breaks.

    A package-looking line in a multiline string or comment is not a package
    declaration. Preserve source positions so the declaration check below sees
    only code, including in files containing raw strings and escaped quotes.
    """
    result = list(text)
    index = 0
    state = "code"
    depth = 0
    while index < len(text):
        if state == "code":
            if text.startswith('"""', index):
                state, count = "raw", 3
            elif text.startswith("//", index):
                state, count = "line", 2
            elif text.startswith("/*", index):
                state, depth, count = "block", 1, 2
            elif text[index] in ('"', "'"):
                state, count = text[index], 1
            else:
                index += 1
                continue
        elif state == "line" and text[index] in "\r\n":
            state = "code"
            index += 1
            continue
        elif state == "block" and text.startswith("/*", index):
            depth += 1
            count = 2
        elif state == "block" and text.startswith("*/", index):
            depth -= 1
            if depth == 0:
                state = "code"
            count = 2
        elif state == "raw" and text.startswith('"""', index):
            state, count = "code", 3
        elif state in ('"', "'") and text[index] == "\\":
            count = min(2, len(text) - index)
        elif state in ('"', "'") and text[index] == state:
            state, count = "code", 1
        else:
            count = 1
        for pos in range(index, index + count):
            if text[pos] not in "\r\n":
                result[pos] = " "
        index += count
    return "".join(result)


def check_readme_map(root):
    try:
        entries = _load_android_module_map(root)
        readme = root / "android" / "README.md"
        rows = parse_mapping_rows(readme.read_text(encoding="utf-8"))
        settings = root / "android" / "settings.gradle.kts"
        includes = set(parse_includes(settings.read_text(encoding="utf-8")))
    except (OSError, UnicodeError, ValueError, SpecError) as exc:
        return False, str(exc)
    sources = root / "Sources"
    if not sources.is_dir():
        return False, "missing Sources/"
    swift_modules = {child.name for child in sources.iterdir()
                     if child.is_dir() and child.name.startswith(SWIFT_PREFIX)}
    problems = []
    for label, names in (("unregistered Sources modules", swift_modules - entries.keys()),
                         ("missing Sources modules", entries.keys() - swift_modules)):
        if names:
            problems.append(label + ": " + ", ".join(sorted(names)))
    names = [row[0] for row in rows]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        problems.append("duplicate README rows: " + ", ".join(duplicates))
    for label, nameset in (("unknown README rows", set(names) - entries.keys()),
                           ("missing README rows", entries.keys() - set(names))):
        if nameset:
            problems.append(label + ": " + ", ".join(sorted(nameset)))
    for name, package, gradle, status in rows:
        entry = entries.get(name)
        if entry is None:
            continue
        expected = [name, entry["kotlin"] or "—", entry["gradle"] or "—", entry["status"]]
        if [name, package, gradle, status] != expected:
            problems.append("README data mismatch: {}".format(name))
    for entry in entries.values():
        package, gradle = entry["kotlin"], entry["gradle"]
        if gradle is None:
            continue
        module = root / "android" / gradle[1:]
        if gradle not in includes or not (module / "build.gradle.kts").is_file():
            problems.append("missing included Gradle module: {}".format(gradle))
            continue
        source_dir = module / "src" / "main" / "kotlin" / Path(*package.split("."))
        declaration = re.compile(r"^[ \t]*package[ \t]+" + re.escape(package) + r"[ \t]*;?[ \t]*\r?$", re.M)
        if not source_dir.is_dir() or not any(
            declaration.search(_kotlin_code_without_literals(read_text(path)))
            for path in source_dir.glob("*.kt") if path.is_file()
        ):
            problems.append("missing Kotlin package {} in {}".format(package, gradle))
    if problems:
        return False, "; ".join(problems)
    return True, "{} reviewed Swift modules match README and Android sources".format(len(entries))


def check_kotlin_stubs(root):
    """Fail on a stub left in production Kotlin.

    The P0 guard was the mirror image of this one: it rejected *any* real
    statement, because that phase was structure only. The tree now carries real
    code, so the useful guard is the one that stops unfinished work from
    shipping: a `TODO()` or an `error("... not implemented")` in `src/main`.
    Test sources are exempt -- a fake backend is allowed to be incomplete.
    """
    android = root / "android"
    files = []
    for path in sorted(android.rglob("*.kt")):
        if any(part in SKIP_DIR_NAMES for part in path.parts):
            continue
        if "src" in path.parts and "main" not in path.parts:
            continue
        files.append(path)
    problems = []
    for path in files:
        cleaned = strip_comments(read_text(path))
        for number, line in enumerate(cleaned.splitlines(), start=1):
            if STUB_RE.search(line):
                problems.append("{}:{}: {}".format(path.relative_to(root), number, line.strip()[:80]))
    if problems:
        return False, "unfinished stub in production Kotlin: " + "; ".join(problems[:5])
    return True, "{} production .kt files, no TODO()/not-implemented stub".format(len(files))


def check_repositories(root):
    android = root / "android"
    problems = []
    allowed = 0
    for path in sorted(android.rglob("*.gradle.kts")):
        if any(part in SKIP_DIR_NAMES for part in path.parts):
            continue
        cleaned = strip_comments(read_text(path))
        declares_in_tree_repo = all(marker in cleaned for marker in IN_TREE_REPO_MARKERS)
        for number, line in enumerate(cleaned.splitlines(), start=1):
            if not line.strip():
                continue
            # A URL is never admitted: not for google()/mavenCentral() (they are
            # function calls), not for the in-tree repo, and not for `file:`.
            if HARD_FORBIDDEN_REPO_RE.search(line):
                problems.append("{}:{}: {}".format(path.relative_to(root), number, line.strip()[:80]))
            elif PATH_REPO_RE.search(line) and not declares_in_tree_repo:
                problems.append("{}:{}: {}".format(path.relative_to(root), number, line.strip()[:80]))
            elif "://" in line:
                problems.append("{}:{}: {}".format(path.relative_to(root), number, line.strip()[:80]))
            allowed += len(re.findall(r"\bgoogle\(\)|\bmavenCentral\(\)", line))
    if problems:
        return False, "non-allowlisted repository: " + "; ".join(problems[:5])
    return True, "only google()/mavenCentral() plus the in-tree publish repo ({} declarations)".format(allowed)


def iter_text_files(root):
    android = root / "android"
    for path in sorted(android.rglob("*")):
        if not path.is_file():
            continue
        if any(part in SKIP_DIR_NAMES for part in path.parts):
            continue
        if path.suffix.lower() in TEXT_SUFFIXES:
            yield path
    for relative in (".github/workflows/android.yml", "docs/design/android-module-map-2026-10-31.md"):
        path = root / relative
        if path.is_file():
            yield path


def is_machine_local_file(root, path):
    """Only the checkout's own android/local.properties is machine-local.

    A file merely *named* local.properties elsewhere (for example a vendored or
    fixture copy) is still a committed file and must stay portable.
    """
    try:
        return path.relative_to(root).as_posix() == "android/local.properties"
    except ValueError:
        return False


def check_absolute_paths(root):
    """Fail on a hard-coded machine path in a committed, shipped file.

    The only file-level exemption is the gitignored android/local.properties,
    whose sdk.dir is machine-local by design. Tool tests are NOT blanket-exempt:
    a fixture that needs an absolute path builds it from parts (or a temporary
    directory), and raw home/SDK paths in a test fail like any other file.
    Shebang lines are skipped wherever they appear (fixtures embed small shell
    scripts), while a non-first-line absolute path in the same file is still a
    finding.
    """
    problems = []
    for path in iter_text_files(root):
        if is_machine_local_file(root, path):
            continue
        if "src" in path.parts and "test" in path.parts:
            continue
        for number, line in enumerate(read_text(path).splitlines(), start=1):
            # A shebang-shaped line is an embedded fixture, not a machine path:
            # skip it wherever it appears, including immediately after a
            # triple-quote opener (`FAKE = r"""#!/usr/bin/env bash`). A real
            # absolute path on any other line is still a finding.
            if line.lstrip().startswith("#!") or any(
                marker in line for marker in ('"""#!', "'''#!", '"#!', "'#!")
            ):
                continue
            match = ABS_POSIX_RE.search(line) or ABS_WINDOWS_RE.search(line)
            if match:
                problems.append("{}:{}: {}".format(path.relative_to(root), number, match.group(0)))
    if problems:
        return False, "hard-coded absolute path: " + "; ".join(problems[:5])
    return True, "0 hard-coded absolute paths"


def check_local_properties_gitignored(root):
    """The bootstrap writes sdk.dir into a machine-local, uncommitted file."""
    path = root / "android" / ".gitignore"
    if not path.is_file():
        return False, "missing android/.gitignore"
    entries = {
        line.strip()
        for line in read_text(path).splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    if "local.properties" not in entries:
        return False, "android/.gitignore does not ignore local.properties"
    return True, "android/local.properties is gitignored (machine-local sdk.dir)"


def check_catalog_pins(root):
    path = root / "android" / "gradle" / "libs.versions.toml"
    if not path.is_file():
        return False, "missing android/gradle/libs.versions.toml"
    section = None
    entries = 0
    problems = []
    for number, line in enumerate(read_text(path).splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped.strip("[]").strip()
            continue
        if section != "versions" or not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            continue
        entries += 1
        if "# unverified pin" not in line:
            problems.append("line {} lacks '# unverified pin'".format(number))
    if entries == 0:
        return False, "[versions] has no entries"
    if problems:
        return False, "; ".join(problems)
    return True, "{} [versions] entries marked unverified".format(entries)


def check_nested_comments(root):
    """Kotlin block comments nest, so `/*` inside a KDoc opens a second comment.

    A doc line like `every wal/*.xlwal file` therefore swallows the rest of the
    file: the compiler reports "unclosed comment" at the end and "unresolved
    reference" on whatever the comment ate, nowhere near the real line. That cost
    two lanes a debugging round, so it is a machine check now.

    The scan is a small state machine, not a regex, because `/*` is harmless inside
    a string: `"/dsh/home/sessions/*/session.*.jsonl"` is a path glob in a test, and
    flagging it would make the check noise instead of signal. Line comments are
    skipped to end of line for the same reason.
    """
    findings = []
    for path in sorted(root.glob("android/**/*.kt")):
        if "/build/" in path.as_posix():
            continue
        text = path.read_text(encoding="utf-8")
        state = "code"          # code | line | block | string | raw | char
        depth = 0
        line = 1
        i = 0
        while i < len(text):
            ch = text[i]
            pair = text[i:i + 2]
            triple = text[i:i + 3]
            if ch == "\n":
                line += 1
                if state == "line":
                    state = "code"
                i += 1
                continue
            if state == "line":
                i += 1
            elif state == "block":
                if pair == "/*":
                    findings.append(
                        f"{path.relative_to(root)}:{line}: nested block comment (`/*` inside a comment)"
                    )
                    depth += 1
                    i += 2
                elif pair == "*/":
                    depth -= 1
                    i += 2
                    if depth == 0:
                        state = "code"
                else:
                    i += 1
            elif state == "raw":
                if triple == '"""':
                    state = "code"
                    i += 3
                else:
                    i += 1
            elif state in ("string", "char"):
                if ch == "\\":
                    i += 2
                elif (state == "string" and ch == '"') or (state == "char" and ch == "'"):
                    state = "code"
                    i += 1
                else:
                    i += 1
            else:  # code
                if pair == "//":
                    state = "line"
                    i += 2
                elif pair == "/*":
                    state = "block"
                    depth = 1
                    i += 2
                elif triple == '"""':
                    state = "raw"
                    i += 3
                elif ch == '"':
                    state = "string"
                    i += 1
                elif ch == "'":
                    state = "char"
                    i += 1
                else:
                    i += 1
    if findings:
        return False, "; ".join(findings[:3])
    return True, "no nested block comments"


def check_android_16k_link_arg(root):
    """The Android link must pin a 16 KB page size, and only for Android."""
    path = root / CARGO_16K_CONFIG
    if not path.is_file():
        return False, "missing {}: nothing pins the Android page size".format(CARGO_16K_CONFIG)
    text = strip_comments(read_text(path))
    problems = []
    pages = [int(match.group(1)) for match in MAX_PAGE_RE.finditer(text)]
    linked = "link-arg" in text and "max-page-size" in text
    if not pages:
        problems.append("no -Wl,-z,max-page-size=<n> in a link argument")
    elif max(pages) < MIN_PAGE_SIZE:
        problems.append("max-page-size={} is below {}".format(max(pages), MIN_PAGE_SIZE))
    if not linked:
        problems.append("the page size is not applied as a rustc link argument")
    # The scoping is part of the requirement: an ungated flag reaches the host
    # dylib (ld64 rejects it) and the wasm products, and a workspace Cargo config
    # would invalidate another lane's jq artifact for no reason.
    if "CARGO_CFG_TARGET_OS" not in text or '"android"' not in text:
        problems.append(
            'missing a CARGO_CFG_TARGET_OS == "android" gate: the flag would leak '
            "into host and wasm links"
        )
    if problems:
        return False, "; ".join(problems)
    return True, "{} pins 16 KB pages for Android only".format(CARGO_16K_CONFIG)


def load_alignment_checker():
    """Import check-native-alignment.py (a dash in the name blocks `import`)."""
    import importlib.util

    path = Path(__file__).resolve().with_name("check-native-alignment.py")
    spec = importlib.util.spec_from_file_location("pdsh_check_native_alignment", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_android_16k_artifact(root):
    """A built arm64-v8a .so must have every PT_LOAD aligned to >= 16 KB."""
    present = [relative for relative in ANDROID_SO_CANDIDATES if (root / relative).is_file()]
    if not present:
        return True, (
            "no arm64-v8a libpdsh_jni.so in the tree, artifact probe SKIPPED "
            "(not a pass by itself; android-16k-link-arg is the source gate). "
            "Build one with: cd shell && cargo ndk -t arm64-v8a build -p pdsh-jni"
        )
    checker = load_alignment_checker()
    problems = []
    notes = []
    for relative in present:
        try:
            loads = checker.parse_load_alignments((root / relative).read_bytes())
        except (OSError, checker.ElfError) as exc:
            problems.append("{}: {}".format(relative, exc))
            continue
        bad = [align for _, align in loads if align < MIN_PAGE_SIZE]
        if bad:
            problems.append(
                "{}: PT_LOAD p_align {} below 0x{:x}".format(
                    relative, ", ".join("0x{:x}".format(align) for align in bad), MIN_PAGE_SIZE
                )
            )
        else:
            notes.append(
                "{}: {} PT_LOAD, min p_align=0x{:x}".format(
                    relative, len(loads), min(align for _, align in loads)
                )
            )
    if problems:
        return False, "; ".join(problems)
    return True, "; ".join(notes) + " (16 KB-page ready)"


CHECKS = (
    ("settings-includes", check_settings_includes),
    ("module-build-files", check_module_build_files),
    ("module-inventory", check_module_inventory),
    ("page-inventory", check_page_inventory),
    ("sdk-levels", check_sdk_levels),
    ("readme-map", check_readme_map),
    ("kotlin-stubs", check_kotlin_stubs),
    ("nested-comments", check_nested_comments),
    ("repositories", check_repositories),
    ("absolute-paths", check_absolute_paths),
    ("local-properties", check_local_properties_gitignored),
    ("catalog-pins", check_catalog_pins),
    ("android-16k-link-arg", check_android_16k_link_arg),
    ("android-16k-artifact", check_android_16k_artifact),
)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check the PDSH Android structure without Gradle or an SDK."
    )
    parser.add_argument("--root", default=".", metavar="DIR", help="repository root (default: .)")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    if not (root / "android").is_dir():
        print("[FAIL] android-tree: {} has no android/ directory".format(root))
        return 1
    failures = 0
    for name, check in CHECKS:
        try:
            ok, detail = check(root)
        except Exception as exc:  # keep one line per check even on bad input
            ok, detail = False, "checker error: {}".format(exc)
        print("[{}] {}: {}".format("PASS" if ok else "FAIL", name, detail))
        if not ok:
            failures += 1
    if failures:
        print("FAILED {} of {} checks".format(failures, len(CHECKS)))
        return 1
    print("OK {} checks passed".format(len(CHECKS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
