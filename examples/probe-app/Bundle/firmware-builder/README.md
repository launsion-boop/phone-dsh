# Firmware builder pack (untracked)

The DEBUG "Firmware builder" page builds one ESP32 firmware on the iPhone. Its
page code is tracked in `../../FirmwareBuilder/`; the large inputs live here and
are **not** committed. One pack is staged at a time:

| Pack | Target | Project | Compilers |
| --- | --- | --- | --- |
| TonoLink | ESP32-S3 (xtensa) | tonolink-m21-r4 `agent_s3` | `cc1` |
| Xiaozhi on the FoloToy AI Passport | ESP32-C3 (riscv32) | 78/xiaozhi-esp32 `folotoy/ai-passport` | `cc1`, `cc1plus` |

| File | What it is |
| --- | --- |
| `cc1.wasm`, `cc1plus.wasm` | Espressif GCC 15.2.0 C and C++ compilers for the pack's target, built for `wasm32-wasip1` (a pack has only the ones its sources need) |
| `as.wasm`, `ar.wasm`, `ld.wasm` | binutils esp-2.45.0 `as`/`ar`/`ld` for the same target |
| `sdk.bin` | Prebuilt ESP-IDF and component archives, linker scripts, the archive plan, the exact `ld` arguments, the ELF path and the chip |
| `project.bin` | The project's sources and headers, and the exact compiler and `as` arguments per source |
| `manifest.json` | Byte count and SHA-256 of each file, the target, the image file name, and the ELF and image digests of the reference build the pack was captured from |

Stage a pack with `scripts/stage-firmware-builder.sh <directory-or-rsync-source>`.
The script copies the files the manifest lists, removes the previous pack, and
refuses a pack whose digests do not match its manifest. Without a pack the app
still builds and the page reports that the pack is missing.

A pack is produced on a computer from one ESP-IDF build of the project with
`scripts/firmware-pack/capture-pack.py` (see its header). The phone never
contacts that computer. The pack fixes the target, the list of sources and every
flag: editing existing sources is supported, adding or removing a source needs a
new pack. Only the TonoLink image can be flashed from the phone (board firmware
page); the xiaozhi image is saved to Files and flashed with `esptool`.
