# PR 59 validation, 2026-11-07

Base: `9b3b31e7291695530765c7d61a32753d902748f9`. Plugin test head:
`ba1b6947`; Android page test head: `a7e8a724`. Protocol impact: P09
for the shared web-search note; the plugin change updates a test and does not
change the packed preset. The frozen P09 revision and compatibility decision
are in [PC-20261107-web-search-note](../protocol-changes/PC-20261107-web-search-note.md).

* Fixed DSH checkout `7be5505b0be06009d74891c869063c9cf19a0df0`:
  `pnpm run build:artifacts` → PASS, 7/7; `PDSH_DSH_CHECKOUT=/private/tmp/pdsh59-upstream-dsh node
  plugins/scripts/dsh-checkout.mjs --verify` → PASS, 7 artifacts, tracked source
  clean. The checkout and artifacts are temporary and are not vendored.
* Actual WASI Python build and `bash plugins/wasi-toolbox/python/build.sh
  --check --out /private/tmp/pdsh59-python-wasi` → PASS with Node 22 in PATH;
  33 selected runtime tests → PASS, 0 skip. `bash plugins/wasi-toolbox/jq/build.sh
  --check --out /private/tmp/pdsh59-jq-wasi --cache /private/tmp/pdsh59-jq-cache`
  → PASS with the isolated Rust toolchain; 24 selected runtime tests → PASS,
  0 skip.
* `bash scripts/ci/check.sh --only phone-plugins` with Node 22.21.1, the verified
  `PDSH_DSH_CHECKOUT`, `PDSH_PYTHON_ARTIFACTS`, `PDSH_PYTHON_WASM`,
  `PDSH_PYTHON_STDLIB`, `PDSH_JQ_ARTIFACTS` and `PDSH_CHROMIUM` set to the
  locally built artifacts and installed Chrome → PASS, 2,454 tests, 0 failed,
  0 skipped. Earlier failures in two outdated test inputs were fixed without
  changing the implementations under test. The new device-task preset is now
  explicitly checked for its isolation gate and absence of tool plugins.

  The precise gate invocation was:

  ```sh
  PATH="$HOME/.nvm/versions/node/v22.21.1/bin:$PATH" \
  RUSTUP_HOME=/private/tmp/pdsh59-rustup CARGO_HOME=/private/tmp/pdsh59-cargo \
  PDSH_DSH_CHECKOUT=/private/tmp/pdsh59-upstream-dsh \
  PDSH_PYTHON_ARTIFACTS=/private/tmp/pdsh59-python-wasi \
  PDSH_PYTHON_WASM=/private/tmp/pdsh59-python-wasi/python.wasm \
  PDSH_PYTHON_STDLIB=/private/tmp/pdsh59-python-wasi/python313.zip \
  PDSH_JQ_ARTIFACTS=/private/tmp/pdsh59-jq-wasi \
  PDSH_CHROMIUM='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  bash scripts/ci/check.sh --only phone-plugins
  ```

* With the same pinned DSH checkout and verified Python/jq artifacts,
  `bash scripts/ci/check.sh --only phone-image` → PASS. `bash
  scripts/ci/smoke.sh` built a fresh Worker bundle and image, then ran the real
  macOS WKWebView smoke suite → PASS, 4 tests, 0 skipped; the smoke report's
  `ok` was true. These are host/runtime checks, not physical-device task proof.
  A subsequent targeted run of the previously skipped Worker scenarios with
  that freshly built bundle and image → FAIL: 8 tests, 4 assertion failures
  in 3 test cases. Two budget-abort cases observed Worker console errors, and
  the WebContent-kill case failed recovery and its expected output-file check.
  These are real observed failures under the supplied assets, not skips; their
  causes and whether they reproduce on the base are still under investigation.
* `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
  → PASS / FAIL / PASS. P0 reports eight missing/stale UI structures; this
  is not page parity or device runtime acceptance.
* The updated `phone-sdk` stage now selects the BLE, LAN and device-task
  modules as well as the prior suites. Its first full run failed because the
  locked cJSON component was absent; after temporarily supplying the fully
  verified locked component, the real cross-runtime Swift/C test passed and
  the full stage wrapper returned PASS. The 16 XCTest bundles reported 1,230
  selected tests, 0 failures and 5 skips; the wrapper's printed 445 is the
  largest single-bundle count, not the overall total. The six live SSH cases
  ran against an ephemeral loopback fixture; the five remaining skipped
  scenarios keep full SDK acceptance incomplete. The temporary SSH keys and
  component link were removed. Android structure
  returned PASS with three skips and the 16 KB JNI artifact unverified. The
  Android `WebSearchSettingsPageTest` subsequently passed on Robolectric: 22
  tests, 0 failures, 0 skipped. This used a temporary mirror and isolated cache;
  the Robolectric Android 14 jar matched Maven Central's published SHA-256,
  while other mirror artifacts were only sampled. Neither result is physical-device evidence.
* `phone-hygiene` remains FAIL (42 findings, also present on the base) and
  `phone-gate-contracts` remains FAIL because its hygiene self-test runs that
  scanner. No allowlist, scanner, baseline, or license was weakened to hide it.

Not verified: physical iPhone/ESP32 BLE task round trip, protected session,
changed-key rejection and persistence after device reboot; actual Android BLE
or LAN device integration; production TLS provisioning, UI and disconnect
acceptance. BLE task grants remain fail-closed and the PR remains draft. The
simulator-only TLS experiment and its limits are recorded in the session CCR.
