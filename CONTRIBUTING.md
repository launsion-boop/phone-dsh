# Contributing

- **Agent collaboration.** Start at [AGENTS.md](AGENTS.md) (also `CLAUDE.md`) and the
  [protocol baseline](spec/README.md): it maps each boundary to its owning contract,
  implementations, compatibility policy, existing checks and known gaps. Protocol-impacting
  changes record the delta and producer/consumer coordination using
  [the change template](docs/protocol-change-template.md) in the task or PR. Behaviour-preserving
  refactors must justify each triggered ID with `ID: none — reason`; a global
  `Protocol impact: none — reason` is allowed only when no IDs trigger. Target/draft clauses are not
  evidence that a feature is implemented.
- **Zero DSH source patches.** The pinned DeepSeek Harness checkout is never modified or vendored
  (`scripts/ci/check.sh --only phone-no-dsh-patch` enforces that on the source tree). The image packer has one controlled
  exception: it stages the built `@deepseek-ai/dsh-file-reference-local` package and normalizes one Cordis `dispose()`
  cleanup statement. A missing or duplicated match fails the pack, and `sizes.json` records the pinned commit/version plus the
  source and transformed SHA-256 (see [`plugins/scripts/README.md`](plugins/scripts/README.md#cordis-disposal-compatibility)).
  Any other change DSH itself needs becomes a patch proposal under `docs/upstream/`.
- **Contract first.** `spec/v1` is the host↔Worker contract; golden vectors are the interoperability oracle for the Swift
  and TypeScript codecs. Change the spec and the vectors together, in one change.
- **Gates.** `bash scripts/ci/check.sh --list` shows every stage. A change must keep `phone-plugins`, `phone-sdk`,
  `phone-image`, `phone-gate-contracts`, `phone-hygiene`, `phone-license` and `phone-no-dsh-patch` green; changes to
  the host path also run `scripts/ci/smoke.sh` (macOS, real WKWebView). The Xcode package-resolution stage is optional
  on developer machines without XcodeGen/Xcode; a run with any skipped stage exits as `INCOMPLETE`, never `PASS`.
- **Rust codec evidence.** `phone-rust-tests` runs `cargo test -p pdsh-wire -p pdsh-wal`
  from `shell/`. Missing cargo is SKIP and makes the aggregate INCOMPLETE; a cargo
  test failure is FAIL. This does not certify Swift/Kotlin interoperability.
- **Public-repo hygiene.** No credentials, no personal paths, no private hostnames; `scripts/ci/hygiene.py` scans for
  them and `scripts/ci/hygiene-allow.txt` holds the deliberate exceptions.
- **Licences.** MIT only for first-party code (SPDX header on every source file); third-party code must be MIT,
  Apache-2.0, BSD or similarly permissive, and is recorded in `plugins/THIRD_PARTY.md` (checked by a test).
- **Fix the mechanism, not the symptom.** A defect found by a scenario or a probe is fixed in the component that owns it,
  with a regression test that fails before the fix. Scenario-specific special cases are not accepted.
