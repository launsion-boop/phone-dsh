<!-- SPDX-License-Identifier: MIT -->
# PC-20261121-remove-geofence — retire the unowned phone geofence tool

## Contract freeze

```yaml
change: PC-20261121-remove-geofence
contracts: [P08, P09, P18, P19]
status: implemented
breaking: true
base: 7ad45d3bf79ef243408a7532265e1b47fc943861
contract_revision: P19 iOS tool catalog at base; PhoneToolCatalog.routes in examples/probe-app/ProbeKit/Capabilities/PhoneCapabilityGate.swift
version_decision: Retire the host tool in the next app build. Keep the P19 phone-tool envelope and phone.<tool> forwarding unchanged; no envelope or wire version is added.
```

- **Trigger → current → expected.** The iOS host exposes `location.geofence` through `PhoneToolCatalog.routes` and `PhoneCapabilityBridge`; the system permission center has a `locationAlways` row, but the app has no geofence management page. The feature registers circular regions after model tool calls. Remove the tool route, implementation, Always-location permission request and permission-center row. Keep the one-shot `location.current` capability and its When-In-Use purpose string.
- **Contract owners.** P19 owns the iOS tool membership and the unchanged result envelope. P08 owns the iOS Core Location calls and retirement cleanup. P09 owns removal of the permission row from iOS, Android and Harmony permission catalogs. P18 owns the one-time old-region cleanup marker. One implementer owns all paths in this change.
- **Delta.** `location.geofence` leaves `PhoneToolCatalog.routes`; calls reaching the new host resolve as `unknown_tool`. `PhoneToolEnvelope` success/failure fields and limits remain unchanged. `locationAlways` is no longer offered in the three permission catalogs. The iOS app removes `NSLocationAlwaysAndWhenInUseUsageDescription`. At first launch after upgrade, it stops previously registered `CLCircularRegion`s and writes `phone-dsh.location-geofence-retired.v1 = true`. It leaves the old `phone-dsh.permissions.locationAlways` preference untouched; the Swift enum case remains decodable for historical audit rows.
- **Compatibility.** Old app → old caller keeps current behavior until the app is upgraded. New app → new caller never advertises the removed tool. A stale caller invoking it against the new host receives `unknown_tool`; no side effect occurs. UserDefaults data is not deleted, so rollback can still decode the old permission case. The upgrade cleanup cancels existing OS region registrations; rollback does not recreate them, so a user would need to configure them again if the old feature is restored.
- **Fixtures and acceptance.** The existing `PhonePermissionContractTests` must exercise the real `CompositePhoneToolBridge`, assert the route is absent, and expect `unknown_tool`. Existing permission-page checks must omit `后台定位`. No shared JSON schema or golden exists for the host-local route catalog; P19 envelope vectors are unchanged. Device verification is still needed to confirm Core Location registrations are cleared on an upgraded iPhone.
- **Exact validation commands.** `plutil -lint examples/probe-app/Config/PhoneDSHProbe-Info.plist`; `git diff --check`; `xcodebuild test -scheme PhoneDSHSim -only-testing:PhoneDSHSimTests/PhonePermissionContractTests`; Android `./gradlew :app:testDebugUnitTest :lib:testDebugUnitTest`. Tests/builds are not run unless requested.

## Revision record

| revision | owner | reason | affected ends |
| --- | --- | --- | --- |
| 1 (frozen) | coordinator | Remove an Agent-only geofence feature with no user management page and retire its permission prompt. | iOS ProbeKit/app, Android permission catalog, Harmony permission catalog |
| 2 (implemented) | coordinator | Remove the tool and permission row across catalogs; preserve historical preference decoding and add upgrade cleanup. | P08 iOS Core Location, P09 permission catalogs, P18 UserDefaults marker, P19 phone tool catalog |

## Handoff evidence

- **Base / head:** freeze base `7ad45d3bf79ef243408a7532265e1b47fc943861`; landed on `origin/main` `2440dcc6f` via branch `fix/remove-geofence`.
- **Protocol impact:** P08; P09; P18; P19.
- **Contract revision:** PC-20261121-remove-geofence, revision 2; no shared schema or golden changes. `spec/registry.json` regenerated from `spec/README.md`.
- **Changed ends:** iOS host route and implementation removed; Android and Harmony background-location rows removed; iOS migration added to stop old circular region registrations once.
- **Status per end:** P08 implemented (device behavior not verified); P09 implemented; P18 implemented; P19 implemented.
- **Commands → result:**
  - `plutil -lint examples/probe-app/Config/PhoneDSHProbe-Info.plist` → PASS
  - `git diff --check` → PASS
  - `PDSH_WITH_XZSHELL=1 xcodebuild test -scheme PhoneDSHSim -only-testing:PhoneDSHSimTests/PhonePermissionContractTests -only-testing:PhoneDSHSimTests/PhoneInfoToolTests` (iOS simulator) → PASS, 10 tests
  - `cd android && ./gradlew :app:testDebugUnitTest --tests '*PhonePermission*' --tests '*HostPhonePermissions*' :lib:testDebugUnitTest --tests '*PhonePermissionsPage*'` → PASS, 17 + 15 tests
  - `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` → phone-spec PASS; phone-cross-tree PASS after `registry_build.py --write`; phone-p0-conformance FAIL with the same two stale-source findings (`BotChatPage.swift:1303` context menu, `ChatPage.swift:4594` 提交回答) reproduced on unmodified `origin/main` `2440dcc6f`.
  - Harmony build → NOT_RUN.
- **Not verified / remaining risk:** no iPhone upgrade test; Core Location region cleanup still needs confirmation on a physical upgraded device. Harmony not built.
