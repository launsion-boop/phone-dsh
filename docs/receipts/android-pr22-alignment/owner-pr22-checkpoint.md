# Latest integration pointer — 2026-11-03

The core provider/configuration repairs are now integrated. See [owner-core-final.md](owner-core-final.md) for the current 2369-test, 10-device-case, APK/AAR/R8 acceptance and explicit remaining states. Product source commit `8c4fd72b` and owner merge `a084b80b` have identical trees. The merge resolved only the baseline-record conflict by retaining the tested, smaller 13-record set.

The older a06 checkpoint below is historical; its rejected446 candidate was subsequently repaired and independently re-reviewed. Its counts and open-work statements are not the latest completion state.

---

# PR14 Android / PR22 owner checkpoint

Date: 2026-11-03. Status: in progress; keep PR14 draft.

## Source binding

- Completed owner source: `a06aefb3187d538a1fb21540f9b296905048b40d`.
- Original PR14: `8c2eeab7b29728ebd0a54b71b5deaab07e5ac6eb`.
- Main ancestor: `2695fd21d2d32369c5b3c8b8ae4cc736819b7d74`.
- UI authority: frozen iOS PR22 `edd687463cd24b9c969914a13fa1da268df016fe`, preserving current-main iOS keyboard/scroll changes. `examples/probe-app`, `Sources` and `.github` remain byte-identical to main in this Android branch.
- Separate iOS follow-up: PR23 `7985eb29498b7a8dc0c6a4ed35fecb12d4e7f80e`; it is not merged into this branch.
- No Android main merge, deployment, or workflow restoration.

## Implemented and reviewed

- Typed session presentation/actions, independent stop availability, confirmed writes and stale session/root result guards; UTF-8 streaming and bounded non-cancellable mux cleanup.
- Source-backed composer/header/empty-state geometry, collapse preference, extended-grapheme 8000-character limit, native math/images/resources and required licenses. Resource loading retains the exact backend Worker identity.
- Actual 320pt drawer with reachable cutout-safe footer, logical group/session actions, archive restore, permission catalog/CAS/readback and settings callbacks. Groups share the physical workspace; they are not independent DSH VFS workspaces.
- Content updates preserve session metadata and current selection across cold launch. Worker-ready now triggers a fresh snapshot after the observed initial `no_channel` race. Installed App cold launch retained `UI-PR22-QA` and automatically populated the permission menu without manual Retry.
- Actual projection-driven compact/detailed session metrics, checked token totals and detail sheets. Projection-only polls refresh live values while preserving catalogs they did not read. Missing metrics are not synthesized.
- Subagent catalog/list identity facts, bounded exact-Worker history reads, confirmed local adoption/selection, cached-history refresh and earlier-page cursor checks. The large sheet follows source geometry. Unsupported aside actions are withheld, matching the separately fixed PR23 availability contract.
- About reuses the unchanged iOS logo asset at 64pt, source branding, raw package version/build, pushed-page back behavior and a footer outside the version card. Source-check adapters verify actual renderer/callback flow and reject conditional/no-op substitutions.

## Evidence and limits

- **PASS at a06aefb3:** canonical 12-module JVM run, **2319 tests, 0 failures/errors, 2 existing skips**: Core P4SnapshotRecoveryTest and Testkit TrajectoryPythonParityTest. Full production debug App and library AndroidTest APK builds passed. Log: `/tmp/pr22-owner-a06-all-modules.log`.
- **PASS:** spec tools 174 tests, extraction check 37 current contracts, token/source check and Android structure check. Tooling 79 tests: 77 executed successfully, 2 Linux-root-only skips on Mac.
- **PASS:** six additional physical Android instrumentation cases (metrics2, CodeBlock2, catalog2), across source-bound runs. These are native component fixtures, not live model sessions. The original 27-case instrumentation run remains separately bound to its earlier owner source; do not combine them into one final-run claim.
- **PASS:** source a06 includes the CodeBlock intrinsic-height crash repair; long code expand/wrap/collapse uses actual pointer input. The floating latest pill's source geometry is retained; its overlap with a wide code footer is handled by tapping the visible control area in the device proof.
- **PASS:** isolated Fleet owner-permission campaign `8616fc65095b41698e30ad972f76f1fc`, accepted integration `680ee2000aa4ef99eb48803674f34f18db72d41d`, independently reviewed/tested. Actual Linux UID0/seccomp fallback: 9/9 tests, no skips; post-exec NoNewPrivs1, DAC bits absent and chmod0500 write denied. Helper source equals owner467d1ac; strengthened tests/receipt adopted in517e23ac. See `owner-permissions-linux-proof.md`.
- **Historical PASS at c175/b185:** release App, published-coordinate AAR consumer/R8 and physical native-math rendering. New final release/AAR/R8 checks are pending the remaining core-page integration.

## Open / FAIL / NOT_RUN

- Source page checks remain **strict FAIL46, ratchet FAIL13 outside33 existing records**. The baseline only shrank; no new waivers were added.
- Fleet Provider/Configuration candidate44632141 is **REJECTED, not applied**. Independent reviews found new-profile overwrite/receipt/key-binding/readback/malformed-data defects and unallowlisted configuration fields, plus draft/refresh lifecycle gaps. Two Luna repair lanes are active. Its CODE report is not owner acceptance.
- Running-child live stream attachment and unsupported user-history block kinds remain explicit subagent limits. Actual child Worker open/history backend validation is NOT_RUN; native catalog tests use controlled callbacks.
- Physical DSH workspace create/switch/delete is unavailable; the drawer's logical groups must not be relabeled as a physical workspace catalog. HTML/3D preview retains the documented process/cookie-isolation limit.
- iOS live interaction/pixel acceptance remains NOT_RUN (user chose to continue current verification). Physical phone, live provider/model endpoints and 16KB runtime checks remain NOT_RUN.

Logs/screenshots and exact source-bound receipts are retained in the owner workspace `fleet-review`; the pre-PR22 PR description is archived in `pr14-description-before-pr22.md` and does not describe current CI status.
