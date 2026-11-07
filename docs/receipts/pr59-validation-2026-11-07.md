# PR 59 validation, 2026-11-07

Base: `9b3b31e7291695530765c7d61a32753d902748f9`. Test head: `ba1b6947`
(the subsequent receipt changes documentation only). Protocol impact: P09
for the shared web-search note; the plugin change updates a test and does not
change the packed preset. The frozen P09 revision and compatibility decision
are in [PC-20261107-web-search-note](../protocol-changes/PC-20261107-web-search-note.md).

* Fixed DSH checkout `7be5505b0be06009d74891c869063c9cf19a0df0`:
  `pnpm run build:artifacts` → PASS, 7/7; `PDSH_DSH_CHECKOUT=<checkout> node
  plugins/scripts/dsh-checkout.mjs --verify` → PASS, 7 artifacts, tracked source
  clean. The checkout and artifacts are temporary and are not vendored.
* Actual WASI Python build and `bash plugins/wasi-toolbox/python/build.sh
  --check --out <artifacts>` → PASS; 33 selected runtime tests → PASS, 0 skip.
  jq `build.sh --check` → PASS; 24 selected runtime tests → PASS, 0 skip.
* `bash scripts/ci/check.sh --only phone-plugins` with Node 22.21.1, the verified
  `PDSH_DSH_CHECKOUT`, `PDSH_PYTHON_ARTIFACTS`, `PDSH_PYTHON_WASM`,
  `PDSH_PYTHON_STDLIB`, `PDSH_JQ_ARTIFACTS` and `PDSH_CHROMIUM` set to the
  locally built artifacts and installed Chrome → PASS, 2,454 tests, 0 failed,
  0 skipped. Earlier failures in two outdated test inputs were fixed without
  changing the implementations under test. The new device-task preset is now
  explicitly checked for its isolation gate and absence of tool plugins.
* `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
  → PASS / FAIL / PASS. P0 reports eight missing/stale UI structures; this
  is not page parity or device runtime acceptance.
* The full SDK gate's wrapper returned PASS with 11 skips; six SSH cases were
  subsequently run against a temporary loopback SSH fixture (8 tests PASS,
  0 skip). The other skipped SDK checks remain incomplete. Android structure
  returned PASS with three skips and the 16 KB JNI artifact unverified. The
  real Android Compose test for the P09 note was still pending dependency
  setup at this receipt. Neither result is physical-device evidence.
* `phone-hygiene` remains FAIL (42 findings, also present on the base) and
  `phone-gate-contracts` remains FAIL because its hygiene self-test runs that
  scanner. No allowlist, scanner, baseline, or license was weakened to hide it.

Not verified: physical iPhone/ESP32 BLE task round trip, protected session,
changed-key rejection and persistence after device reboot; actual Android BLE
or LAN device integration; production TLS provisioning, UI and disconnect
acceptance. BLE task grants remain fail-closed and the PR remains draft. The
simulator-only TLS experiment and its limits are recorded in the session CCR.
