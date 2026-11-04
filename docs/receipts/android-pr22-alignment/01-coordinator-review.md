# PR22 continuation review

Status: UNACCEPTED staged candidate. No Android parity or installed-App acceptance
is claimed. The original PR14 remains unchanged until final owner validation.

## Provenance

- Android origin: PR14 `8c2eeab7b29728ebd0a54b71b5deaab07e5ac6eb`.
- Prepared source: `aa2e1aab2e002e856d8651c27aeb60ca759df403`.
- Frozen iOS authority: PR22 `edd687463cd24b9c969914a13fa1da268df016fe`.
- Shared runtime: main `45de1121ee8b6df4323609ae45e66caa0d0fe29a`.
- First Fleet campaign: `34a5ef86231e459fb3ba168755944755`.
- Staged outputs retain their original commits and merge ancestry; they have not
  been accepted merely because they were imported for a continued Fleet review.

The first campaign's immutable required checks created an ordering blocker:
tokens were required to pass the stale page-contract suite before the page
contract lane could integrate. New dispatch was paused; completed candidates
were retained. This continuation corrects dependency order and check scope,
preserving all original complete-suite commands for final integration.

## Actual coordinator checks

At the combined token/page-contract commit `3a0d4eb`:

- Python UI tooling: 137 tests PASS.
- Token schema/provenance/README checker: PASS, 59 source anchors and 28 geometry
  tokens. Six declared contrast-debt pairs remain; strict contrast is not green.
- iOS page extraction: PASS, 32 generated page contracts.
- Page structure ratchet: PASS with 90 known differences on 12 pages, zero new
  and zero stale differences. This is a migration inventory, not parity.

The exact iOS PR22 source built successfully on the owner's Mac. Native reference
captures use iPhone14ProMax/iOS26.5, 430x932 points at 3x. Preview fixtures and actual
first-launch home/drawer/device/provider interactions are recorded separately.
No real-provider call, physical-device or Android installed-App result is claimed.

After staging the independently produced theme/copy/tooling outputs, the combined
`:lib:compileDebugKotlin` check FAILS: legacy generated token identifiers such as
`radiusComposer` and `geometryDisclosureRowHeight` were removed by the token
refresh but are still read by UiTokens. The continued foundation run must repair
the complete generated API against PR22 source provenance before consumer lanes
start. A script-only green token check is not a compiled Android acceptance.

## Required repairs before acceptance

1. The incoming theme candidate keeps `body` at the old 17pt and adds a separate
   16pt role. Existing consumers must adopt the PR22 roles coherently.
2. Theme codegen must have one data authority: reviewed spec tokens generated
   from HomeSpec provenance, then generated Kotlin. Independent Swift/HTML and
   JSON value tables must not silently diverge.
3. Android provider copy must describe its actual encrypted storage. Do not claim
   Apple Keychain, SwiftTerm or swift-nio are Android runtime dependencies.
4. Bootstrap review found a read-only-root default path, javac-only version
   checking, an overly broad path-check exemption, unbounded downloads and stale
   consumer docs. Repair these against actual task-writable storage.
5. Keep APK/native/Worker missing-input checks fail-loud while allowing unrelated
   host JVM tests to execute. No dummy libraries, empty Worker bundles, skipped
   assertions or reduced published API graph.
6. Five existing lib JVM failures remain assigned to the owning implementation
   lanes. The final integrated run must execute the whole suites again.
7. Home must mount ChatPage with the HomeDrawer overlay. Settings must use PR22's
   grouped index and real subpages. Hidden voice controls stay hidden.
8. Linux source/JVM validation and Mac installed-App acceptance remain distinct.
   Do not require an unavailable emulator in mandatory Linux worker checks or
   relabel missing device evidence as passed.

The deleted CI workflows stay deleted. No main merge or deployment is authorized.
