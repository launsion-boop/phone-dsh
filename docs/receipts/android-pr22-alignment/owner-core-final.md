# PR14 final owner integration — 2026-11-03

This receipt covers the owner-integrated Android source, not the rejected Fleet446 candidate by itself. The owner retained the current-main ancestry, completed UI work and independently accepted helper proof, then integrated Fleet App/lib changes plus bounded Luna repairs. Candidate tools and baseline42 were excluded. No main merge, deployment or workflow restoration.

## Result

- Provider profiles are an atomic collection with selected next-launch default, legacy migration, per-profile key references, request-correlated save receipts and by-ID readback. Invalid/unknown documents fail closed without overwriting bytes; unreadable-key deletion fails before writes. New profiles do not borrow selected-profile keys. Explicit launch endpoint overrides do not borrow a saved profile's key/model.
- Actual runtime launch identity remains separate from the saved next-process default. A same-process engine restart does not apply a different upstream endpoint/key. The UI states this next-App-launch limit and does not claim the running engine switched.
- Key fields are masked/password inputs; Get Models and native probes use the requested profile/draft. Editor and advanced settings have inline source navigation and proper inner Back handling. No real key/provider request was used in this acceptance.
- Configuration reads the four real DSH sources with independent partial errors. Only source-allowlisted namespaces/fields and supported effective values are rendered. Model routes use their special catalog UI, not arbitrary JSON. Writes bind request IDs and the draft's captured namespace revision, confirm through reread, preserve failed/stale/newer drafts, and support local discard.
- Configuration follows source list sections, inline toolbar, About sheet, and inventory navigation. Settings now opens Configuration directly. Inventory refreshes on entry/pull/retry with measured loading/errors. Unsupported phone plugin installation/enabling stays unavailable.

## Verification

- **PASS:** canonical 12-module JVM run: **2369 tests, 0 failures/errors, 2 existing skips** (Core P4SnapshotRecovery; Testkit PythonParity).
- **PASS:** production debug/release APK builds, library AndroidTest APK, current release AAR and published-coordinate minified consumer/R8 build. Current built AAR SHA matches the artifact in the local Maven publication; this was local publication only. Release APK uses the configured debug-signing fallback and was not distributed.
- **PASS:** 180 spec-tool tests, 37-contract extractor freshness, token/source check, Android structure check and whitespace check. The same six existing contrast deferrals remain explicit.
- **PASS:** final Android instrumentation **10/10** on owned API35 ARM64 emulator5560: metrics sheets/Done/compact, short/long code expand/wrap/collapse, catalog pointer/failure/availability/width, navigation gestures and Settings return-scroll retention. These are controlled native fixtures, not live model/backend sessions.
- **PASS:** installed App Settings → Configuration; actual settings values loaded (including subagent limits, execution/tool limits and terminal budgets); About info → Done returned to Configuration; inventory navigation reached the real plugin page.
- **RECOVERED:** first cold inventory read timed out at5s; actual Retry loaded the real plugin inventory. Initial failure is retained in screenshots/XML, not relabeled as first-load success.
- **Historical/scoped:** accepted Fleet Linux permission integration680ee200 verified actual UID0/seccomp fallback9/9; owner adopted its unchanged helper plus strengthened tests/receipt. Earlier Linux runtime53Rust/1204JVM and earlier native-math R8 device render retain their own source bindings.

Logs: `/tmp/pr22-owner-core-final-pass.log`, `/tmp/pr22-owner-core-final-spec-pass-2.log`, `/tmp/pr22-owner-core-final-native-10.log`. Artifact hashes, source delta hash, module counts and physical UI XML/screenshots are retained in owner `fleet-review/core-final-acceptance.json` and `core-ui-final-device`.

## Explicit remaining states

- **FAIL:** structural strict check30 divergences; ratchet17 new outside13 remaining records. The baseline only shrank and one obsolete unrecognized record was removed; no new waiver or baseline record was added. Many remaining provider controls belong to editor/advanced subpages, but no blanket parser exemption was introduced.
- **NOT_RUN:** live provider/model endpoints, physical phones, iOS live interaction and complete paired pixel acceptance, 16KB runtime.
- **Unavailable:** running-child live-stream attachment; unsupported user-history block types fail closed rather than losing content; physical DSH workspace create/switch/delete. Drawer folders remain logical groups sharing the materialized workspace. HTML/3D preview retains the documented process/cookie-isolation limit.
- iOS fixes remain in separate PR23; Android retains current-main iOS source. PR14 stays Draft.


## PR23 main synchronization

PR23 was merged to main as `419e9701a61f952997eb61ce1f34896fb61cd16d`. The Android PR now includes that main commit. Conflict resolution retained the tested 13-record Android ratchet and its helper/variant rules, added main's required segmented-picker option comparison, regenerated contracts from the merged Swift source, and translated 22 unchanged token provenance lines by exact source-line mapping. No token value or Android business code changed during this synchronization. The obsolete standalone editor contract remains represented by the parent's real editor subpage.

Fresh synchronization checks: 182 UI spec tests passed; extractor freshness and token/source checks passed; 17 Android source/token discipline unit tests passed; diff checks passed. The page-structure ratchet remains explicitly FAIL17 outside the same13 records. Prior 2369-module and10-device-case results retain their original product-source binding; the Android product code is unchanged by this main merge.
