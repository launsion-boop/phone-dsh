# Android PCLink verification

Run on 2026-11-12 with an Android 15 (API 35) emulator and a physical Mac running `dsh web` with the PCLink plugin. The Mac connected to the configured relay and served an isolated test workspace.

| Check | Observed result | Evidence |
| --- | --- | --- |
| Open **Connect computer** from the **PC** drawer | The drawer closed. The pairing page displayed the installer command. Pasting from the Android clipboard reproduced the complete command. | [Pairing page](pairing-page.png) |
| Pair with the Mac | Android accepted a fresh manual pairing code and showed **已连接 PCLink QA Mac**. The Mac reported `relay: connected`, `pairing: completed`, and a phone approved via `manual`. | [Pairing confirmation](paired.png) |
| Open a Mac session | The PC drawer listed **PCLink Mac QA 20261112**. Opening it showed `PC_HISTORY_QA_20261112`, a marker already present in the Mac session. Android Back returned to the phone chat. | [Mac session history](mac-session.png) |

The test pairing was removed afterward. The red status in the history screenshot belongs to the saved Mac test turn. This run verified reading the saved history. QR pairing, sending a new turn from Android, and a physical Android device were outside the run.

The tested patch was based on `8f3de8b8375bc9c32add4517f6eaadc815b8d4b5`. The installed debug APK had SHA-256 `226ffabf54167024a172089aca1b26ddbd424ccacac04d9004beb8f89624e977`.

Build and targeted tests from `android/` passed. The 250 tests comprise 168 PCLink, 66 app, and 16 UI tests.

```sh
bash tools/with-android-toolchain.sh ./gradlew :app:assembleDebug :pclink:test \
  :app:testDebugUnitTest --tests 'com.phonedsh.probe.HostBackChainTest' \
  --tests 'com.phonedsh.probe.HostPclinkInstallCommandTest' \
  --tests 'com.phonedsh.probe.pc.PcWorkspaceControllerTest' \
  --tests 'com.phonedsh.probe.ChatSessionSnapshotTest' \
  :lib:testDebugUnitTest --tests 'com.phonedsh.ui.nav.PcDrawerTest' \
  --continue --console=plain --max-workers=4
```

From the repository root, `node spec/pclink/v1/tools/vectors.mjs --check` and `python3 spec/pclink/v1/tools/check_samples.py --root .` passed. The page structure check, `python3 -B spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json`, exited 1 with the same three differences on the tested base and patch.
