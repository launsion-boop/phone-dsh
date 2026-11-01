#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Count JUnit results for one or more Android/Gradle modules.
#
# Why this exists: the result directory depends on the module's plugin.
#   * `com.android.library` / `com.android.application`  -> build/test-results/testDebugUnitTest
#                                                            (and testReleaseUnitTest, a second copy
#                                                            of the same tests)
#   * `java-library` + `kotlin.jvm` (":core", ":net", ":platform")  -> build/test-results/test
# A glob of `test*` matches all three and counts the same test three times; a glob of
# `testDebugUnitTest` returns zero for the JVM modules. Both mistakes were made during
# this port and both made the reported number wrong without failing anything, so the
# counting lives here instead of in each prompt.
#
# Usage: android/tools/test-count.sh [module ...]        # default: every module in settings.gradle.kts
#        android/tools/test-count.sh :core :net
#
# The default module set is read from android/settings.gradle.kts instead of a
# hard-coded list, so a module added by another lane is counted without editing
# this file. A TOTAL of zero exits 1: an empty suite must never look like a
# green run (the stage that calls this also re-checks the TOTAL line).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT/android"

if [ "$#" -gt 0 ]; then
  modules=("$@")
else
  modules=()
  while IFS= read -r module; do
    if [ -n "$module" ]; then
      modules[${#modules[@]}]=":$module"
    fi
  done <<EOF
$(sed -n 's/^[[:space:]]*include(":\([^"]*\)").*/\1/p' settings.gradle.kts)
EOF
  if [ "${#modules[@]}" -eq 0 ]; then
    echo "no include(\":module\") lines found in android/settings.gradle.kts" >&2
    exit 2
  fi
fi

total=0
failed=0
partial_modules=""
for module in "${modules[@]}"; do
  name="${module#:}"
  partial=""
  dir="$name/build/test-results"
  [ -d "$dir" ] || { printf '%-20s %s\n' "$module" "no results (not built)"; continue; }
  line=$(python3 - "$dir" <<'PY'
import glob
import os
import sys
import xml.etree.ElementTree as ET

root = sys.argv[1]
# Prefer the per-variant directory when it exists: `test/` may be a published copy of
# the same results (see the :testkit / :lib publishUnitTestReports tasks).
candidates = [os.path.join(root, "testDebugUnitTest"), os.path.join(root, "test")]
chosen = next((c for c in candidates if os.path.isdir(c) and glob.glob(os.path.join(c, "*.xml"))), None)
if chosen is None:
    print("no results (not built)")
    raise SystemExit
tests = failures = errors = skipped = 0
for path in glob.glob(os.path.join(chosen, "*.xml")):
    suite = ET.parse(path).getroot()
    tests += int(suite.get("tests", 0))
    failures += int(suite.get("failures", 0))
    errors += int(suite.get("errors", 0))
    skipped += int(suite.get("skipped", 0))
print(f"{tests} tests, {failures} failures, {errors} errors, {skipped} skipped  [{os.path.basename(chosen)}]")
PY
)
  printf '%-20s %s%s\n' "$module" "$line" "$partial"
  case "$line" in
    *"no results"*) continue ;;
  esac
  # A filtered `--tests` run leaves only the classes it selected, and Gradle then
  # reports the unfiltered task UP-TO-DATE — so the count silently shrinks while
  # still printing "0 failing". Compare the result-file count against the module's
  # test sources and shout when the results look partial.
  partial=""
  case "$line" in
    *"no results"*) ;;
    *)
      src_dir="$name/src/test"
      if [ -d "$src_dir" ]; then
        # Only files whose name *ends* in Test(s): a Helper/"…TestSupport" file is
        # not a test class and would otherwise trip the check on healthy modules.
        srcs=$(find "$src_dir" \( -name '*Test.kt' -o -name '*Tests.kt' -o -name '*Test.java' \) 2>/dev/null | wc -l | tr -d ' ')
        xmls=$(find "$name/build/test-results" -name '*.xml' 2>/dev/null | wc -l | tr -d ' ')
        if [ "$srcs" -gt 0 ] && [ "$xmls" -lt "$srcs" ]; then
          partial="  [PARTIAL? ${xmls} result files for ${srcs} test sources]"
          partial_modules="$partial_modules $module"
        fi
      fi
      ;;
  esac
  n=$(sed -E 's/^([0-9]+) tests.*/\1/' <<<"$line")
  f=$(sed -E 's/.*, ([0-9]+) failures.*/\1/' <<<"$line")
  e=$(sed -E 's/.*, ([0-9]+) errors.*/\1/' <<<"$line")
  total=$((total + n))
  failed=$((failed + f + e))
done

printf '\n%-20s %d tests, %d failing\n' "TOTAL" "$total" "$failed"
if [ "$total" -eq 0 ]; then
  echo "FAIL: 0 tests counted across ${#modules[@]} module(s); an empty suite is not a pass" >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "FAIL: $failed failing test(s) or error(s)" >&2
  exit 1
fi
if [ -n "$partial_modules" ]; then
  echo "WARN: these modules have fewer result files than test sources:$partial_modules" >&2
  echo "      a filtered 'gradlew --tests X' run leaves partial results that look like a pass; re-run with --rerun-tasks" >&2
fi
