# Android local Ubuntu proot slice — receipt

- Worktree: `dsh-work/ubuntu-slice`
- Branch: `fleet-pr14/ubuntu-slice`
- Base: `8c570d6b` (PR14 head)
- Date: 2026-11-03
- Scope: `ubuntu run -- uname -a` through the repository App on a real local
  Ubuntu Base 24.04.5 / Termux proot 5.1.107.102, with the mock backend still
  the default for JVM tests and for any host that does not inject a real
  session factory.

`Protocol impact: P18 — capabilities.ts is a P18 owner file; its JSON field set
and version are unchanged and only the description string is now selected by the
existing `backend` value (the `notes` member already did). P03/P13/P16/P17:
none — no exec-bridge/journal/handoff schema, Remote contract file, Worker URL
param, `PDSH_*` env, `__PDSH_*` global or loopback transport changed. The
`ubuntu` command's JSON shape and `UbuntuJobLane` state machine are untouched;
`backend` remains a string value (`mock`/`proot`).`

## 1. Pinned assets and provenance

| Asset | Version | Bytes | SHA-256 | Licence |
|---|---|---:|---|---|
| `proot_5.1.107.102_aarch64.deb` | Termux proot 5.1.107.102 | 103,028 | `10a394b585c2fc2b2c8502544f4e5f1be581dc8bfff79e8ba62f16207423e030` | GPL-2.0-or-later |
| `proot` raw | same deb | 259,832 | `3621937c1c5a98d0d39ca599af573a6bc15128690606d535e8b05da00cec4f41` | GPL-2.0-or-later |
| `libproot.so` (patched) | same deb | 259,832 | `aad737c5b546ee7471f133be90ef20f765aa98a303522557ceed3dff76605085` | GPL-2.0-or-later |
| `libproot_loader.so` | same deb `libexec/proot/loader` | 18,136 | `1da54355333cca3fb6ee10e3b82a24df24fb230c99241ce83809bf9e240609b5` | GPL-2.0-or-later |
| `libtalloc_2.5.0_aarch64.deb` | Termux libtalloc 2.5.0 | 34,036 | `556591f43bb773ad8777e1a29522640866a55f95dab71914418b94a8c58ad5a7` | LGPL-3.0-or-later |
| `libtalloc.so` | same deb (`libtalloc.so.2.5.0`) | 33,592 | `742b438c4d09e276985a61d44164c9de207b6d8cc268f3018cb3001961bcb309` | LGPL-3.0-or-later |
| `libandroid-shmem_0.7_aarch64.deb` | Termux libandroid-shmem 0.7 | 7,216 | `0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6` | BSD-3-Clause |
| `libandroid-shmem.so` | same deb | 14,432 | `84475798e07c8174dbbfaec70a827fdb02f19ffa69a589380c13e7507fd0e731` | BSD-3-Clause |

`android/tools/fetch-termux-proot.sh` downloads the three `.deb` files over
HTTPS, verifies both the `.deb` SHA-256 and every extracted file's SHA-256, then
rewrites proot's 15-byte `DT_NEEDED` string `libtalloc.so.2\0` to
`libtalloc.so\0\0\0` in place. The output SHA-256 is the pinned patched value
above; no ELF offset moves and no `patchelf` is required. The binaries are
written to `android/app/build/generated/termux-proot/jniLibs` (gitignored) and
never committed. The full text is in `NOTICE`.

Ubuntu Base 24.04.5 arm64 is a runtime download, not a build input:

```
url    https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz
size   29,936,675 B
sha256 a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2
```

Device-side install produced `files/ubuntu` = **151 MB** (rootfs 122 MB on the
4 KiB-page emulator's filesystem), `.pdsh-rootfs` marker:
`24.04.5` + the same SHA-256.

## 2. What changed

- `android/tools/fetch-termux-proot.sh` — pinned download, SHA checks, in-place
  `DT_NEEDED` patch, emitted jniLibs and `proot-assets.json`; `--check` mode.
- `android/app/build.gradle.kts` — `PackageProotAssets` per variant, generated
  jniLibs, `noCompress += "so"`, `keepDebugSymbols` for the four binaries,
  `abiFilters += "arm64-v8a"` (removes transitive 4 KB-aligned armeabi/x86 AAR
  libraries that the packaged-APK gate correctly rejected), manifest
  `extractNativeLibs=true`.
- `android/platform-android/.../UbuntuRootfsStore.kt` — pinned HTTPS download,
  SHA-256 verify, free-space precheck, streaming ustar/PAX extractor (relative
  entry paths only, no `..` escape, absolute in-guest symlinks rewritten
  relative, symlink escape refused, hardlink-to-copy fallback, device nodes
  refused), atomic install + marker, delete.
- `android/platform-android/.../ProotRuntime.kt` — `--kill-on-exit -0 -r rootfs
  -b hostWorkspace:/dsh/workspace -w cwd` argv, cleared child environment with
  `PROOT_LOADER`/`LD_LIBRARY_PATH`/`PROOT_TMP_DIR`/`PROOT_NO_SECCOMP` and the
  guest HOME/PATH/TERM/LANG/TMPDIR, `setsid` + process-group kill.
- `android/app/.../ProotUbuntuAdapter.kt` — real `UbuntuAdapter`
  (start/poll/stop/readArtifact), empty manifest for this slice, `cwd` must be
  `/dsh/workspace` or below, range reads refuse symlinks/path escapes.
- `android/app/.../ProotUbuntuSession.kt` — `backend=proot` session over the
  real adapter + durable job store + real seal.
- `android/dsh/.../UbuntuSession.kt`, `MockUbuntuSession.kt`,
  `UbuntuHostTool.kt`, `HostExec.kt` — `UbuntuSession` seam, session factory
  injection, backend read from the session, probe availability, cancel path,
  close resets the session, real-backend `cwd` check.
- `ProbeEngineViewModel.kt` — composition root chooses the proot session
  factory; `MainActivity.kt` — approval dialog branches on `backend`.
- `plugins/shell-ext/src/ubuntu.ts`, `plugins/shell-ext/src/index.ts`,
  `plugins/worker-entry/src/capabilities.ts` — `ubuntuDescription(backend)`;
  mock keeps the MOCK warning, proot says real and never claims a mock; close
  text says the cached rootfs stays for proot.
- `scripts/ci/check-android-16k.py` + tests — extracted mode
  (`extractNativeLibs=true` auto-detected from the source manifest, or
  `--extracted`): skips zip compression/offset assertions, still checks every
  ELF PT_LOAD `p_align` and the required member; mutation tests added.

## 3. JVM and gate evidence

Commands (JDK 17, Android SDK 35, NDK 30.0.16248370, Gradle 8.13):

```
bash android/tools/with-android-toolchain.sh ./gradlew --no-daemon \
  :dsh:testDebugUnitTest :platform-android:testDebugUnitTest :app:testDebugUnitTest
```

Result: **BUILD SUCCESSFUL**, `dsh 330 / 0 failed`, `platform-android 93 / 0
failed`, `app 271 / 0 failed` (694 total; 0 skipped).

```
cd plugins && npm run typecheck
cd plugins && node scripts/run-tests.mjs "shell-ext/test/ubuntu.test.ts" \
  "worker-entry/src/capability-manifest.test.ts" "tests/shell-ext-bridge.test.ts"
```

Result: typecheck PASS; **57 tests / 57 pass / 0 fail**.

```
python3 android/tools/structure_check.py --root .
python3 -m unittest discover -s scripts/ci -p 'test_check_android_16k.py'
python3 scripts/ci/check-android-16k.py --apk android/app/build/outputs/apk/debug/app-debug.apk
```

Result: structure **14/14 PASS**; gate mutation suite **17 tests OK**; packaged
APK (extracted mode):

```
[i] ... extracted mode (extractNativeLibs=true); zip compression/offset are not
    execution properties, ELF PT_LOAD alignment is still checked
[ok] android/app/build/outputs/apk/debug/app-debug.apk: 21 PT_LOAD segment(s),
    min p_align=0x4000
[PASS] ... every inspected .so is 16 KB aligned in the ELF
```

The APK packaged all four Termux binaries STORED as
`lib/arm64-v8a/{libproot.so,libproot_loader.so,libtalloc.so,libandroid-shmem.so}`
plus `libpdsh_jni.so`, with merged manifest `extractNativeLibs="true"`.

Known unrelated gate results on this working tree (not touched by this diff):
`scripts/ci/license.py` reports five pre-existing files without SPDX headers
(`ChatQueueActionsTest.kt`, `PendingRemoteRequestTest.kt`,
`ArchivedSessionsPageTest.kt`, `test_with_owner_fs_permissions.py`,
`test_with_rust_toolchain.py`); `android/tools/test_gradle_build_inputs.py`
fails because the sandbox cannot write the bootstrap install root
`$HOME/toolchains/pdsh-android`. Our new files carry SPDX MIT headers.

## 4. Device evidence

`emulator-5800` disappeared from `adb devices` during this session; the
available API 35 arm64-v8a 4 KB-page `userdebug` device was **`emulator-5558`**.
The results below are from that device and are not claimed for 5800. No 16 KB
device/image was available.

Build/install:

```
bash examples/probe-app/scripts/copy-bundle-assets.sh --force
bash android/tools/fetch-termux-proot.sh
./gradlew :app:assembleDebug
adb -s emulator-5558 install -r -t android/app/build/outputs/apk/debug/app-debug.apk
```

The APK was installed and the Worker reached `APP_WORKER_READY`. The scripted
upstream called `ubuntu run -- uname -a`; the approval dialog showed
`环境：ubuntu-24.04（backend=proot）` and the real-environment text; 允许 was
tapped. The installed APK was built from this worktree and the final Worker
bundle; a later rebuild after unused-import cleanup produced the same inputs
(both APKs passed the packaged gate).

Cold first run (rootfs absent): the job sealed, then downloaded 29,936,675 B
over ~3 minutes (23:04:17 → 23:07:12), verified the SHA, hit the two real
hardlink fallbacks (`perl5.38.2`, `uncompress`), installed 24.04.5, and ran
proot. The job record succeeded, but the host's planned engine restart during
that long sealed window failed to repack the boot overlay and the turn was
`APP_TURN_FAILED reason=channel_lost`; `internal_access_observed=true` (11
accesses, 6 excused) because the seal was held across unrelated host activity.
**This is a real cold-start risk, recorded below.**

Warm run on the final bundle (rootfs cached; one scripted turn, run then
`ubuntu status` if needed). Captured tool result:

```
ubuntu: run job=uj-e419f327817d49b5aa4025ab5585465a state=succeeded exit=0 env=ubuntu-24.04 backend=proot
ubuntu: egress=false authorityExited=worker-vfs
ubuntu: approval=granted
ubuntu: seal=restored internalAccessObserved=false
--- log tail ---
Linux localhost 6.6.30-android15-8-gdd9c02ccfe27-ab11987101-4k #1 SMP PREEMPT Tue Jun 18 20:50:32 UTC 2024 aarch64 aarch64 aarch64 GNU/Linux
```

`sealMock` is `false`: the host payload carries the real seal's answer, and the
Worker renderer appends its `(mock: ...)` note only when `sealMock === true`;
the note is absent. The job record for this run:

```
state=succeeded exit_code=0 seal_state=restored internal_access_observed=false
```

`ubuntu close` (final bundle, same scripted harness):

```
ubuntu: closed. Every running job was stopped; the cached Ubuntu rootfs stays on disk for the next run.
```

Immediately after `ubuntu close` and after force-stop, there was **no**
`proot`/`uname`/`ld-linux` process under the App UID (`ps -A` → none). Rootfs
marker and SHA-256 were read back from the device:

```
24.04.5
a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2
```

## 5. PASS / FAIL / NOT_RUN

| Item | Result |
|---|---|
| JVM `:dsh` / `:platform-android` / `:app` | **PASS** 694/694 |
| Plugin typecheck + affected tests | **PASS** 57/57 |
| 16 KB extracted-mode gate (APK) | **PASS** (arm64 only; 21 PT_LOAD, min `0x4000`) |
| Structure gate / 16k mutation tests | **PASS** 14/14, 17/17 |
| Device `ubuntu run -- uname -a` on API 35 arm64 | **PASS** on `emulator-5558` (warm rootfs) |
| `backend=proot`, `seal=restored`, `sealMock=false` | **PASS** |
| `state=succeeded`, `exit=0`, stdout `Linux ... aarch64` | **PASS** |
| `ubuntu close` then no residual proot | **PASS** |
| Cold first run through a turn | **PARTIAL** — rootfs download/install/proot succeeded, but the host's planned restart during the ~3 min sealed window made that turn `channel_lost`; the job record itself is `succeeded` |
| `emulator-5800` | **NOT_RUN** — device disappeared; used 5558 |
| 16 KB-page device/image | **NOT_RUN** |
| Physical phone / real model / release build | **NOT_RUN** |
| `gcc`/`apt`, artifacts/`ubuntu fetch` E2E, settings rootfs row | **NOT_RUN** (out of this slice) |

## 6. Remaining risks / decisions

1. **Cold download holds the seal for minutes.** The first run's rootfs download
   completed inside the sealed window; a host planned restart in that window
   failed its boot-overlay repack and lost the turn. The job still ran and
   succeeded, and the next (cached) run was clean. Options are to pre-download
   before `seal` (changes the lane order) or to gate/limit the download under a
   foreground notice. This needs an owner decision before calling first-run UX
   done.
2. **`egress=false` is the contract's local pair**, but proot shares the device
   network: a command that opens a socket can send bytes. The approval and
   Worker text state this; `egress` was not changed (bridge.md §12.5's
   invariant ties `egress=false` to `authorityExited="worker-vfs"`).
3. **The interactive tripwire can observe unrelated host accesses** during a
   long job (`internalAccessObserved=true` on the 3-minute first run). Fast jobs
   reported `false`.
4. **Process death/orphan sweep, RSS monitoring, rootfs deletion UI and the
   settings row** are deliberately not in this slice. App force-stop leaves no
   process in this test, but a kill during proot is not covered by a boot sweep.
5. **Google Play executable-code policy** for the on-demand rootfs is still
   undecided; see `NOTICE`.
6. **Licence review**: proot GPL-2.0-or-later as an independent process,
   libtalloc LGPL-3.0-or-later, libandroid-shmem BSD-3-Clause; `NOTICE` records
   sources, versions, SHAs and the `DT_NEEDED` patch. Legal sign-off and the
   GPL source offer are not part of this code change.
7. **16 KB evidence is static + packaged-APK only**; no 16 KB kernel loaded the
   binaries.

## 7. Reproduction notes

- The generated jniLibs are build inputs: run
  `android/tools/fetch-termux-proot.sh` after a clean; `:app:assembleDebug` then
  fails loudly without them.
- The plugin change means the Worker bundle must be rebuilt before an APK can
  show the backend-aware description:
  `bash examples/probe-app/scripts/copy-bundle-assets.sh --force`.
- The scripted upstream and approval taps are test fixtures, not a real model.
